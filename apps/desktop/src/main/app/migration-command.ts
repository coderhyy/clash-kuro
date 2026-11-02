import { lstat, realpath } from 'node:fs/promises'
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { collectBootEvidence, parseBootEvidence, verifyNoKnownLegacyWriters, verifyRestart } from '../platform/migration-boot'
import { prepareProxyMigration, type MigrationPreparationOptions } from '../platform/migration-preparation'
import { readPreparedMigration } from '../platform/migration-receipt'
import { execCommand } from '../platform/system-proxy'

export type MigrationCommand =
  | { command: 'prepare'; backupDirectory: string; endpoints: string[] }
  | { command: 'check' }

export interface MigrationCommandOptions extends Pick<MigrationPreparationOptions, 'dataDir' | 'helperPath'> {
  args: readonly string[]
  collectorPath: string
  installationRoot: string
  /** Required for development builds; omit for an installed build. */
  repoRoot?: string
  exec?: MigrationPreparationOptions['exec']
  collect?: MigrationPreparationOptions['collect']
}

export type MigrationCommandResult =
  | { handled: false }
  | { handled: true; command: MigrationCommand['command']; residentEnabled: false; message: string }

/** Accept full argv or just command arguments. Migration options always use the explicit equals form. */
export function parseMigrationCommand(args: readonly string[]): MigrationCommand | null {
  if (args.some(arg => arg.startsWith('--experimental-resident')))
    throw new Error('Resident admission is not available in this build')
  if (!args.some(arg => /^--(?:proxy-migration|backup-directory|expected-server|confirm-controlled-restart)/.test(arg)))
    return null

  const values = new Map<string, string>()
  const endpoints: string[] = []
  let started = false
  for (const arg of args) {
    if (!started && !arg.startsWith('-')) continue
    started = true
    if (arg === '--confirm-controlled-restart') {
      if (values.has('confirm')) throw new Error('Duplicate controlled restart confirmation')
      values.set('confirm', 'true')
      continue
    }
    const match = /^--(proxy-migration|backup-directory|expected-server)=(.+)$/.exec(arg)
    if (!match || /[\0\r\n]/.test(arg)) throw new Error(`Malformed or unknown migration argument: ${arg}`)
    const name = match[1]!, value = match[2]!
    if (name === 'expected-server') {
      if (!/^127\.0\.0\.1:[1-9]\d{0,4}$/.test(value) || Number(value.split(':')[1]) > 65535 ||
          endpoints.includes(value) || endpoints.length >= 8) throw new Error('Invalid or duplicate migration endpoint')
      endpoints.push(value)
    } else {
      if (values.has(name)) throw new Error(`Duplicate migration argument: ${name}`)
      values.set(name, value)
    }
  }
  const command = values.get('proxy-migration')
  if (command === 'prepare') {
    const backupDirectory = values.get('backup-directory')
    if (!backupDirectory || !isAbsolute(backupDirectory) || backupDirectory.startsWith('\\\\') ||
        backupDirectory.startsWith('//') || !endpoints.length || values.has('confirm'))
      throw new Error('Prepare requires an absolute local --backup-directory and --expected-server; restart confirmation is check-only')
    return { command, backupDirectory, endpoints }
  }
  if (command === 'check') {
    if (!values.has('confirm') || values.has('backup-directory') || endpoints.length)
      throw new Error('Check requires --confirm-controlled-restart; backup-directory and expected-server are prepare-only')
    return { command }
  }
  throw new Error('Expected explicit --proxy-migration=prepare or --proxy-migration=check')
}

const pathKey = (path: string) => process.platform === 'win32' ? resolve(path).toLowerCase() : resolve(path)

async function canonicalDirectory(path: string): Promise<string> {
  if (!isAbsolute(path) || path.startsWith('\\\\') || path.startsWith('//') || /[\0\r\n]/.test(path))
    throw new Error('Migration requires absolute local directories')
  const stat = await lstat(path), actual = await realpath(path)
  if (!stat.isDirectory() || stat.isSymbolicLink() || pathKey(actual) !== pathKey(path))
    throw new Error('Migration directories must not traverse links or aliases')
  return actual
}

async function verifyBackupParent(backupDirectory: string, options: MigrationCommandOptions): Promise<void> {
  const parent = await canonicalDirectory(dirname(backupDirectory))
  for (const root of [options.installationRoot, ...(options.repoRoot === undefined ? [] : [options.repoRoot])]) {
    const child = relative(pathKey(await canonicalDirectory(root)), pathKey(parent))
    if (!child || (!isAbsolute(child) && child !== '..' && !child.startsWith(`..${sep}`)))
      throw new Error('Migration backup parent must be outside the installation and repository')
  }
}

/** Caller holds the single-instance lock and has not constructed Platform or started any proxy writer. */
export async function runMigrationCommand(options: MigrationCommandOptions): Promise<MigrationCommandResult> {
  const command = parseMigrationCommand(options.args)
  if (!command) return { handled: false }
  const exec = options.exec ?? execCommand
  const source = options.collect ?? ((checkpoint?: number) => collectBootEvidence(options.collectorPath, checkpoint, exec))
  const collect: MigrationPreparationOptions['collect'] = async checkpoint => {
    const evidence = parseBootEvidence(await source(checkpoint))
    // Only this pre-Platform coordinator is exempt; names and caller-supplied PIDs cannot exempt other writers.
    return { ...evidence, knownWriters: evidence.knownWriters.filter(writer => writer.pid !== process.pid) }
  }

  if (command.command === 'prepare') {
    await verifyBackupParent(command.backupDirectory, options)
    await prepareProxyMigration({ dataDir: options.dataDir, helperPath: options.helperPath,
      backupDirectory: command.backupDirectory, endpoints: command.endpoints, exec, collect })
    return { handled: true, command: 'prepare', residentEnabled: false,
      message: 'Migration prepared. Keep the marker and backups. Resident NOT enabled; exclusive native ownership/replay still required. This build is not a completed migration handoff; do not Restart or activate resident on this result alone.' }
  }

  const receipt = await readPreparedMigration(options.dataDir, options.helperPath)
  const observed = await collect(receipt.after.newest.record)
  verifyNoKnownLegacyWriters(receipt.after)
  verifyNoKnownLegacyWriters(observed)
  verifyRestart(receipt.after, observed)
  if (!isDeepStrictEqual(receipt, await readPreparedMigration(options.dataDir, options.helperPath)))
    throw new Error('Migration receipt changed while collecting restart evidence')
  return { handled: true, command: 'check', residentEnabled: false,
    message: 'Migration check passed: prerequisites-only. Resident NOT enabled; exclusive native ownership/replay still required. Keep the marker and backups; this is not full positive admission.' }
}
