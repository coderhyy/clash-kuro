import { afterEach, expect, test, vi } from 'vitest'
import { prepareResidentStartup } from './resident-startup'
import type { AuthorizeResident } from '../platform/resident-client'
import type { startResidentSession } from '../platform/resident-session'

const deps = vi.hoisted(() => ({ receipt: vi.fn(), environment: vi.fn(), authorizer: vi.fn(), session: vi.fn() }))
vi.mock('../platform/migration-receipt', () => ({ readPreparedMigration: deps.receipt }))
vi.mock('../platform/resident-environment', () => ({ inspectResidentEnvironment: deps.environment }))
vi.mock('../platform/migration-admission', () => ({ createMigrationAuthorizer: deps.authorizer }))
vi.mock('../platform/resident-session', () => ({ startResidentSession: deps.session }))
afterEach(() => vi.resetAllMocks())
const sid = 'S-1-5-21-1-2-3-1001'
const options = { args: ['kuro.exe', '--experimental-resident', '--confirm-controlled-restart'],
  dataDir: 'private-data', helperPath: 'shipping-helper.exe', collectorPath: 'collector.ps1', appPath: 'app.asar' }
const session = { helper: options.helperPath, dataDir: options.dataDir, core: 'core.exe', server: '127.0.0.1:7891',
  log: 'log', recoveryDirectory: 'caller-chosen-root-must-not-be-used' }

function fixture() {
  deps.receipt.mockResolvedValue({ userSid: sid, endpoints: ['127.0.0.1:7890'] })
  deps.environment.mockResolvedValue({ userSid: sid, recoveryDirectory: 'C:\\Users\\fixture\\ClashKuro\\Recovery' })
  deps.session.mockResolvedValue('session-result')
  const authorize = vi.fn<AuthorizeResident>().mockResolvedValue({ receiptDigest: 'a'.repeat(64), evidenceDigest: 'b'.repeat(64) })
  deps.authorizer.mockReturnValue(authorize)
  return authorize
}

test('default startup does not discover, deploy or enable a resident', async () => {
  expect(await prepareResidentStartup({ ...options, args: ['kuro.exe'] })).toBeUndefined()
  for (const call of Object.values(deps)) expect(call).not.toHaveBeenCalled()
})

test.each([
  ['--experimental-resident=true'], ['--experimental-resident', '--experimental-resident'],
  ['--experimental-resident', '--confirm-controlled-restart', '--confirm-controlled-restart'],
  ['--experimental-resident', '--proxy-migration=prepare'], ['--experimental-resident', '--unknown'],
])('invalid activation flags deny without filesystem or process operations: %j', async (...args) => {
  await expect(prepareResidentStartup({ ...options, args })).rejects.toThrow('Invalid resident startup')
  for (const call of Object.values(deps)) expect(call).not.toHaveBeenCalled()
})

test('route selection stays read-only; actual start retains native root and binds reserved owner to authorizer', async () => {
  const authorize = fixture()
  const start = await prepareResidentStartup(options)
  expect(start).toBeTypeOf('function')
  expect(deps.session).not.toHaveBeenCalled()
  expect(deps.authorizer).not.toHaveBeenCalled()
  expect(await start!(session)).toBe('session-result')
  const input = deps.session.mock.calls[0]![0] as Parameters<typeof startResidentSession>[0]
  expect(input.recoveryDirectory).toBe('C:\\Users\\fixture\\ClashKuro\\Recovery')
  const held = { pid: 123, userSid: sid, nonce: 'c'.repeat(64), helperDigest: 'd'.repeat(64),
    journalDigest: 'e'.repeat(64), priorEndpoints: [], initialEndpoints: [], admissionReceiptDigest: 'a'.repeat(64) }
  await expect(input.authorize!(held)).resolves.toEqual({ receiptDigest: 'a'.repeat(64), evidenceDigest: 'b'.repeat(64) })
  expect(deps.authorizer).toHaveBeenCalledExactlyOnceWith({ dataDir: options.dataDir, helperPath: options.helperPath,
    collectorPath: options.collectorPath, appPath: options.appPath, confirmControlledRestart: true,
    retainedHelper: `C:\\Users\\fixture\\ClashKuro\\Recovery\\${'d'.repeat(64)}.exe` })
  expect(authorize).toHaveBeenCalledExactlyOnceWith(held)
})

test('Restart confirmation cannot bypass unresolved first-admission legacy launch exclusion', async () => {
  fixture()
  const start = (await prepareResidentStartup(options))!
  await start(session)
  const input = deps.session.mock.calls[0]![0] as Parameters<typeof startResidentSession>[0]
  const held = { pid: 123, userSid: sid, nonce: 'c'.repeat(64), helperDigest: 'd'.repeat(64),
    journalDigest: 'e'.repeat(64), priorEndpoints: [], initialEndpoints: ['127.0.0.1:7890'], admissionReceiptDigest: null }
  await expect(input.authorize!(held)).rejects.toThrow('legacy launch exclusion has not been established')
  expect(deps.authorizer).not.toHaveBeenCalled()
})

test('receipt/discovery failures and different users never create a session', async () => {
  fixture()
  deps.receipt.mockRejectedValueOnce(new Error('Backup changed'))
  await expect(prepareResidentStartup(options)).rejects.toThrow('Backup changed')
  expect(deps.environment).not.toHaveBeenCalled()
  deps.environment.mockResolvedValueOnce({ userSid: 'other', recoveryDirectory: 'unused' })
  await expect(prepareResidentStartup(options)).rejects.toThrow('identity mismatch')
  expect(deps.session).not.toHaveBeenCalled()
})

test('caller cannot change helper/data binding or inject an authorizer after route selection', async () => {
  fixture()
  const start = (await prepareResidentStartup(options))!
  for (const patch of [{ helper: 'other' }, { dataDir: 'other' }, { authorize: vi.fn() }])
    await expect(start({ ...session, ...patch })).rejects.toThrow('startup binding')
  expect(deps.session).not.toHaveBeenCalled()
})
