import { lstat } from 'node:fs/promises'
import { join } from 'node:path'

/** Prevent the legacy startup cleanup from running after controlled migration begins. */
export async function guardMigrationStartup(dataDir: string, options: {
  os?: NodeJS.Platform; args?: readonly string[]
} = {}): Promise<void> {
  if ((options.os ?? process.platform) !== 'win32') return
  if ((options.args ?? process.argv).includes('--experimental-resident'))
    throw new Error('Resident admission is not available in this build; do not bypass migration verification')
  try { await lstat(join(dataDir, 'proxy-migration.json')) }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
    throw new Error('Cannot verify migration state; no Core or proxy operation admitted', { cause: error })
  }
  // Any marker (including corrupt, linked or incomplete) forbids falling back to legacy writes.
  throw new Error('Controlled proxy migration is pending; legacy startup is blocked. Keep backups and complete migration verification before starting Kuro')
}
