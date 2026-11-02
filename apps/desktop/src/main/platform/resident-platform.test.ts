import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createServer } from 'node:net'
import { afterEach, expect, test, vi } from 'vitest'
import { createDesktopPlatform } from './index'
import type { startResidentSession } from './resident-session'

vi.mock('./transport', () => ({ createSocketTransport: vi.fn(() => ({
  request: vi.fn(async () => ({ status: 200 })),
})) }))
const cleanups: Array<() => Promise<void>> = []
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup() })

async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), 'kuro-resident-platform-'))
  cleanups.push(() => rm(dir, { recursive: true, force: true }))
  const socket = createServer()
  await new Promise<void>(resolve => socket.listen(0, '127.0.0.1', resolve))
  const address = socket.address()
  if (!address || typeof address === 'string') throw new Error('Missing test port')
  await new Promise<void>(resolve => socket.close(() => resolve()))
  let exit!: (value: { code: number | null; signal: NodeJS.Signals | null }) => void
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => { exit = resolve })
  const request = vi.fn(async (args: readonly string[]) => ({ stdout: JSON.stringify({
    command: args[0], ok: true, connections: [{ name: null, flags: 1 }],
  }), stderr: '' }))
  const close = vi.fn(async () => { exit({ code: 0, signal: null }) })
  const session = { request, close, exited, diagnostics: () => '', helper: 'fake', journal: 'fake' }
  const start = vi.fn<typeof startResidentSession>(async () => session)
  const exec = vi.fn(async () => ({ stdout: '', stderr: '' }))
  const execSync = vi.fn(() => '')
  const platform = createDesktopPlatform({ dataDir: dir, corePath: process.execPath, os: 'win32',
    mixedPort: address.port, sysproxyHelperPath: join(dir, 'fake.exe'), startResident: start, exec, execSync })
  await platform.writeFileAtomic('runtime.yaml', 'external-controller-pipe: "original"\n')
  return { platform, start, request, close, session, exec, execSync, exit }
}

test('resident routes proxy commands through owner without per-call log or one-shot fallback', async () => {
  const f = await fixture()
  await expect(f.platform.setSystemProxy({ host: '127.0.0.1', port: 7891, bypass: [] })).rejects.toThrow()
  expect(f.exec).not.toHaveBeenCalled()
  // A rejected write poisons the proxy adapter: use a fresh lifetime for normal admission.
  const g = await fixture()
  await g.platform.startCore()
  await g.platform.setSystemProxy({ host: '127.0.0.1', port: 7891, bypass: [] })
  expect(g.request.mock.calls.at(-1)?.[0]).toEqual(['set', '--host', '127.0.0.1', '--port', '7891', '--bypass', ''])
  expect(g.exec).not.toHaveBeenCalled()
  await g.platform.shutdown({ timeoutMs: 2500 })
  expect(g.close).toHaveBeenCalledTimes(1)
  await expect(g.platform.setSystemProxy({ host: '127.0.0.1', port: 7891, bypass: [] })).rejects.toThrow(/shutting down/)
})

test('normal resident stop permits restart, rotates pipe and never writes a helper pid as Core pid', async () => {
  const f = await fixture()
  await f.platform.startCore()
  const before = f.platform.controlChannel()
  expect(await f.platform.readFile('core.pid')).toBeNull()
  await f.platform.stopCore()
  expect(await f.platform.isCoreRunning()).toBe(false)
  f.start.mockResolvedValueOnce({ ...f.session, exited: new Promise(() => {}) })
  await f.platform.startCore()
  expect(f.platform.controlChannel()).not.toEqual(before)
  expect(f.start).toHaveBeenCalledTimes(2)
  await f.platform.setSystemProxy({ host: '127.0.0.1', port: 7892, bypass: [] })
  expect(f.request.mock.calls.at(-1)?.[0]).toContain('7892')
  await f.platform.stopCore()
})

test('cleanup failure closes lifetime and repeated shutdown shares the same rejection', async () => {
  const f = await fixture()
  await f.platform.startCore()
  f.close.mockRejectedValue(new Error('native cleanup unknown'))
  const first = f.platform.shutdown({ timeoutMs: 100 })
  expect(f.platform.shutdown({ timeoutMs: 9999 })).toBe(first)
  await expect(first).rejects.toThrow('unknown')
  await expect(f.platform.startCore()).rejects.toThrow()
  expect(f.close).toHaveBeenCalledTimes(1)
})

test('unexpected helper exit cannot turn shutdown into successful cleanup', async () => {
  const f = await fixture()
  await f.platform.startCore()
  f.close.mockRejectedValue(new Error('native cleanup unverified (42)'))
  f.exit({ code: 42, signal: null })
  await Promise.resolve()
  await expect(f.platform.shutdown({ timeoutMs: 100 })).rejects.toThrow('unverified')
  await expect(f.platform.getSystemProxy()).rejects.toThrow()
})

test('native cleanup may finish before Electron handles exit; preserve its evidence without reopening writes', async () => {
  const f = await fixture()
  await f.platform.startCore()
  f.exit({ code: 0, signal: null })
  await Promise.resolve()
  expect(await f.platform.isCoreRunning()).toBe(false)
  await expect(f.platform.setSystemProxy({ host: '127.0.0.1', port: 7891, bypass: [] })).rejects.toThrow()
  await expect(f.platform.shutdown({ timeoutMs: 100 })).resolves.toBeUndefined()
  expect(f.close).toHaveBeenCalledTimes(1)
  await expect(f.platform.startCore()).rejects.toThrow()
})

test('session hook never starts another helper or claims synchronous clear succeeded', async () => {
  const f = await fixture()
  await f.platform.startCore()
  const report = f.platform.clearSystemProxySync({ timeoutMs: 1500 })
  expect(report).toMatchObject({ ran: false, ok: false })
  expect(f.execSync).not.toHaveBeenCalled()
  await expect(f.platform.startCore()).rejects.toThrow('shutting down')
})

test('session trigger and shutdown share in-flight cleanup, rather than reporting early success', async () => {
  const f = await fixture()
  await f.platform.startCore()
  let finish!: () => void
  f.close.mockImplementation(() => new Promise<void>(resolve => { finish = resolve }))
  f.platform.clearSystemProxySync({ timeoutMs: 1500 })
  const shutdown = f.platform.shutdown({ timeoutMs: 20 })
  await expect(shutdown).rejects.toThrow('deadline exceeded')
  expect(f.platform.shutdown({ timeoutMs: 9000 })).toBe(shutdown)
  expect(f.close).toHaveBeenCalledTimes(1)
  finish()
  await expect(f.platform.startCore()).rejects.toThrow('shutting down')
})

test('shutdown aborts a pending startup; no Core may be created after that signal', async () => {
  const f = await fixture()
  let entered!: () => void
  const waiting = new Promise<void>(resolve => { entered = resolve })
  f.start.mockImplementation(options => new Promise((_, reject) => {
    options.signal!.addEventListener('abort', () => reject(new Error('startup aborted')), { once: true })
    entered()
  }))
  const startup = f.platform.startCore()
  const assertion = expect(startup).rejects.toThrow('startup aborted')
  await waiting
  await f.platform.shutdown({ timeoutMs: 100 }).catch(() => {})
  await assertion
  expect(f.start.mock.calls[0]![0].signal?.aborted).toBe(true)
})
