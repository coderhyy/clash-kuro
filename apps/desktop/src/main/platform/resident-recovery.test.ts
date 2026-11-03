import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { afterEach, expect, test, vi } from 'vitest'
const { spawn } = vi.hoisted(() => ({ spawn: vi.fn() }))
vi.mock('node:child_process', () => ({ spawn }))
import { recoverResident } from './resident-recovery'

function fixture(report: unknown, code = 0, hang = false) {
  const child = Object.assign(new EventEmitter(), {
    stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
    pid: 123, exitCode: null as number | null, signalCode: null,
    kill: vi.fn(() => true),
  })
  spawn.mockReturnValue(child)
  if (!hang) setTimeout(() => {
    if (report) child.stdout.write(JSON.stringify(report) + '\n')
    child.stdout.end()
    child.exitCode = code
    child.emit('exit', code, null)
    child.emit('close', code, null)
  }, 0)
  return child
}
afterEach(() => vi.clearAllMocks())
const ok = { command: 'shutdown', protocol: 3, firstTrigger: 64, queryEvents: 0, endEvents: 0,
  ok: true, timedOut: false, coreGone: true, corePid: 0, durationMs: 10 }
test('only a drained successful recovery report admits the caller to proceed', async () => {
  const child = fixture(ok)
  await recoverResident('helper', 'log')
  expect(child.kill).not.toHaveBeenCalled()
  expect(spawn).toHaveBeenCalledWith('helper', ['recover-admitted', '--log', 'log'], expect.objectContaining({ windowsHide: true, detached: true }))
})
test.each([null, { ...ok, corePid: 123 }, { ...ok, ok: false }, { ...ok, timedOut: true }])('missing or invalid recovery evidence rejects even exit zero: %j', async report => {
  fixture(report)
  await expect(recoverResident('helper', 'log')).rejects.toThrow('new writes forbidden')
})
test('budget expiry requests exact-child termination but never reports recovery success', async () => {
  const child = fixture(null, 0, true)
  await expect(recoverResident('helper', 'log', 30)).rejects.toThrow('writer state unknown')
  expect(child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
})
