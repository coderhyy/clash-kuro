import { createHash } from 'node:crypto'
import { lstat, readFile, realpath } from 'node:fs/promises'
import { isAbsolute, join, normalize, relative, sep } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { parseBootEvidence } from './migration-boot'
import type { PreparedMigrationReceipt } from './migration-preparation'

const digest = /^[a-f0-9]{64}$/
const hash = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex')
const pathKey = (path: string) => process.platform === 'win32' ? normalize(path).toLowerCase() : normalize(path)
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid migration receipt object')
  return value as Record<string, unknown>
}
function text(value: unknown): string {
  if (typeof value !== 'string' || !value || value.includes('\0')) throw new Error('Invalid migration receipt string')
  return value
}
async function canonical(path: string, directory = false): Promise<void> {
  if (!isAbsolute(path) || path.startsWith('\\\\')) throw new Error('Migration receipt requires local absolute paths')
  const stat = await lstat(path)
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) ||
      pathKey(await realpath(path)) !== pathKey(path)) throw new Error('Migration receipt path is not canonical')
}
async function bytes(path: string, maximum = 4 * 1024 * 1024): Promise<Buffer> {
  await canonical(path)
  if ((await lstat(path)).size > maximum) throw new Error('Migration evidence exceeds size limit')
  const result = await readFile(path)
  if (result.length > maximum) throw new Error('Migration evidence exceeds size limit')
  return result
}

/** Recompute disk evidence; this neither authorizes replay nor establishes writer ownership. */
export async function readPreparedMigration(dataDir: string, helperPath: string): Promise<PreparedMigrationReceipt> {
  await canonical(dataDir, true)
  await canonical(helperPath)
  const source = await bytes(join(dataDir, 'proxy-migration.json'))
  const row = object(JSON.parse(source.toString('utf8')))
  if (row.version !== 1 || row.state !== 'prepared' ||
      typeof row.id !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(row.id))
    throw new Error('Migration preparation is incomplete or unsupported')
  const storedHelper = text(row.helperPath), backupDirectory = text(row.backupDirectory)
  const helperDigest = text(row.helperDigest), backupDigest = text(row.backupDigest)
  if (!digest.test(helperDigest) || !digest.test(backupDigest) || pathKey(storedHelper) !== pathKey(helperPath))
    throw new Error('Migration helper binding changed')
  if (!Array.isArray(row.endpoints) || !row.endpoints.length || row.endpoints.length > 8 ||
      new Set(row.endpoints).size !== row.endpoints.length || row.endpoints.some(value => typeof value !== 'string' ||
        !/^127\.0\.0\.1:[1-9]\d{0,4}$/.test(value) || Number(value.split(':')[1]) > 65535))
    throw new Error('Invalid migration receipt endpoints')
  const before = parseBootEvidence(row.before), after = parseBootEvidence(row.after)
  if (row.userSid !== before.userSid || row.userSid !== after.userSid)
    throw new Error('Migration receipt identity mismatch')
  await canonical(backupDirectory, true)
  const child = relative(pathKey(dataDir), pathKey(backupDirectory))
  if (!child || (!isAbsolute(child) && child !== '..' && !child.startsWith(`..${sep}`)))
    throw new Error('Migration backup is inside data directory')
  const manifestBytes = await bytes(join(backupDirectory, 'manifest.json'))
  if (hash(manifestBytes) !== backupDigest) throw new Error('Migration manifest changed')
  const manifest = object(JSON.parse(manifestBytes.toString('utf8')))
  const binding = { version: 1, id: row.id, userSid: row.userSid, endpoints: row.endpoints,
    helperPath: storedHelper, helperDigest, before, after }
  for (const [name, expected] of Object.entries(binding)) {
    if (!isDeepStrictEqual(manifest[name], expected)) throw new Error(`Migration manifest binding mismatch: ${name}`)
  }
  const files = object(manifest.files)
  const required = ['current-helper.exe', 'before-get.json', 'before-boot.json', 'legacy-runonce.json',
    'internet-settings.reg', 'backup.json', 'clear.json', 'after-get.json', 'after-boot.json']
  if (before.legacyRunOnce !== null) required.push('legacy-helper.exe')
  if (!isDeepStrictEqual(Object.keys(files).sort(), required.sort())) throw new Error('Migration backup inventory mismatch')
  for (const [name, expected] of Object.entries(files)) {
    if (typeof expected !== 'string' || !digest.test(expected) ||
        hash(await bytes(join(backupDirectory, name), 64 * 1024 * 1024)) !== expected)
      throw new Error(`Migration backup changed: ${name}`)
  }
  if (files['current-helper.exe'] !== helperDigest || hash(await bytes(helperPath, 64 * 1024 * 1024)) !== helperDigest)
    throw new Error('Migration deployed helper changed')
  if (!(await bytes(join(dataDir, 'proxy-migration.json'))).equals(source)) throw new Error('Migration receipt changed during verification')
  return { version: 1, state: 'prepared', id: row.id, userSid: before.userSid, endpoints: row.endpoints as string[],
    helperPath: storedHelper, helperDigest, backupDirectory, backupDigest, before, after }
}
