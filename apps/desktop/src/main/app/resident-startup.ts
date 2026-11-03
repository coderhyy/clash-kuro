import { inspectResidentEnvironment } from '../platform/resident-environment'
import { startResidentSession } from '../platform/resident-session'
import { prepareRecoveryHelper } from '../platform/recovery-helper'
import { recoverResident } from '../platform/resident-recovery'
import { join } from 'node:path'

/** Startup recovery also runs without an active profile; native ownership excludes competing writers. */
export async function prepareResidentStartup(options: {
  dataDir: string; helperPath: string
}): Promise<typeof startResidentSession> {
  const environment = await inspectResidentEnvironment(options.helperPath)
  if (environment.retainedStatePresent || environment.recoveryRegistrationPresent) {
    const retained = await prepareRecoveryHelper(options.helperPath, environment.recoveryDirectory)
    await recoverResident(retained, join(options.dataDir, 'sysproxy-owner.log'))
  }
  return async session => {
    if (session.helper !== options.helperPath || session.dataDir !== options.dataDir)
      throw new Error('Resident session does not match the startup binding')
    return startResidentSession({ ...session, recoveryDirectory: environment.recoveryDirectory })
  }
}
