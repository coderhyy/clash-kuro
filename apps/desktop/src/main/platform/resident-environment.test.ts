import { expect, test, vi } from 'vitest'
import { inspectResidentEnvironment } from './resident-environment'

const value = { command: 'resident-paths', ok: true, userSid: 'S-1-5-21-1-2-3-1001',
  recoveryDirectory: 'C:\\Users\\fixture\\AppData\\Local\\ClashKuro\\Recovery',
  retainedStatePresent: false, recoveryRegistrationPresent: false }
test('native root discovery is one read-only command, independent of environment defaults', async () => {
  const exec = vi.fn(async () => ({ stdout: JSON.stringify(value), stderr: '' }))
  expect(await inspectResidentEnvironment('trusted-helper.exe', exec)).toEqual({
    recoveryDirectory: value.recoveryDirectory, userSid: value.userSid,
    retainedStatePresent: false, recoveryRegistrationPresent: false })
  expect(exec).toHaveBeenCalledExactlyOnceWith('trusted-helper.exe', ['resident-paths'])
})

test.each([[false, false], [true, false], [false, true], [true, true]])(
  'native presence flags remain booleans, not ownership proof: %s, %s', async (retainedStatePresent, recoveryRegistrationPresent) => {
    const exec = vi.fn(async () => ({ stdout: JSON.stringify({ ...value, retainedStatePresent, recoveryRegistrationPresent }), stderr: '' }))
    expect(await inspectResidentEnvironment('helper.exe', exec)).toEqual({
      recoveryDirectory: value.recoveryDirectory, userSid: value.userSid, retainedStatePresent, recoveryRegistrationPresent })
    expect(exec).toHaveBeenCalledExactlyOnceWith('helper.exe', ['resident-paths'])
  })

test.each([
  null, {}, { ...value, ok: false }, { ...value, command: 'get' }, { ...value, userSid: '' },
  ...['retainedStatePresent', 'recoveryRegistrationPresent'].flatMap(key =>
    [undefined, null, 0, 1, 'false', 'true', [], {}].map(flag => ({ ...value, [key]: flag }))),
  ...['relative', '\\\\server\\share\\ClashKuro\\Recovery', 'C:\\Users\\fixture\\..\\ClashKuro\\Recovery',
    'C:\\Other', value.recoveryDirectory + '\\', value.recoveryDirectory + '\0'].map(recoveryDirectory => ({ ...value, recoveryDirectory })),
])('invalid native discovery fails closed without fallback: %j', async input => {
  const exec = vi.fn(async () => ({ stdout: JSON.stringify(input), stderr: '' }))
  await expect(inspectResidentEnvironment('helper.exe', exec)).rejects.toThrow()
  expect(exec).toHaveBeenCalledTimes(1)
})

test('collector failure or diagnostics cannot become a default root', async () => {
  await expect(inspectResidentEnvironment('helper.exe', async () => { throw new Error('Access denied') })).rejects.toThrow('Access denied')
  await expect(inspectResidentEnvironment('helper.exe', async () => ({ stdout: JSON.stringify(value), stderr: 'warning' })))
    .rejects.toThrow('invalid')
})
