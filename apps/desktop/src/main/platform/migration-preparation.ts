import { createHash, randomUUID } from 'node:crypto'
import { lstat, mkdir, open, readFile, realpath } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { parseBootEvidence, verifyNoKnownLegacyWriters, type BootEvidence } from './migration-boot'
import { parseWindowsProxyServer, type Exec } from './system-proxy'

export interface PreparedMigrationReceipt {
  version: 1
  state: 'prepared'
  id: string
  userSid: string
  endpoints: readonly string[]
  helperPath: string
  helperDigest: string
  backupDirectory: string
  /** SHA256 of backupDirectory/manifest.json; preparation is not resident admission. */
  backupDigest: string
  before: BootEvidence
  /** Collected after successful clear/readback and retirement, for later verifyRestart. */
  after: BootEvidence
}

export interface MigrationPreparationOptions {
  dataDir: string
  /** A new directory under an existing trusted local parent, outside dataDir. */
  backupDirectory: string
  helperPath: string
  endpoints: readonly string[]
  exec: Exec
  collect: (checkpoint?: number) => Promise<BootEvidence>
}

interface Connection {
  name: string | null
  flags: number
  proxyServer: string | null
  bypass: string | null
  autoConfigUrl: string | null
}
const internetSettings = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
const hash = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')
const json = (value: unknown) => Buffer.from(JSON.stringify(value, null, 2) + '\n')
const normalize = (path: string) => process.platform === 'win32' ? resolve(path).toLowerCase() : resolve(path)

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid migration helper result')
  return value as Record<string, unknown>
}

function helperResult(stdout: string, command: string): Record<string, unknown> {
  const result = object(JSON.parse(stdout))
  if (result.ok !== true || result.command !== command ||
      ['error', 'rasError', 'notifyError', 'runOnceError'].some(key => key in result) || !Array.isArray(result.connections))
    throw new Error(`Migration helper ${command} failed or returned incomplete LAN/RAS evidence`)
  return result
}

function connections(stdout: string): Connection[] {
  const result = helperResult(stdout, 'get')
  const names = new Set<string | null>()
  const rows = (result.connections as unknown[]).map(value => {
    const row = object(value)
    if ((row.name !== null && (typeof row.name !== 'string' || !row.name || /[\0\r\n]/.test(row.name))) ||
        typeof row.flags !== 'number' || !Number.isInteger(row.flags) || row.flags < 0 || row.flags > 0xffffffff ||
        ['proxyServer', 'bypass', 'autoConfigUrl'].some(key => row[key] !== null &&
          (typeof row[key] !== 'string' || (row[key] as string).includes('\0'))) || 'error' in row)
      throw new Error('Incomplete migration helper connection')
    const name = typeof row.name === 'string' ? row.name.toLowerCase() : null
    if (names.has(name)) throw new Error('Duplicate migration LAN/RAS connection')
    names.add(name)
    return { name: row.name, flags: row.flags, proxyServer: row.proxyServer,
      bypass: row.bypass, autoConfigUrl: row.autoConfigUrl } as Connection
  })
  if (!names.has(null)) throw new Error('Migration backup has no LAN connection')
  return rows
}

function sameConnections(expected: Connection[], actual: Connection[]): void {
  const sort = (rows: Connection[]) => [...rows].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
  if (JSON.stringify(sort(expected)) !== JSON.stringify(sort(actual))) throw new Error('LAN/RAS settings or inventory changed unexpectedly')
}

function owned(row: Connection, endpoints: readonly string[]): boolean {
  if (!row.proxyServer) return false
  const endpoint = parseWindowsProxyServer(row.proxyServer)
  if (!endpoint || !endpoints.includes(`${endpoint.host}:${endpoint.port}`)) return false
  // Match the native clear parser's alphabetic scheme names, not the looser display parser alone.
  if (row.proxyServer.split(';').some(part => part.trim() &&
      !/^(?:[a-zA-Z]+=)?127\.0\.0\.1:[1-9]\d{0,4}$/.test(part.trim())))
    throw new Error('Ambiguous expected proxy endpoint')
  return true
}

function legacy(command: string | null, endpoints: readonly string[]): string | null {
  if (command === null) return null
  const match = /^"([^"\x00-\x1f\x7f]+)" clear --expected-server (127\.0\.0\.1:[1-9]\d{0,4})(?: --log "([^"\x00-\x1f\x7f]+)")?$/.exec(command)
  if (!match || match[0] !== command || command.length >= 260 || !isAbsolute(match[1]!) ||
      basename(match[1]!).toLowerCase() !== 'kuro-sysproxy.exe' || !endpoints.includes(match[2]!) ||
      (match[3] !== undefined && (!isAbsolute(match[3]) || match[3].length > 255 || /[\\/]$/.test(match[3]))))
    throw new Error('Unrecognized legacy cleanup command; do not retire it')
  return match[1]!
}

async function canonical(path: string, directory: boolean): Promise<string> {
  if (!isAbsolute(path) || path.startsWith('\\\\')) throw new Error('Migration requires absolute local paths')
  const stat = await lstat(path), actual = await realpath(path)
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) || normalize(actual) !== normalize(path))
    throw new Error('Migration paths must not traverse links or aliases')
  return actual
}

async function helperBytes(path: string): Promise<Buffer> {
  await canonical(path, false)
  const bytes = await readFile(path)
  if (!bytes.length) throw new Error('Migration helper is empty')
  return bytes
}

async function durableMove(exec: Exec, source: string, destination: string, replace = false): Promise<void> {
  const payload = Buffer.from(JSON.stringify({ source, destination, flags: replace ? 9 : 8 })).toString('base64')
  // File fsync alone does not make a Windows directory entry durable. Never fall back to plain rename.
  const script = `$ErrorActionPreference = 'Stop'
$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${payload}')) | ConvertFrom-Json
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class KuroMigrationFiles { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool MoveFileEx(string source, string destination, uint flags); }'
if (-not [KuroMigrationFiles]::MoveFileEx($p.source, $p.destination, [uint32]$p.flags)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }`
  await exec('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')])
}

async function durableFile(exec: Exec, path: string, bytes: Buffer, replace = false): Promise<void> {
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`)
  const file = await open(temporary, 'wx', 0o600)
  try { await file.writeFile(bytes); await file.sync() } finally { await file.close() }
  await durableMove(exec, temporary, path, replace)
  if (!(await readFile(path)).equals(bytes)) throw new Error('Durable migration file readback differs')
}

function sameBoot(before: BootEvidence, after: BootEvidence): void {
  if (after.userSid !== before.userSid || after.lastBootUpTime !== before.lastBootUpTime ||
      after.kernel.record !== before.kernel.record || after.kernel.digest !== before.kernel.digest ||
      after.boot.record !== before.boot.record || after.boot.digest !== before.boot.digest ||
      after.checkpoint?.record !== before.newest.record || after.checkpoint.digest !== before.newest.digest ||
      after.newest.record < before.newest.record || Date.parse(after.collectedAt) < Date.parse(before.collectedAt))
    throw new Error('Identity or boot continuity changed during migration preparation')
}

/** Controlled preparation only. Caller owns exclusion of other writers; this never activates or restores. */
export async function prepareProxyMigration(options: MigrationPreparationOptions): Promise<PreparedMigrationReceipt> {
  const { exec } = options
  const endpoints = [...options.endpoints]
  if (!endpoints.length || endpoints.length > 8 || new Set(endpoints).size !== endpoints.length ||
      endpoints.some(value => value.trim() !== value || !/^127\.0\.0\.1:[1-9]\d{0,4}$/.test(value) || Number(value.split(':')[1]) > 65535))
    throw new Error('Invalid migration endpoint inventory')
  const dataDir = await canonical(options.dataDir, true)
  const helperPath = await canonical(options.helperPath, false)
  const parent = await canonical(dirname(options.backupDirectory), true)
  const backupDirectory = join(parent, basename(options.backupDirectory))
  const within = relative(normalize(dataDir), normalize(backupDirectory))
  if (!isAbsolute(options.backupDirectory) || !within || (!within.startsWith(`..${sep}`) && within !== '..' && !isAbsolute(within)))
    throw new Error('Migration backup must be outside the data directory')
  const marker = join(dataDir, 'proxy-migration.json')
  try { await lstat(marker); throw new Error('Migration marker already exists; retain it and the backups') }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
  const id = randomUUID()
  const preparing = json({ version: 1, state: 'preparing', id, backupDirectory, helperPath, endpoints })
  await durableFile(exec, marker, preparing)
  const markerIdentity = await lstat(marker, { bigint: true })
  const verifyMarker = async () => {
    const stat = await lstat(marker, { bigint: true })
    if (!stat.isFile() || stat.isSymbolicLink() || stat.dev !== markerIdentity.dev || stat.ino !== markerIdentity.ino ||
        stat.nlink !== 1n || !(await readFile(marker)).equals(preparing)) throw new Error('Migration preparing marker changed')
  }

  const collect = async (checkpoint?: number) => structuredClone(parseBootEvidence(await options.collect(checkpoint)))
  const before = await collect()
  if (before.knownWriters.length) throw new Error('Known proxy writer processes remain; do not prepare')
  const oldHelper = legacy(before.legacyRunOnce, endpoints)
  const currentBytes = await helperBytes(helperPath), helperDigest = hash(currentBytes)
  const oldBytes = oldHelper ? await helperBytes(oldHelper) : null
  const run = async (args: string[]) => {
    const result = await exec(helperPath, args)
    if (result.stderr.trim()) throw new Error('Migration helper reported diagnostics; state is unverified')
    return result.stdout
  }
  const beforeRaw = await run(['get']), beforeConnections = connections(beforeRaw)
  const cleared = beforeConnections.map(row => ({ ...row,
    flags: (row.flags & 2) && owned(row, endpoints) ? ((row.flags & ~2) | 1) >>> 0 : row.flags,
  }))

  await mkdir(backupDirectory, { mode: 0o700 })
  const files: Record<string, string> = {}
  const backup = async (name: string, bytes: Buffer) => {
    await durableFile(exec, join(backupDirectory, name), bytes)
    files[name] = hash(bytes)
  }
  await backup('current-helper.exe', currentBytes)
  if (oldBytes) await backup('legacy-helper.exe', oldBytes)
  await backup('before-get.json', Buffer.from(beforeRaw))
  await backup('before-boot.json', json(before))
  await backup('legacy-runonce.json', json(before.legacyRunOnce))
  const registryExport = join(backupDirectory, 'internet-settings-export.reg')
  const registryPath = join(backupDirectory, 'internet-settings.reg')
  await exec('reg.exe', ['export', internetSettings, registryExport])
  await canonical(registryExport, false)
  const registryBytes = await readFile(registryExport), registry = registryBytes.subarray(2).toString('utf16le')
  const root = 'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
  if (registryBytes.length % 2 !== 0 || registryBytes[0] !== 0xff || registryBytes[1] !== 0xfe ||
      !registry.startsWith('Windows Registry Editor Version 5.00\r\n') || !registry.endsWith('\r\n') || registry.includes('\0') ||
      !registry.includes(`[${root}]\r\n`) || !registry.includes(`[${root}\\Connections]\r\n`))
    throw new Error('Incomplete Internet Settings/Connections registry export')
  const registryFile = await open(registryExport, 'r+')
  try { await registryFile.sync() } finally { await registryFile.close() }
  await durableMove(exec, registryExport, registryPath)
  files['internet-settings.reg'] = hash(registryBytes)
  const binding = { version: 1, id, userSid: before.userSid, endpoints, helperPath, helperDigest,
    legacyHelper: oldHelper && { path: oldHelper, digest: hash(oldBytes!) }, before }
  await backup('backup.json', json({ ...binding, files: { ...files } }))
  const verifyBackup = async () => {
    for (const [name, digest] of Object.entries(files)) {
      const path = join(backupDirectory, name)
      await canonical(path, false)
      if (hash(await readFile(path)) !== digest) throw new Error('Migration backup changed or is corrupt')
    }
    if (hash(await helperBytes(helperPath)) !== helperDigest ||
        (oldHelper && hash(await helperBytes(oldHelper)) !== hash(oldBytes!)))
      throw new Error('Migration helper changed after backup')
  }
  await verifyBackup()
  const preClear = await collect(before.newest.record)
  sameBoot(before, preClear)
  if (preClear.knownWriters.length || preClear.legacyRunOnce !== before.legacyRunOnce)
    throw new Error('Legacy writer inventory or command changed before clear')
  await verifyMarker()
  sameConnections(beforeConnections, connections(await run(['get'])))
  await verifyBackup()
  await verifyMarker()

  const clearRaw = await run(['clear', ...endpoints.flatMap(endpoint => ['--expected-server', endpoint])])
  await backup('clear.json', Buffer.from(clearRaw))
  const report = helperResult(clearRaw, 'clear')
  if (report.runOnce !== 'deleted' || (report.connections as unknown[]).length !== beforeConnections.length)
    throw new Error('Legacy cleanup retirement or per-connection clear is unverified')
  const statuses = new Map<string | null, unknown>()
  for (const value of report.connections as unknown[]) {
    const row = object(value)
    if ((row.name !== null && typeof row.name !== 'string') || statuses.has(row.name as string | null) || 'error' in row)
      throw new Error('Invalid clear connection evidence')
    statuses.set(row.name as string | null, row.status)
  }
  for (const row of beforeConnections) {
    const expected = !(row.flags & 2) ? 'unchanged' : owned(row, endpoints) ? 'cleared' : 'notOurs'
    if (statuses.get(row.name) !== expected) throw new Error('Clear reported an unexpected connection change')
  }
  const afterRaw = await run(['get'])
  await backup('after-get.json', Buffer.from(afterRaw))
  sameConnections(cleared, connections(afterRaw))
  const after = await collect(before.newest.record)
  verifyNoKnownLegacyWriters(after)
  sameBoot(before, after)
  await backup('after-boot.json', json(after))
  await verifyBackup()
  const manifest = json({ ...binding, after, files })
  await durableFile(exec, join(backupDirectory, 'manifest.json'), manifest)
  const receipt: PreparedMigrationReceipt = { version: 1, state: 'prepared', id, userSid: before.userSid,
    endpoints, helperPath, helperDigest, backupDirectory, backupDigest: hash(manifest), before, after }
  await verifyMarker()
  await durableFile(exec, marker, json(receipt), true)
  return receipt
}
