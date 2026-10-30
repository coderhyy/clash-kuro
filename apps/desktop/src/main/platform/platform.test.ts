import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { lstat, mkdtemp, readdir, rm, symlink } from 'node:fs/promises'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { afterEach, expect, test, vi } from 'vitest'
import { assertMixedPortAvailable, createDesktopPlatform, type DesktopPlatform, type DesktopPlatformOptions, type Exec } from './index'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => {
  vi.restoreAllMocks()
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup()
})

async function freePort(): Promise<number> {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing TCP port')
  await new Promise<void>((resolve) => server.close(() => resolve()))
  return address.port
}

async function fixture(extra: Partial<DesktopPlatformOptions> = {}) {
  const dataDir = await mkdtemp('/tmp/tern-platform-')
  const exec = vi.fn<Exec>(async () => ({ stdout: '', stderr: '' }))
  const platform = createDesktopPlatform({ dataDir, corePath: process.execPath, mixedPort: await freePort(), exec, ...extra })
  cleanups.push(async () => { await rm(dataDir, { force: true, recursive: true }) })
  cleanups.push(() => platform.stopCore())
  return { platform, dataDir, exec }
}

function fakeCore(platform: () => DesktopPlatform, ignoreTerm = false): DesktopPlatformOptions['spawn'] {
  return (_file, _args, options) => {
    const channel = platform().controlChannel()
    const path = channel.kind === 'unix' ? channel.path : channel.name
    return spawn(process.execPath, ['-e', `
      const http = require('node:http');
      ${ignoreTerm ? "process.on('SIGTERM', () => {});" : ''}
      http.createServer((req, res) => res.end('{"version":"fake"}')).listen(${JSON.stringify(path)});
    `], options)
  }
}

test('atomic files stay inside dataDir, replace old content and clean temp files', async () => {
  const { platform, dataDir } = await fixture()
  expect(await platform.readFile('missing')).toBeNull()
  await platform.writeFileAtomic('profiles/a.yaml', 'first')
  await platform.writeFileAtomic('profiles/a.yaml', 'second')
  expect(await platform.readFile('profiles/a.yaml')).toBe('second')
  expect(await readdir(join(dataDir, 'profiles'))).toEqual(['a.yaml'])
  expect((await lstat(join(dataDir, 'profiles/a.yaml'))).mode & 0o777).toBe(0o600)
  await platform.removeFile('profiles/a.yaml')
  await platform.removeFile('profiles/a.yaml')
  expect(await platform.readFile('profiles/a.yaml')).toBeNull()
})

test('concurrent writes can create the same nested parent directory', async () => {
  const { platform } = await fixture()
  await Promise.all(Array.from({ length: 12 }, (_, index) => platform.writeFileAtomic(`profiles/nested/${index}.yaml`, String(index))))
  expect(await platform.readFile('profiles/nested/11.yaml')).toBe('11')
})

test.each(['../outside', 'a/../outside', '/etc/passwd', 'C:\\Windows\\file', '\\\\server\\share', 'a\\..\\file', '', 'a\0b', 'a/./b', 'file:stream'])('rejects unsafe file name %j on every operation', async (name) => {
  const { platform } = await fixture()
  await expect(platform.readFile(name)).rejects.toThrow('relative path')
  await expect(platform.writeFileAtomic(name, 'no')).rejects.toThrow('relative path')
  await expect(platform.removeFile(name)).rejects.toThrow('relative path')
})

test('rejects symlink escapes in both parents and final file', async () => {
  const { platform, dataDir } = await fixture()
  await symlink('/tmp', join(dataDir, 'escape'))
  await symlink('/etc/passwd', join(dataDir, 'file'))
  for (const name of ['escape/tern-should-not-exist', 'file']) {
    await expect(platform.readFile(name)).rejects.toThrow('Symlinks')
    await expect(platform.writeFileAtomic(name, 'no')).rejects.toThrow('Symlinks')
    await expect(platform.removeFile(name)).rejects.toThrow('Symlinks')
  }
})

test('validates a private temp config before rename and preserves old runtime on failure', async () => {
  const { platform, dataDir, exec } = await fixture()
  expect(await platform.applyRuntimeConfig('mode: direct')).toEqual({ ok: true })
  const args = exec.mock.calls[0]![1]
  expect(args.slice(0, 4)).toEqual(['-t', '-d', dataDir, '-f'])
  expect(args[4]).toMatch(/runtime\.yaml\..*\.tmp$/)
  exec.mockRejectedValueOnce(Object.assign(new Error('invalid config'), { stderr: 'bad YAML' }))
  expect(await platform.applyRuntimeConfig('bad')).toEqual({ ok: false, error: 'invalid config\nbad YAML' })
  expect(await platform.readFile('runtime.yaml')).toBe('mode: direct')
  expect(await readdir(dataDir)).toEqual(['runtime.yaml'])
})

test('shortens a long unix path inside dataDir or gives an actionable error', () => {
  const dataDir = '/tmp/' + 'x'.repeat(92)
  const platform = createDesktopPlatform({ dataDir, corePath: '/unused', mixedPort: 17890 })
  expect(platform.controlChannel()).toEqual({ kind: 'unix', path: join(dataDir, 'c') })
  expect(() => createDesktopPlatform({ dataDir: '/tmp/' + 'x'.repeat(110), corePath: '/unused', mixedPort: 17890 })).toThrow('shorter userData')
})

test('Windows channels are randomized and never expose TCP', () => {
  const options = { dataDir: '/tmp/test', corePath: '/unused', mixedPort: 17890, os: 'win32' as const }
  const a = createDesktopPlatform(options).controlChannel()
  const b = createDesktopPlatform(options).controlChannel()
  expect(a.kind).toBe('pipe')
  if (a.kind === 'pipe') expect(a.name).toMatch(/^\\\\\.\\pipe\\tern-[a-f0-9-]+$/)
  expect(a).not.toEqual(b)
})

test('Windows Core restarts rotate and revalidate the runtime pipe scalar', async () => {
  const { platform, exec } = await fixture({
    os: 'win32', startTimeoutMs: 25, stopTimeoutMs: 100,
    spawn: (_file, _args, options) => spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], options),
  })
  const first = platform.controlChannel()
  if (first.kind !== 'pipe') throw new Error('Expected pipe')
  await platform.applyRuntimeConfig(`mode: direct\nexternal-controller-pipe: ${JSON.stringify(first.name)}\n`)
  await expect(platform.startCore()).rejects.toThrow('readiness timed out')
  await expect(platform.startCore()).rejects.toThrow('readiness timed out')
  const second = platform.controlChannel()
  if (second.kind !== 'pipe') throw new Error('Expected pipe')
  expect(second.name).not.toBe(first.name)
  expect(await platform.readFile('runtime.yaml')).toContain(`external-controller-pipe: ${JSON.stringify(second.name)}`)
  expect(exec.mock.calls.filter(([, args]) => args[0] === '-t')).toHaveLength(2)
})

test('port occupancy is readable and invalid ports never reach listen', async () => {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  try { await expect(assertMixedPortAvailable(address.port)).rejects.toThrow('already in use') }
  finally { await new Promise<void>((resolve) => server.close(() => resolve())) }
  await assertMixedPortAvailable(address.port)
  await expect(assertMixedPortAvailable(0)).rejects.toThrow('Invalid mixed-port')
})

test('startCore checks the latest mixed-port before spawning and never changes it', async () => {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  const spawned = vi.fn(fakeCore(() => platform))
  const { platform } = await fixture({ mixedPort: () => address.port, spawn: spawned })
  try {
    await platform.applyRuntimeConfig('mode: direct')
    await expect(platform.startCore()).rejects.toThrow(`127.0.0.1:${address.port} is already in use`)
    expect(spawned).not.toHaveBeenCalled()
  } finally { await new Promise<void>((resolve) => server.close(() => resolve())) }
})

test('start waits for readiness, writes pid and chmods socket; concurrent starts share one Core', async () => {
  let platform: DesktopPlatform
  const spawned = vi.fn(fakeCore(() => platform))
  const fixtureResult = await fixture({ spawn: spawned })
  platform = fixtureResult.platform
  await platform.applyRuntimeConfig('mode: direct')
  await Promise.all([platform.startCore(), platform.startCore()])
  expect(spawned).toHaveBeenCalledOnce()
  expect(await platform.isCoreRunning()).toBe(true)
  expect(await platform.readFile('core.pid')).toMatch(/^\d+$/)
  const channel = platform.controlChannel()
  if (channel.kind !== 'unix') throw new Error('Expected unix')
  expect((await lstat(channel.path)).mode & 0o777).toBe(0o600)
  expect((await lstat(fixtureResult.dataDir)).mode & 0o777).toBe(0o700)
  await platform.stopCore()
  expect(await platform.isCoreRunning()).toBe(false)
  expect(await platform.readFile('core.pid')).toBeNull()
  await platform.startCore()
  expect(spawned).toHaveBeenCalledTimes(2)
})

test('Core that ignores SIGTERM is killed after the grace period', async () => {
  let platform: DesktopPlatform
  const result = await fixture({ spawn: fakeCore(() => platform, true), stopTimeoutMs: 30 })
  platform = result.platform
  await platform.applyRuntimeConfig('mode: direct')
  await platform.startCore()
  const pid = Number(await platform.readFile('core.pid'))
  await platform.stopCore()
  expect(() => process.kill(pid, 0)).toThrow()
  expect(await platform.readFile('core.pid')).toBeNull()
})

test('failed readiness and failed spawn leave no child or pid', async () => {
  const { platform } = await fixture({
    startTimeoutMs: 40, stopTimeoutMs: 40,
    spawn: (_file, _args, options) => spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], options),
  })
  await platform.applyRuntimeConfig('mode: direct')
  await expect(platform.startCore()).rejects.toThrow('readiness timed out')
  expect(await platform.isCoreRunning()).toBe(false)
  expect(await platform.readFile('core.pid')).toBeNull()
  const second = await fixture({ spawn: (_file, args, options) => spawn('/does/not/exist', args, options) })
  await second.platform.applyRuntimeConfig('mode: direct')
  await expect(second.platform.startCore()).rejects.toThrow('ENOENT')
  expect(await second.platform.readFile('core.pid')).toBeNull()
})

test('stale or unrelated pid is removed without sending a signal', async () => {
  const { platform, exec } = await fixture({ os: 'darwin' })
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'])
  if (!unrelated.pid) throw new Error('Missing pid')
  const pid = unrelated.pid
  cleanups.push(async () => { unrelated.kill('SIGKILL') })
  await platform.writeFileAtomic('core.pid', String(pid))
  exec.mockResolvedValue({ stdout: '/bin/sh\n', stderr: '' })
  await expect(platform.startCore()).rejects.toThrow('No Runtime Config')
  expect(await platform.readFile('core.pid')).toBeNull()
  expect(() => process.kill(pid, 0)).not.toThrow()
  expect(exec).toHaveBeenCalledWith('/bin/ps', ['-ww', '-p', String(pid), '-o', 'comm='])
})

test('an orphan with the same executable path is terminated before port detection', async () => {
  const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'])
  if (!unrelated.pid) throw new Error('Missing pid')
  const pid = unrelated.pid
  cleanups.push(async () => { unrelated.kill('SIGKILL') })
  const { platform, exec } = await fixture({ os: 'darwin' })
  exec.mockResolvedValue({ stdout: process.execPath, stderr: '' })
  await platform.writeFileAtomic('core.pid', String(pid))
  await expect(platform.startCore()).rejects.toThrow('No Runtime Config')
  expect(() => process.kill(pid, 0)).toThrow()
  expect(await platform.readFile('core.pid')).toBeNull()
})

test('shutdown clears proxy before Core, even on permission error, and prevents restart', async () => {
  const { platform } = await fixture()
  const order: string[] = []
  vi.spyOn(platform, 'clearSystemProxy').mockImplementation(async () => { order.push('proxy'); throw new Error('denied') })
  vi.spyOn(platform, 'stopCore').mockImplementation(async () => { order.push('core') })
  await platform.shutdown({ timeoutMs: 100 })
  expect(order).toEqual(['proxy', 'core'])
  await expect(platform.startCore()).rejects.toThrow('shutting down')
})

test('a hanging proxy cleanup still attempts Core cleanup within the shutdown budget', async () => {
  const { platform } = await fixture()
  vi.spyOn(platform, 'clearSystemProxy').mockImplementation(() => new Promise(() => {}))
  const stop = vi.spyOn(platform, 'stopCore').mockImplementation(() => new Promise(() => {}))
  const start = Date.now()
  await platform.shutdown({ timeoutMs: 60 })
  expect(stop).toHaveBeenCalledOnce()
  expect(Date.now() - start).toBeLessThan(300)
})

test('an injected fetchText can use Electron networking without importing Electron', async () => {
  const fetchText = vi.fn(async () => ({ status: 200, headers: {}, body: 'profile' }))
  const { platform } = await fixture({ fetchText, powerMonitor: new EventEmitter() })
  expect(await platform.fetchText('https://example.test', { viaCore: true, userAgent: 'Tern' })).toEqual({ status: 200, headers: {}, body: 'profile' })
  expect(fetchText).toHaveBeenCalledWith('https://example.test', { viaCore: true, userAgent: 'Tern' })
})
