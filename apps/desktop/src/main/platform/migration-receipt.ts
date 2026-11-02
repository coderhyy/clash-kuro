import { createHash } from 'node:crypto'
import { lstat, realpath } from 'node:fs/promises'
import { basename, isAbsolute, join, normalize, relative, sep } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { parseBootEvidence } from './migration-boot'
import type { PreparedMigrationReceipt } from './migration-preparation'
import { canonicalMigrationArtifact, hashMigrationArtifact, readMigrationArtifact } from './migration-deployment'

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
  if (!directory) { await canonicalMigrationArtifact(path); return }
  if (!isAbsolute(path) || /^[\\/]{2}/.test(path) || /[\0\r\n]/.test(path)) throw new Error('Migration receipt requires local absolute paths')
  const stat = await lstat(path)
  if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile()) ||
      pathKey(await realpath(path)) !== pathKey(path)) throw new Error('Migration receipt path is not canonical')
}
async function bytes(path: string, maximum = 4 * 1024 * 1024): Promise<Buffer> {
  return readMigrationArtifact(path, maximum)
}

/** Recompute disk evidence; this neither authorizes replay nor establishes writer ownership. */
export async function readPreparedMigration(dataDir: string, helperPath: string,
  deployment: { collectorPath: string; appPath: string }): Promise<PreparedMigrationReceipt> {
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
  const collectorPath = text(row.collectorPath), appPath = text(row.appPath)
  const collectorDigest = text(row.collectorDigest), appDigest = text(row.appDigest)
  if (!digest.test(collectorDigest) || !digest.test(appDigest) ||
      pathKey(collectorPath) !== pathKey(deployment.collectorPath) || pathKey(appPath) !== pathKey(deployment.appPath) ||
      basename(appPath).toLowerCase() !== 'app.asar') throw new Error('Migration deployment binding changed')
  const verifyDeployment = async () => {
    if (await hashMigrationArtifact(deployment.collectorPath, 4 * 1024 * 1024) !== collectorDigest ||
        await hashMigrationArtifact(deployment.appPath, 512 * 1024 * 1024) !== appDigest)
      throw new Error('Migration app or collector changed')
  }
  await verifyDeployment()
  if (!Array.isArray(row.endpoints) || !row.endpoints.length || row.endpoints.length > 8 ||
      new Set(row.endpoints).size !== row.endpoints.length || row.endpoints.some(value => typeof value !== 'string' ||
        !/^127\.0\.0\.1:[1-9]\d{0,4}$/.test(value) || Number(value.split(':')[1]) > 65535))
    throw new Error('Invalid migration receipt endpoints')
  const before = parseBootEvidence(row.before), after = parseBootEvidence(row.after)
  if (before.legacyRunOnce !== null || after.legacyRunOnce !== null)
    throw new Error('Migration capture requires legacy RunOnce absence; retirement is unsupported')
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
    helperPath: storedHelper, helperDigest, collectorPath, collectorDigest, appPath, appDigest, before, after }
  for (const [name, expected] of Object.entries(binding)) {
    if (!isDeepStrictEqual(manifest[name], expected)) throw new Error(`Migration manifest binding mismatch: ${name}`)
  }
  const files = object(manifest.files)
  const required = ['current-helper.exe', 'before-get.json', 'before-boot.json', 'legacy-runonce.json',
    'internet-settings.reg', 'backup.json', 'retirement.json', 'after-get.json', 'after-boot.json']
  if (!isDeepStrictEqual(Object.keys(files).sort(), required.sort())) throw new Error('Migration backup inventory mismatch')
  for (const [name, expected] of Object.entries(files)) {
    if (typeof expected !== 'string' || !digest.test(expected) ||
        hash(await bytes(join(backupDirectory, name), 64 * 1024 * 1024)) !== expected)
      throw new Error(`Migration backup changed: ${name}`)
  }
  if (files['current-helper.exe'] !== helperDigest || hash(await bytes(helperPath, 64 * 1024 * 1024)) !== helperDigest)
    throw new Error('Migration deployed helper changed')
  const retirement = object(JSON.parse((await bytes(join(backupDirectory, 'retirement.json'))).toString('utf8')))
  if (!isDeepStrictEqual(retirement, { kind: 'absence-observation', legacyRunOnce: null }) ||
      JSON.parse((await bytes(join(backupDirectory, 'legacy-runonce.json'))).toString('utf8')) !== null)
    throw new Error('Migration capture requires a no-op legacy absence observation, not retirement')
  await verifyDeployment()
  if (!(await bytes(join(dataDir, 'proxy-migration.json'))).equals(source)) throw new Error('Migration receipt changed during verification')
  return { version: 1, state: 'prepared', id: row.id, userSid: before.userSid, endpoints: row.endpoints as string[],
    helperPath: storedHelper, helperDigest, collectorPath, collectorDigest, appPath, appDigest,
    backupDirectory, backupDigest, before, after }
}
