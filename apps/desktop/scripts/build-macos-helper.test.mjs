import { afterEach, expect, test, vi } from 'vitest'
import { runNativeCheck } from './build-macos-helper.mjs'

const prefix = '[native-check] '
afterEach(() => vi.restoreAllMocks())
function events(spy) {
  return spy.mock.calls.map(([message]) => JSON.parse(message.slice(prefix.length)))
}

test('native check logs its stage and preserves a successful return', () => {
  const log = vi.spyOn(console, 'error').mockImplementation(() => {})
  const result = runNativeCheck('fixture-success', process.execPath, ['-e', 'process.exit(0)'], { stdio: 'inherit', timeout: 2_000 })
  expect(result).toBeNull()
  expect(events(log)).toMatchObject([
    { stage: 'fixture-success', event: 'started', timeoutMs: 2_000 },
    { stage: 'fixture-success', event: 'passed', status: 0 },
  ])
  expect(events(log)[1].elapsedMs).toBeGreaterThanOrEqual(0)
})

test('native check reports the actual child exit without inventing a timeout', () => {
  const log = vi.spyOn(console, 'error').mockImplementation(() => {})
  let failure
  try {
    runNativeCheck('fixture-exit', process.execPath, ['-e', 'process.exit(7)'], { stdio: 'inherit', timeout: 2_000 })
  } catch (error) { failure = error }
  expect(failure?.status).toBe(7)
  expect(failure?.signal).toBeNull()
  expect(events(log)[1]).toMatchObject({ event: 'failed', status: 7, signal: null, code: null })
})

test('native check distinguishes the parent timeout from child signal termination', () => {
  const log = vi.spyOn(console, 'error').mockImplementation(() => {})
  let failure
  try {
    runNativeCheck('fixture-timeout', process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'inherit', timeout: 50 })
  } catch (error) { failure = error }
  expect(failure?.code).toBe('ETIMEDOUT')
  expect(failure?.signal).toBe('SIGTERM')
  expect(events(log)[1]).toMatchObject({ event: 'failed', status: null, signal: 'SIGTERM', code: 'ETIMEDOUT', timeoutMs: 50 })
})

test.skipIf(process.platform === 'win32')('native check distinguishes the native watchdog signal from the parent timeout', () => {
  const log = vi.spyOn(console, 'error').mockImplementation(() => {})
  let failure
  try {
    runNativeCheck('fixture-watchdog', process.execPath, ['-e', "process.kill(process.pid, 'SIGALRM')"], { stdio: 'inherit', timeout: 2_000 })
  } catch (error) { failure = error }
  expect(failure?.signal).toBe('SIGALRM')
  expect(failure?.code).toBeUndefined()
  expect(events(log)[1]).toMatchObject({ event: 'failed', status: null, signal: 'SIGALRM', code: null })
})
