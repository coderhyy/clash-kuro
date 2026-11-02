import { win32 } from 'node:path'
import { execCommand, type Exec } from './system-proxy'

/** Read-only discovery; native reservation must rederive and validate the same root before writing. */
export async function inspectResidentEnvironment(helper: string, exec: Exec = execCommand): Promise<{
  recoveryDirectory: string; userSid: string; retainedStatePresent: boolean; recoveryRegistrationPresent: boolean
}> {
  const { stdout, stderr } = await exec(helper, ['resident-paths'])
  const value = JSON.parse(stdout) as Record<string, unknown> | null
  if (stderr.trim() || !value || value.command !== 'resident-paths' || value.ok !== true ||
      typeof value.retainedStatePresent !== 'boolean' || typeof value.recoveryRegistrationPresent !== 'boolean' ||
      typeof value.userSid !== 'string' || !/^S-1-5-21-\d+-\d+-\d+-\d+$/.test(value.userSid) ||
      typeof value.recoveryDirectory !== 'string' || !/^[a-z]:\\/i.test(value.recoveryDirectory) ||
      /[\0\r\n"]/.test(value.recoveryDirectory) ||
      win32.normalize(value.recoveryDirectory) !== value.recoveryDirectory ||
      !value.recoveryDirectory.endsWith('\\ClashKuro\\Recovery'))
    throw new Error('Native resident environment is unavailable or invalid')
  return { recoveryDirectory: value.recoveryDirectory, userSid: value.userSid,
    retainedStatePresent: value.retainedStatePresent, recoveryRegistrationPresent: value.recoveryRegistrationPresent }
}
