import { afterEach, expect, test, vi } from 'vitest'
import { startResidentSession } from './resident-session'

const deps = vi.hoisted(() => ({
  spawn: vi.fn(), prepare: vi.fn(), recover: vi.fn(), client: vi.fn(),
}))
vi.mock('node:child_process', () => ({ spawn: deps.spawn }))
vi.mock('./recovery-helper', () => ({ prepareRecoveryHelper: deps.prepare }))
vi.mock('./resident-recovery', () => ({ recoverResident: deps.recover }))
vi.mock('./resident-client', () => ({ residentClient: deps.client }))
afterEach(() => { vi.resetAllMocks(); vi.useRealTimers() })

function fixture() {
  let finish!: (value: { code: number; signal: null; report: { ok: boolean; timedOut: boolean; coreGone: boolean } }) => void
  const closed = new Promise<Parameters<typeof finish>[0]>(resolve => { finish = resolve })
  const child = { kill: vi.fn(), exitCode: null, signalCode: null }
  const client = { ready: Promise.resolve(), closed, exited: closed,
    request: vi.fn(), diagnostics: () => '', close: vi.fn() }
  deps.spawn.mockReturnValue(child)
  deps.prepare.mockResolvedValue('retained.exe')
  deps.recover.mockResolvedValue(undefined)
  deps.client.mockReturnValue(client)
  const authorize = vi.fn(async () => ({ receiptDigest: 'a'.repeat(64), evidenceDigest: 'b'.repeat(64) }))
  const options = { helper: 'shipping.exe', recoveryDirectory: 'retained', dataDir: 'private-data', core: 'fake-core.exe',
    server: '127.0.0.1:7891', log: 'private-log', authorize }
  const complete = (ok = true) => finish({ code: ok ? 0 : 42, signal: null, report: { ok, timedOut: !ok, coreGone: true } })
  return { options, child, client, complete }
}

test('admitted session has one reservation child, no separate replay/ownership handoff', async () => {
  const f = fixture()
  const session = await startResidentSession(f.options)
  expect(deps.recover).not.toHaveBeenCalled()
  expect(deps.spawn).toHaveBeenCalledExactlyOnceWith('retained.exe', [
    'reserve', '--core', 'fake-core.exe', '--data', 'private-data',
    '--expected-server', '127.0.0.1:7891', '--log', 'private-log'],
  { windowsHide: true, detached: true, stdio: 'pipe' })
  expect(deps.client).toHaveBeenCalledExactlyOnceWith(f.child, 10_000, f.options.authorize)
  expect(f.options.authorize).not.toHaveBeenCalled() // Only validated native reservation may invoke policy.
  const first = session.close()
  expect(session.close()).toBe(first)
  expect(f.client.close).toHaveBeenCalledTimes(1)
  f.complete()
  await first
})

test('abort during retained publication cannot spawn a writer', async () => {
  const f = fixture(), abort = new AbortController()
  deps.prepare.mockImplementation(async () => { abort.abort(); return 'retained.exe' })
  await expect(startResidentSession({ ...f.options, signal: abort.signal })).rejects.toMatchObject({ name: 'AbortError' })
  expect(deps.recover).not.toHaveBeenCalled()
  expect(deps.spawn).not.toHaveBeenCalled()
})

test('missing authorization cannot fall back to legacy replay or create a helper', async () => {
  const f = fixture()
  await expect(startResidentSession({ ...f.options, authorize: undefined })).rejects.toThrow('migration authorization')
  expect(deps.prepare).not.toHaveBeenCalled()
  expect(deps.recover).not.toHaveBeenCalled()
  expect(deps.spawn).not.toHaveBeenCalled()
})

test('reservation failure waits for exact child closure and never starts separate recovery', async () => {
  const f = fixture()
  f.client.ready = Promise.reject(new Error('Admission refused'))
  f.client.close.mockImplementation(() => f.complete(false))
  await expect(startResidentSession(f.options)).rejects.toThrow('Admission refused')
  expect(deps.recover).not.toHaveBeenCalled()
  expect(deps.spawn).toHaveBeenCalledTimes(1)
  expect(f.child.kill).not.toHaveBeenCalled()
})

test('close timeout is failure, never success or permission for a second owner', async () => {
  vi.useFakeTimers()
  const f = fixture(), session = await startResidentSession(f.options)
  const first = session.close()
  const failed = expect(first).rejects.toThrow('new proxy writes forbidden')
  await vi.advanceTimersByTimeAsync(2499)
  expect(session.close()).toBe(first)
  expect(f.child.kill).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1)
  await failed
  expect(f.child.kill).toHaveBeenCalledExactlyOnceWith('SIGKILL')
  f.complete(false)
  expect(deps.spawn).toHaveBeenCalledTimes(1)
})
