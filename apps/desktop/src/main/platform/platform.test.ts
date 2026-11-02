import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { createSocket } from 'node:dgram'
import { chmod, lstat, mkdir, mkdtemp, readdir, readFile, rm, symlink } from 'node:fs/promises'
import { createConnection, createServer, Socket } from 'node:net'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { afterEach, beforeAll, expect, test, vi } from 'vitest'
import { createMihomoClient } from '@kuro/api'
import { FakeTransport } from '@kuro/api/fake'
import { createAppStore, type Backup } from '@kuro/state'
import { fakeSnapshot } from '@kuro/state/fake'
import { assertMixedPortAvailable, createDesktopPlatform, type DesktopPlatform, type DesktopPlatformOptions, type Exec } from './index'
import { reserveTestPort } from './test-ports'

const cleanups: Array<() => Promise<void>> = []
beforeAll(async () => {
  const reservation = await reserveTestPort()
  await reservation.release()
})
afterEach(async () => {
  vi.restoreAllMocks()
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup()
})

async function freePort(): Promise<number> {
  const reservation = await reserveTestPort()
  await reservation.release()
  return reservation.port
}

async function fixture(extra: Partial<DesktopPlatformOptions> = {}) {
  const dataDir = await mkdtemp(join(process.platform === 'win32' ? tmpdir() : '/tmp', 'kuro-platform-'))
  const exec = vi.fn<Exec>(async () => ({ stdout: '', stderr: '' }))
  const mixedPort = await freePort()
  const platform = createDesktopPlatform({ dataDir, corePath: process.execPath, mixedPort, exec, ...extra })
  cleanups.push(async () => { await rm(dataDir, { force: true, recursive: true, maxRetries: 10, retryDelay: 20 }) })
  cleanups.push(() => platform.stopCore())
  return { platform, dataDir, exec, mixedPort }
}

function fakeCore(platform: () => DesktopPlatform, mixedPort: () => number, ignoreTerm = false, listenMixed = true, authMethod = 0, holdFin = false): DesktopPlatformOptions['spawn'] {
  return (_file, _args, options) => {
    const channel = platform().controlChannel()
    const path = channel.kind === 'unix' ? channel.path : channel.name
    return spawn(process.execPath, ['-e', `
      const http = require('node:http');
      ${ignoreTerm ? "process.on('SIGTERM', () => {});" : ''}
      http.createServer((req, res) => res.end('{"version":"fake"}')).listen(${JSON.stringify(path)});
      ${listenMixed ? `require('node:net').createServer(${holdFin ? '{allowHalfOpen: true}, ' : ''}socket => {
        socket.on('error', error => { if (error.code !== 'ECONNRESET') throw error; });
        socket.once('data', () => socket.write(Buffer.from([5, ${authMethod}])));
      }).listen(${mixedPort()}, '127.0.0.1');` : ''}
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
  if (process.platform !== 'win32') expect((await lstat(join(dataDir, 'profiles/a.yaml'))).mode & 0o777).toBe(0o600)
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
  // Junctions exercise both reparse-point positions without requiring Windows symlink privilege.
  await symlink(process.platform === 'win32' ? tmpdir() : '/tmp', join(dataDir, 'escape'), process.platform === 'win32' ? 'junction' : 'dir')
  await symlink(process.platform === 'win32' ? tmpdir() : '/etc/passwd', join(dataDir, 'file'), process.platform === 'win32' ? 'junction' : 'file')
  for (const name of ['escape/kuro-should-not-exist', 'file']) {
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
  const dataDir = join(resolve('/tmp'), 'x'.repeat(92))
  const platform = createDesktopPlatform({ dataDir, corePath: '/unused', mixedPort: 17890, os: 'darwin' })
  expect(platform.controlChannel()).toEqual({ kind: 'unix', path: join(dataDir, 'c') })
  expect(() => createDesktopPlatform({ dataDir: join(resolve('/tmp'), 'x'.repeat(110)), corePath: '/unused', mixedPort: 17890, os: 'darwin' })).toThrow('shorter userData')
})

test('Windows channels are randomized and never expose TCP', () => {
  const options = { dataDir: '/tmp/test', corePath: '/unused', mixedPort: 17890, os: 'win32' as const }
  const a = createDesktopPlatform(options).controlChannel()
  const b = createDesktopPlatform(options).controlChannel()
  expect(a.kind).toBe('pipe')
  if (a.kind === 'pipe') expect(a.name).toMatch(/^\\\\\.\\pipe\\kuro-[a-f0-9-]+$/)
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
  const port = await freePort()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(port, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  try { await expect(assertMixedPortAvailable(address.port)).rejects.toThrow('already in use') }
  finally { await new Promise<void>((resolve) => server.close(() => resolve())) }
  await assertMixedPortAvailable(address.port)
  await expect(assertMixedPortAvailable(0)).rejects.toThrow('Invalid mixed-port')
})

test.each(['direct', 'resident'] as const)('%s rejects UDP-only occupancy before creating an owner and releases its TCP probe', async (route) => {
  const mixedPort = await freePort()
  const udp = createSocket('udp4')
  await new Promise<void>((resolve, reject) => udp.once('error', reject).bind(mixedPort, '127.0.0.1', resolve))
  let udpOpen = true
  cleanups.push(async () => { if (udpOpen) await new Promise<void>(resolve => udp.close(resolve)) })
  const startResident = vi.fn<NonNullable<DesktopPlatformOptions['startResident']>>(async () => { throw new Error('Unexpected resident start') })
  const spawned = vi.fn<NonNullable<DesktopPlatformOptions['spawn']>>(() => { throw new Error('Unexpected Core spawn') })
  const { platform } = await fixture({ mixedPort, spawn: spawned,
    ...(route === 'resident' ? { os: 'win32', sysproxyHelperPath: 'fake.exe', startResident } : {}),
  })
  await platform.writeFileAtomic('runtime.yaml', 'mode: direct')
  await expect(platform.startCore()).rejects.toThrow(/mixed-port.*UDP/)
  expect(spawned).not.toHaveBeenCalled()
  expect(startResident).not.toHaveBeenCalled()
  const tcp = createServer()
  await new Promise<void>((resolve, reject) => tcp.once('error', reject).listen(mixedPort, '127.0.0.1', resolve))
  await new Promise<void>(resolve => tcp.close(() => resolve()))
  await new Promise<void>(resolve => udp.close(resolve))
  udpOpen = false
  await assertMixedPortAvailable(mixedPort)
  await assertMixedPortAvailable(mixedPort)
})

test('direct API-ready Core without a mixed listener fails readiness and is stopped', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  const result = await fixture({ spawn: fakeCore(() => platform, () => mixedPort, false, false), startTimeoutMs: 500 })
  platform = result.platform
  mixedPort = result.mixedPort
  await platform.writeFileAtomic('runtime.yaml', 'mode: direct')
  await expect(platform.startCore()).rejects.toThrow(/readiness timed out.*mixed-port/s)
  expect(await platform.isCoreRunning()).toBe(false)
  expect(await platform.readFile('core.pid')).toBeNull()
})

test('mixed listener readiness accepts password negotiation without sending credentials', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  const result = await fixture({ spawn: fakeCore(() => platform, () => mixedPort, false, true, 2) })
  platform = result.platform
  mixedPort = result.mixedPort
  await platform.writeFileAtomic('runtime.yaml', 'mode: direct')
  await platform.startCore()
  expect(await platform.isCoreRunning()).toBe(true)
})

test('startCore checks the latest mixed-port before spawning and never changes it', async () => {
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  const spawned = vi.fn<NonNullable<DesktopPlatformOptions['spawn']>>()
  const { platform } = await fixture({ mixedPort: () => address.port, spawn: spawned })
  try {
    await platform.applyRuntimeConfig('mode: direct')
    await expect(platform.startCore()).rejects.toThrow(`127.0.0.1:${address.port} is already in use`)
    expect(spawned).not.toHaveBeenCalled()
  } finally { await new Promise<void>((resolve) => server.close(() => resolve())) }
})

test('production readiness closes its own probe before reporting ready and permits immediate stop/rebind', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  let probe: Socket | undefined
  let coreClosed = false
  const events: string[] = []
  const destroy = Socket.prototype.destroy
  vi.spyOn(Socket.prototype, 'destroy').mockImplementation(function (this: Socket, error?: Error) {
    if (mixedPort !== undefined && this.remotePort === mixedPort && !probe) {
      probe = this
      events.push('destroy requested')
      this.once('close', () => events.push('close emitted'))
    }
    return destroy.call(this, error)
  })
  const launch = fakeCore(() => platform, () => mixedPort)!
  const result = await fixture({ spawn: (...args) => {
    const core = launch(...args)
    core.once('close', () => { coreClosed = true })
    return core
  } })
  platform = result.platform
  mixedPort = result.mixedPort
  await platform.applyRuntimeConfig('mode: direct')
  await platform.startCore()
  events.push('startCore resolved')
  const closedAtReady = probe?.closed
  expect.soft(probe).toBeDefined()
  expect.soft(closedAtReady, events.join(' -> ')).toBe(true)
  expect.soft(probe?.readableEnded, 'readiness must receive peer FIN before reporting success').toBe(true)
  await platform.stopCore()
  expect(coreClosed, 'stopCore must await the exact owned child close event').toBe(true)
  await expect(assertMixedPortAvailable(mixedPort)).resolves.toBeUndefined()
})

test('greeting without peer FIN cannot escape the existing readiness deadline', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  const result = await fixture({ spawn: fakeCore(() => platform, () => mixedPort, false, true, 0, true), startTimeoutMs: 500 })
  platform = result.platform
  mixedPort = result.mixedPort
  await platform.applyRuntimeConfig('mode: direct')
  await expect(platform.startCore()).rejects.toThrow(/readiness timed out.*SOCKS5 greeting or close timed out/s)
  expect(await platform.isCoreRunning()).toBe(false)
  expect(await platform.readFile('core.pid')).toBeNull()
})

test('start waits for readiness, writes pid and chmods socket; concurrent starts share one Core', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  const spawned = vi.fn(fakeCore(() => platform, () => mixedPort))
  const fixtureResult = await fixture({ spawn: spawned })
  platform = fixtureResult.platform
  mixedPort = fixtureResult.mixedPort
  const initial = platform.controlChannel()
  await platform.applyRuntimeConfig('mode: direct\n' + (initial.kind === 'pipe' ? `external-controller-pipe: ${JSON.stringify(initial.name)}\n` : ''))
  await Promise.all([platform.startCore(), platform.startCore()])
  expect(spawned).toHaveBeenCalledOnce()
  expect(await platform.isCoreRunning()).toBe(true)
  await new Promise<void>((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port: mixedPort })
    let peerEnded = false
    // Local destroy/close does not prove the accepted Windows socket has closed before Core stops.
    socket.once('connect', () => socket.end())
    socket.once('end', () => { peerEnded = true })
    socket.once('close', () => peerEnded ? resolve() : reject(new Error('Mixed probe closed without peer FIN')))
    socket.once('error', reject)
    socket.resume()
  })
  expect(await platform.readFile('core.pid')).toMatch(/^\d+$/)
  const channel = platform.controlChannel()
  if (process.platform === 'win32') {
    expect(channel.kind).toBe('pipe')
  } else {
    if (channel.kind !== 'unix') throw new Error('Expected unix')
    expect((await lstat(channel.path)).mode & 0o777).toBe(0o600)
    expect((await lstat(fixtureResult.dataDir)).mode & 0o777).toBe(0o700)
  }
  await platform.stopCore()
  expect(await platform.isCoreRunning()).toBe(false)
  expect(await platform.readFile('core.pid')).toBeNull()
  await assertMixedPortAvailable(mixedPort)
  await platform.startCore()
  expect(spawned).toHaveBeenCalledTimes(2)
})

test('Core that ignores SIGTERM is killed after the grace period', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  const spawned = vi.fn(fakeCore(() => platform, () => mixedPort, true)!)
  const result = await fixture({ spawn: spawned, stopTimeoutMs: 30 })
  platform = result.platform
  mixedPort = result.mixedPort
  await platform.applyRuntimeConfig('mode: direct')
  await platform.startCore()
  const pid = Number(await platform.readFile('core.pid'))
  const owned = spawned.mock.results[0]!.value
  const kill = owned.kill.bind(owned)
  // Windows SIGTERM is unconditional termination; simulate an ignored first request for this branch test.
  const signals = process.platform === 'win32' ? vi.spyOn(owned, 'kill').mockImplementation(signal =>
    signal === 'SIGTERM' ? true : kill(signal)) : undefined
  await platform.stopCore()
  if (signals) expect(signals).toHaveBeenCalledWith('SIGKILL')
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

test('unacknowledged owned Core close times out and forbids restart and proxy writes', async () => {
  let platform: DesktopPlatform
  let mixedPort: number
  let release = () => {}
  const launch = fakeCore(() => platform, () => mixedPort)!
  const result = await fixture({ stopTimeoutMs: 30, spawn: (...args) => {
    const owned = launch(...args)
    const events: EventEmitter = owned
    const emit = events.emit.bind(events)
    vi.spyOn(events, 'emit').mockImplementation((name, ...values) => {
      if (name === 'close') { release = () => { emit(name, ...values) }; return true }
      return emit(name, ...values)
    })
    return owned
  } })
  platform = result.platform
  mixedPort = result.mixedPort
  try {
    await platform.applyRuntimeConfig('mode: direct')
    await platform.startCore()
    await expect(platform.stopCore()).rejects.toThrow('Owned Core teardown did not complete')
    await expect(platform.startCore()).rejects.toThrow('shutting down')
    await expect(platform.setSystemProxy({ host: '127.0.0.1', port: mixedPort, bypass: [] })).rejects.toThrow('writes are closed')
  } finally { release() }
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
  await expect(platform.shutdown({ timeoutMs: 100 })).rejects.toThrow('denied')
  expect(order).toEqual(['proxy', 'core'])
  await expect(platform.startCore()).rejects.toThrow('shutting down')
})

test('a hanging proxy cleanup still attempts Core cleanup within the shutdown budget', async () => {
  const { platform } = await fixture()
  vi.spyOn(platform, 'clearSystemProxy').mockImplementation(() => new Promise(() => {}))
  const stop = vi.spyOn(platform, 'stopCore').mockImplementation(() => new Promise(() => {}))
  const start = Date.now()
  await expect(platform.shutdown({ timeoutMs: 60 })).rejects.toThrow('state unknown')
  expect(stop).toHaveBeenCalledOnce()
  expect(Date.now() - start).toBeLessThan(300)
})

test('repeated shutdown shares its first operation and closes proxy writes permanently', async () => {
  const { platform, exec } = await fixture({ os: 'win32' })
  const clear = vi.spyOn(platform, 'clearSystemProxy').mockImplementation(() => new Promise(() => {}))
  vi.spyOn(platform, 'stopCore').mockResolvedValue()
  const first = platform.shutdown({ timeoutMs: 40 })
  const outcome = expect(first).rejects.toThrow('state unknown')
  expect(platform.shutdown({ timeoutMs: 9000 })).toBe(first)
  await expect(platform.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow('writes are closed')
  await outcome
  expect(clear).toHaveBeenCalledOnce()
  await expect(platform.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow('writes are closed')
  expect(exec).not.toHaveBeenCalled()
})

test('an injected fetchText can use Electron networking without importing Electron', async () => {
  const fetchText = vi.fn(async () => ({ status: 200, headers: {}, body: 'profile' }))
  const { platform } = await fixture({ fetchText, powerMonitor: new EventEmitter() })
  expect(await platform.fetchText('https://example.test', { viaCore: true, userAgent: 'Clash Kuro' })).toEqual({ status: 200, headers: {}, body: 'profile' })
  expect(fetchText).toHaveBeenCalledWith('https://example.test', { viaCore: true, userAgent: 'Clash Kuro' })
})

test.skipIf(process.getuid?.() === 0)('a failed Backup import on real disk restores the pre-import data', async () => {
  const { platform, dataDir } = await fixture({ os: 'darwin' })
  const { settings } = fakeSnapshot()
  const saved = { settings: { ...settings, mixedPort: 7891 }, profiles: [], activeProfileId: null, language: 'en' }
  await platform.writeFileAtomic('settings.json', JSON.stringify(saved))
  await platform.writeFileAtomic('override.yaml', 'rules+: [MATCH,DIRECT]\n')
  const app = await createAppStore({
    platform, client: createMihomoClient(new FakeTransport()), systemLocale: () => 'en',
    buildRuntimeConfig: () => '', refreshProfile: async (profile) => profile
  })
  const before = JSON.parse(await app.exportBackup()) as Backup
  const files = async () => ({
    settings: await readFile(join(dataDir, 'settings.json'), 'utf8'),
    override: await readFile(join(dataDir, 'override.yaml'), 'utf8'),
    profiles: await readdir(join(dataDir, 'profiles'))
  })
  await mkdir(join(dataDir, 'profiles'))
  const original = await files()
  const incoming: Backup = {
    ...before,
    settings: { ...before.settings, profiles: [{ ...fakeSnapshot().profiles[0]!, id: 'p2' }], activeProfileId: 'p2' },
    profiles: { p2: 'proxies: []\n' }, override: null
  }
  // Only the imported Profile is written into profiles/; rename into a read-only dir fails, restore never writes there.
  await chmod(join(dataDir, 'profiles'), 0o555)
  cleanups.push(() => chmod(join(dataDir, 'profiles'), 0o700))
  await expect(app.importBackup(JSON.stringify(incoming))).rejects.toThrow('The previous data was restored')
  expect(await files()).toEqual(original)
  const after = JSON.parse(await app.exportBackup()) as Backup
  expect({ ...after, createdAt: '' }).toEqual({ ...before, createdAt: '' })
  const [recovery] = await readdir(join(dataDir, 'backups'))
  expect(JSON.parse(await readFile(join(dataDir, 'backups', recovery!), 'utf8'))).toMatchObject({ settings: saved, override: before.override })
  expect(await app.run('setMode', { mode: 'direct' })).toMatchObject({ ok: true })
})
