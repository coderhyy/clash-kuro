import { createHash, randomUUID } from 'node:crypto'
import { lstat, mkdir, open, readFile, realpath } from 'node:fs/promises'
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { parseBootEvidence, verifyNoKnownLegacyWriters, type BootEvidence } from './migration-boot'
import type { Exec } from './system-proxy'
import { readPreparedMigration } from './migration-receipt'
import { canonicalMigrationArtifact, hashMigrationArtifact, readMigrationArtifact } from './migration-deployment'

export interface PreparedMigrationReceipt {
  version: 1
  state: 'prepared'
  id: string
  userSid: string
  endpoints: readonly string[]
  helperPath: string
  helperDigest: string
  collectorPath: string
  collectorDigest: string
  appPath: string
  appDigest: string
  backupDirectory: string
  /** SHA256 of backupDirectory/manifest.json; preparation is not resident admission. */
  backupDigest: string
  before: BootEvidence
  /** After capture and unchanged proxy readback; absence observations do not establish exclusion or admission. */
  after: BootEvidence
}

export interface MigrationPreparationOptions {
  dataDir: string
  /** A new directory under an existing trusted local parent, outside dataDir. */
  backupDirectory: string
  helperPath: string
  collectorPath: string
  /** Packaged resources/app.asar, not a mutable development source tree. */
  appPath: string
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

async function canonical(path: string, directory: boolean): Promise<string> {
  if (!directory) return canonicalMigrationArtifact(path)
  if (!isAbsolute(path) || /^[\\/]{2}/.test(path) || /[\0\r\n]/.test(path)) throw new Error('Migration requires absolute local paths')
  const stat = await lstat(path), actual = await realpath(path)
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) || normalize(actual) !== normalize(path))
    throw new Error('Migration paths must not traverse links or aliases')
  return actual
}

async function durableMove(exec: Exec, helper: string, source: string, destination: string, replace = false): Promise<void> {
  // Reuse the compiled helper instead of compiling C# in a new PowerShell for every publication.
  const { stdout, stderr } = await exec(helper, ['publish-migration', '--source', source,
    '--destination', destination, '--replace', replace ? 'yes' : 'no'])
  const result = object(JSON.parse(stdout))
  if (stderr.trim() || result.command !== 'publish-migration' || result.ok !== true || result.errorCode !== 0)
    throw new Error('Native write-through publication was not verified')
}

async function durableFile(exec: Exec, helper: string, path: string, bytes: Buffer, replace = false): Promise<void> {
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`)
  const file = await open(temporary, 'wx', 0o600)
  try { await file.writeFile(bytes); await file.sync() } finally { await file.close() }
  await durableMove(exec, helper, temporary, path, replace)
  if (!(await readFile(path)).equals(bytes)) throw new Error('Durable migration file readback differs')
}

function sameBoot(before: BootEvidence, after: BootEvidence, previous: BootEvidence = before): void {
  if (after.userSid !== before.userSid || after.machineGuidSha256 !== before.machineGuidSha256 ||
      BigInt(after.uptimeMs) < BigInt(previous.uptimeMs) || after.lastBootUpTime !== before.lastBootUpTime ||
      after.kernel.record !== before.kernel.record || after.kernel.digest !== before.kernel.digest ||
      after.boot.record !== before.boot.record || after.boot.digest !== before.boot.digest ||
      after.checkpoint?.record !== before.newest.record || after.checkpoint.digest !== before.newest.digest ||
      after.newest.record < before.newest.record || Date.parse(after.collectedAt) < Date.parse(before.collectedAt))
    throw new Error('Identity or boot continuity changed during migration preparation')
}

/** Capture only, without registration or proxy mutation. Snapshot absence cannot exclude delayed
 * legacy launches, even after controlled Restart, and never authorizes initial native admission.
 */
export async function prepareProxyMigration(options: MigrationPreparationOptions): Promise<PreparedMigrationReceipt> {
  const { exec } = options
  const endpoints = [...options.endpoints]
  if (!endpoints.length || endpoints.length > 8 || new Set(endpoints).size !== endpoints.length ||
      endpoints.some(value => value.trim() !== value || !/^127\.0\.0\.1:[1-9]\d{0,4}$/.test(value) || Number(value.split(':')[1]) > 65535))
    throw new Error('Invalid migration endpoint inventory')
  const dataDir = await canonical(options.dataDir, true)
  const helperPath = await canonical(options.helperPath, false)
  const collectorPath = await canonical(options.collectorPath, false)
  const appPath = await canonical(options.appPath, false)
  if (basename(appPath).toLowerCase() !== 'app.asar') throw new Error('Migration requires a packaged app.asar identity')
  const parent = await canonical(dirname(options.backupDirectory), true)
  const backupDirectory = join(parent, basename(options.backupDirectory))
  const within = relative(normalize(dataDir), normalize(backupDirectory))
  if (!isAbsolute(options.backupDirectory) || !within || (!within.startsWith(`..${sep}`) && within !== '..' && !isAbsolute(within)))
    throw new Error('Migration backup must be outside the data directory')
  const marker = join(dataDir, 'proxy-migration.json')
  try { await lstat(marker); throw new Error('Migration marker already exists; retain it and the backups') }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
  const id = randomUUID()
  const preparing = json({ version: 1, state: 'preparing', id, backupDirectory, helperPath, collectorPath, appPath, endpoints })
  await durableFile(exec, helperPath, marker, preparing)
  const markerIdentity = await lstat(marker, { bigint: true })
  const verifyMarker = async () => {
    const stat = await lstat(marker, { bigint: true })
    if (!stat.isFile() || stat.isSymbolicLink() || stat.dev !== markerIdentity.dev || stat.ino !== markerIdentity.ino ||
        stat.nlink !== 1n || !(await readFile(marker)).equals(preparing)) throw new Error('Migration preparing marker changed')
  }

  const collect = async (checkpoint?: number) => {
    const evidence = structuredClone(parseBootEvidence(await options.collect(checkpoint)))
    if (evidence.nativeRunOnce !== null)
      throw new Error('Native recovery registration exists; initial migration unsupported, preserve evidence')
    if (evidence.legacyRunOnce !== null)
      throw new Error('Legacy RunOnce registration exists; preparation requires absence and never deletes it')
    return evidence
  }
  const currentBytes = await readMigrationArtifact(helperPath), helperDigest = hash(currentBytes)
  const collectorDigest = await hashMigrationArtifact(collectorPath, 4 * 1024 * 1024)
  const appDigest = await hashMigrationArtifact(appPath, 512 * 1024 * 1024)
  const before = await collect()
  if (before.knownWriters.length) throw new Error('Known proxy writer processes remain; do not prepare')
  const run = async (args: string[]) => {
    const result = await exec(helperPath, args)
    if (result.stderr.trim()) throw new Error('Migration helper reported diagnostics; state is unverified')
    return result.stdout
  }
  const beforeRaw = await run(['get']), beforeConnections = connections(beforeRaw)

  await mkdir(backupDirectory, { mode: 0o700 })
  const files: Record<string, string> = {}
  const backup = async (name: string, bytes: Buffer) => {
    await durableFile(exec, helperPath, join(backupDirectory, name), bytes)
    files[name] = hash(bytes)
  }
  await backup('current-helper.exe', currentBytes)
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
  await durableMove(exec, helperPath, registryExport, registryPath)
  files['internet-settings.reg'] = hash(registryBytes)
  const binding = { version: 1, id, userSid: before.userSid, endpoints, helperPath, helperDigest,
    collectorPath, collectorDigest, appPath, appDigest,
    legacyHelper: null, before }
  await backup('backup.json', json({ ...binding, files: { ...files } }))
  const verifyBackup = async () => {
    for (const [name, digest] of Object.entries(files)) {
      const path = join(backupDirectory, name)
      await canonical(path, false)
      if (hash(await readFile(path)) !== digest) throw new Error('Migration backup changed or is corrupt')
    }
    if (await hashMigrationArtifact(helperPath) !== helperDigest)
      throw new Error('Migration helper changed after backup')
    if (await hashMigrationArtifact(collectorPath, 4 * 1024 * 1024) !== collectorDigest ||
        await hashMigrationArtifact(appPath, 512 * 1024 * 1024) !== appDigest)
      throw new Error('Migration app or collector changed after backup')
  }
  await verifyBackup()
  const rechecked = await collect(before.newest.record)
  sameBoot(before, rechecked)
  if (rechecked.knownWriters.length) throw new Error('Legacy writer inventory changed during capture')
  await verifyMarker()
  sameConnections(beforeConnections, connections(await run(['get'])))
  await verifyBackup()
  await verifyMarker()

  const afterRaw = await run(['get'])
  await backup('after-get.json', Buffer.from(afterRaw))
  sameConnections(beforeConnections, connections(afterRaw))
  const after = await collect(before.newest.record)
  verifyNoKnownLegacyWriters(after)
  sameBoot(before, after, rechecked)
  await backup('after-boot.json', json(after))
  await backup('retirement.json', json({ kind: 'absence-observation', legacyRunOnce: null }))
  await verifyBackup()
  const manifest = json({ ...binding, after, files })
  await durableFile(exec, helperPath, join(backupDirectory, 'manifest.json'), manifest)
  const receipt: PreparedMigrationReceipt = { version: 1, state: 'prepared', id, userSid: before.userSid,
    endpoints, helperPath, helperDigest, collectorPath, collectorDigest, appPath, appDigest,
    backupDirectory, backupDigest: hash(manifest), before, after }
  await verifyMarker()
  await durableFile(exec, helperPath, marker, json(receipt), true)
  return readPreparedMigration(dataDir, helperPath, { collectorPath, appPath })
}
