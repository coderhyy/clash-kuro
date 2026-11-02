import { join } from 'node:path'
import { beforeEach, expect, test, vi } from 'vitest'
import { guardMigrationStartup } from './migration-startup'

const deps = vi.hoisted(() => ({ lstat: vi.fn() }))
vi.mock('node:fs/promises', () => ({ lstat: deps.lstat }))
const dataDir = 'profile-data'
const environment = { command: 'resident-paths', ok: true, userSid: 'S-1-5-21-1-2-3-1001',
  recoveryDirectory: 'C:\\Users\\fixture\\AppData\\Local\\ClashKuro\\Recovery',
  retainedStatePresent: false, recoveryRegistrationPresent: false }
const missing = () => Object.assign(new Error('Missing marker'), { code: 'ENOENT' })
beforeEach(() => {
  deps.lstat.mockReset()
  deps.lstat.mockRejectedValue(missing())
})

function fixture() {
  const exec = vi.fn(async () => ({ stdout: JSON.stringify(environment), stderr: '' }))
  return { os: 'win32' as const, args: [], helper: 'trusted-helper.exe', exec }
}

test('missing profile marker allows legacy only after one read-only native absence check', async () => {
  const options = fixture()
  await expect(guardMigrationStartup(dataDir, options)).resolves.toBeUndefined()
  expect(deps.lstat).toHaveBeenCalledExactlyOnceWith(join(dataDir, 'proxy-migration.json'))
  expect(options.exec).toHaveBeenCalledExactlyOnceWith(options.helper, ['resident-paths'])
})

test.each([[true, false], [false, true], [true, true]])(
  'missing profile marker cannot downgrade with retained state=%s or registration=%s', async (retainedStatePresent, recoveryRegistrationPresent) => {
    const options = fixture()
    options.exec.mockResolvedValue({ stdout: JSON.stringify({ ...environment, retainedStatePresent, recoveryRegistrationPresent }), stderr: '' })
    await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow('legacy startup is blocked')
    expect(options.exec).toHaveBeenCalledExactlyOnceWith(options.helper, ['resident-paths'])
  })

test('removing the profile marker does not bypass the global recovery state check', async () => {
  const options = fixture()
  deps.lstat.mockResolvedValueOnce({})
  await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow('legacy startup is blocked')
  expect(options.exec).not.toHaveBeenCalled()
  options.exec.mockResolvedValue({ stdout: JSON.stringify({ ...environment, retainedStatePresent: true }), stderr: '' })
  await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow('legacy startup is blocked')
  expect(options.exec).toHaveBeenCalledExactlyOnceWith(options.helper, ['resident-paths'])
})

test.each(['empty file', 'corrupt file', 'directory', 'symbolic link'])('existing %s marker denies without helper discovery', async kind => {
  const options = fixture()
  deps.lstat.mockResolvedValue({ kind })
  await expect(guardMigrationStartup(dataDir, { ...options, helper: undefined })).rejects.toThrow('legacy startup is blocked')
  expect(options.exec).not.toHaveBeenCalled()
})

test.each(['EACCES', 'EIO'])('unknown profile marker error %s denies without discovery', async code => {
  const options = fixture()
  deps.lstat.mockRejectedValue(Object.assign(new Error('Cannot inspect marker'), { code }))
  await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow('Cannot verify migration state')
  expect(options.exec).not.toHaveBeenCalled()
})

test.each([undefined, ''])('Windows missing marker requires a native helper: %s', async helper => {
  const options = fixture()
  await expect(guardMigrationStartup(dataDir, { ...options, helper })).rejects.toThrow('helper')
  expect(options.exec).not.toHaveBeenCalled()
})

test('native discovery execution errors cannot become absence', async () => {
  const options = fixture()
  options.exec.mockRejectedValue(new Error('Access denied'))
  await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow('Access denied')
  expect(options.exec).toHaveBeenCalledTimes(1)
})

test.each([
  { stdout: '{}', stderr: '' }, { stdout: 'not JSON', stderr: '' },
  { stdout: JSON.stringify({ ...environment, retainedStatePresent: undefined }), stderr: '' },
  { stdout: JSON.stringify({ ...environment, recoveryRegistrationPresent: undefined }), stderr: '' },
  { stdout: JSON.stringify(environment), stderr: 'Access denied' },
])('invalid or incomplete native state cannot become absence: %j', async result => {
  const options = fixture()
  options.exec.mockResolvedValue(result)
  await expect(guardMigrationStartup(dataDir, options)).rejects.toThrow()
  expect(options.exec).toHaveBeenCalledTimes(1)
})

test('no flag bypasses the guard or enables resident admission', async () => {
  const options = fixture()
  await expect(guardMigrationStartup(dataDir, { ...options, args: ['--experimental-resident'] })).rejects.toThrow('not available')
  expect(deps.lstat).not.toHaveBeenCalled()
  expect(options.exec).not.toHaveBeenCalled()
})

test.each(['darwin', 'linux'] as const)('non-Windows %s needs no helper or discovery', async os => {
  const options = fixture()
  await expect(guardMigrationStartup(dataDir, { ...options, os, helper: undefined })).resolves.toBeUndefined()
  expect(deps.lstat).not.toHaveBeenCalled()
  expect(options.exec).not.toHaveBeenCalled()
})
