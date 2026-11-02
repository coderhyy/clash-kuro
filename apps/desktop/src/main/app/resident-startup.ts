import { win32 } from 'node:path'
import { readPreparedMigration } from '../platform/migration-receipt'
import { inspectResidentEnvironment } from '../platform/resident-environment'
import { createMigrationAuthorizer } from '../platform/migration-admission'
import { startResidentSession } from '../platform/resident-session'

/** Select a gated route, not an enabled proxy. No Core, recovery replay or proxy write occurs here. */
export async function prepareResidentStartup(options: {
  args: readonly string[]; dataDir: string; helperPath: string; collectorPath: string; appPath?: string
}): Promise<typeof startResidentSession | undefined> {
  if (!options.args.some(arg => arg.startsWith('--experimental-resident'))) return undefined
  const appPath = options.appPath
  if (!appPath) throw new Error('Resident migration requires a packaged, hash-bound app')
  const flags = options.args.filter(arg => arg.startsWith('-'))
  if (flags.filter(arg => arg === '--experimental-resident').length !== 1 ||
      flags.filter(arg => arg === '--confirm-controlled-restart').length > 1 ||
      flags.some(arg => arg !== '--experimental-resident' && arg !== '--confirm-controlled-restart'))
    throw new Error('Invalid resident startup arguments; migration preparation and activation are separate commands')
  const receipt = await readPreparedMigration(options.dataDir, options.helperPath, { ...options, appPath })
  const environment = await inspectResidentEnvironment(options.helperPath)
  if (environment.userSid !== receipt.userSid) throw new Error('Native migration user identity mismatch')
  const confirmControlledRestart = flags.includes('--confirm-controlled-restart')
  return async session => {
    if (session.helper !== options.helperPath || session.dataDir !== options.dataDir || session.authorize)
      throw new Error('Resident session does not match the verified startup binding')
    return startResidentSession({ ...session, recoveryDirectory: environment.recoveryDirectory, initialEndpoints: receipt.endpoints,
      authorize: async held => {
        if (held.userSid !== environment.userSid) throw new Error('Reserved native user differs from startup discovery')
        // Restart/snapshots alone cannot exclude a consumed-but-not-yet-launched legacy RunOnce.
        if (held.admissionReceiptDigest === null)
          throw new Error('Initial resident admission is blocked: legacy launch exclusion has not been established')
        return createMigrationAuthorizer({ dataDir: options.dataDir, helperPath: options.helperPath,
          collectorPath: options.collectorPath, appPath, confirmControlledRestart,
          retainedHelper: win32.join(environment.recoveryDirectory, `${held.helperDigest}.exe`) })(held)
      } })
  }
}
