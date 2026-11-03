import { afterEach, expect, test, vi } from 'vitest'
import { prepareResidentStartup } from './resident-startup'

const deps = vi.hoisted(() => ({ environment: vi.fn(), session: vi.fn(), prepare: vi.fn(), recover: vi.fn() }))
vi.mock('../platform/resident-environment', () => ({ inspectResidentEnvironment: deps.environment }))
vi.mock('../platform/resident-session', () => ({ startResidentSession: deps.session }))
vi.mock('../platform/recovery-helper', () => ({ prepareRecoveryHelper: deps.prepare }))
vi.mock('../platform/resident-recovery', () => ({ recoverResident: deps.recover }))
afterEach(() => vi.resetAllMocks())
const options = { dataDir: 'private-data', helperPath: 'shipping-helper.exe' }
const session = { helper: options.helperPath, dataDir: options.dataDir, core: 'core.exe',
  server: '127.0.0.1:7891', log: 'log', recoveryDirectory: 'caller-root' }

test('current startup discovers native recovery root without creating a writer', async () => {
  deps.environment.mockResolvedValue({ recoveryDirectory: 'native-root' })
  deps.session.mockResolvedValue('result')
  const start = await prepareResidentStartup(options)
  expect(deps.session).not.toHaveBeenCalled()
  expect(deps.recover).not.toHaveBeenCalled()
  expect(await start(session)).toBe('result')
  expect(deps.session).toHaveBeenCalledExactlyOnceWith({ ...session, recoveryDirectory: 'native-root' })
})

test('pending recovery completes before exposing a new session, including startup without a profile', async () => {
  deps.environment.mockResolvedValue({ recoveryDirectory: 'native-root', retainedStatePresent: true })
  deps.prepare.mockResolvedValue('retained.exe')
  await prepareResidentStartup(options)
  expect(deps.recover).toHaveBeenCalledExactlyOnceWith('retained.exe', expect.stringContaining('sysproxy-owner.log'))
  expect(deps.session).not.toHaveBeenCalled()
  deps.recover.mockRejectedValueOnce(new Error('Recovery unknown'))
  await expect(prepareResidentStartup(options)).rejects.toThrow('Recovery unknown')
  expect(deps.session).not.toHaveBeenCalled()
})

test('invalid discovery never creates a writer', async () => {
  deps.environment.mockRejectedValue(new Error('Invalid native identity'))
  await expect(prepareResidentStartup(options)).rejects.toThrow('Invalid native identity')
  expect(deps.session).not.toHaveBeenCalled()
})

test('caller cannot replace the bound helper, data', async () => {
  deps.environment.mockResolvedValue({ recoveryDirectory: 'native-root' })
  const start = await prepareResidentStartup(options)
  for (const patch of [{ helper: 'other' }, { dataDir: 'other' }])
    await expect(start({ ...session, ...patch })).rejects.toThrow('startup binding')
  expect(deps.session).not.toHaveBeenCalled()
})
