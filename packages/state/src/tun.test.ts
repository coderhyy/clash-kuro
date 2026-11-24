import { expect, test, vi } from 'vitest'
import type { TunSessionConfig, TunStatus } from '@kuro/core'
import { FakePlatform } from '@kuro/core/fake'
import { FakeTransport } from '@kuro/api/fake'
import { createMihomoClient } from '@kuro/api'
import { FakeTunPlatform, fakeSnapshot } from './fake'
import { createAppStore, type Backup } from './index'

const readyOff: TunStatus = { availability: 'ready', state: 'off' }
type TestPlatform = FakePlatform & { tun: FakeTunPlatform }
const session: TunSessionConfig = {
  version: 1, template: 'macos-dual-stack-v1', mode: 'rule', proxies: [], groups: [],
  rules: [{ type: 'MATCH', value: '', target: 'DIRECT', noResolve: false }],
  dns: { nameservers: ['192.0.2.53'], bootstrap: ['192.0.2.53'], proxyNameservers: ['192.0.2.53'], policies: [] },
}

async function setupTun(status: TunStatus = readyOff, initialize?: (platform: TestPlatform) => void) {
  const platform = Object.assign(new FakePlatform(), { tun: new FakeTunPlatform({ ...status }) })
  const snapshot = fakeSnapshot()
  platform.files.set('settings.json', JSON.stringify({ settings: snapshot.settings, profiles: snapshot.profiles, activeProfileId: 'p1' }))
  platform.files.set('profiles/p1.yaml', 'proxies: []')
  platform.runtimeConfig = 'old ordinary config'
  platform.coreRunning = true
  initialize?.(platform)
  const transport = new FakeTransport().on('GET', '/proxies', { status: 200, body: { proxies: {} } })
  const onQuit = vi.fn()
  const buildTunConfig = vi.fn(() => session)
  const app = await createAppStore({
    platform, client: createMihomoClient(transport), systemLocale: () => 'en',
    buildRuntimeConfig: () => 'proxies: []', refreshProfile: async (profile) => profile,
    buildTunConfig,
    hooks: { onQuit }
  })
  return { app, platform, tun: platform.tun, transport, onQuit, buildTunConfig }
}

test('rejected TUN configuration preserves the working ordinary mode and never starts the helper', async () => {
  const { app, platform, tun, buildTunConfig } = await setupTun()
  buildTunConfig.mockImplementation(() => { throw new Error('TUN Profile.dns: unsupported DoH resolver') })
  const stop = vi.spyOn(platform, 'stopCore')
  const clear = vi.spyOn(platform, 'clearSystemProxy')
  const start = vi.spyOn(tun, 'start')
  const result = await app.run('setTun', { enabled: true })
  expect(result).toEqual({ ok: false, error: 'TUN Profile.dns: unsupported DoH resolver' })
  expect(stop).not.toHaveBeenCalled()
  expect(clear).not.toHaveBeenCalled()
  expect(start).not.toHaveBeenCalled()
  expect(platform.coreRunning).toBe(true)
  expect(platform.runtimeConfig).toBe('old ordinary config')
})

test('TUN receives the admitted configuration with current Profile, mode and Override', async () => {
  const { app, tun, buildTunConfig } = await setupTun()
  const start = vi.spyOn(tun, 'start')
  expect(await app.run('setTun', { enabled: true })).toEqual({ ok: true })
  expect(buildTunConfig).toHaveBeenCalledWith({ profile: app.store.getState().profiles[0], settings: app.store.getState().settings, override: '' })
  expect(start).toHaveBeenCalledWith(session)
})

function replacement(json: string): string {
  const backup = JSON.parse(json) as Backup
  backup.settings.settings.mixedPort = 9000
  backup.settings.profiles = [{ ...backup.settings.profiles[0]!, id: 'p2' }]
  backup.settings.activeProfileId = 'p2'
  backup.profiles = { p2: 'replacement original' }
  backup.override = 'rules: [new]'
  return JSON.stringify(backup)
}

test.each(['on', 'unknown'] as const)('startup recovers %s TUN without a Profile and never starts it', async (state) => {
  const { app, platform, tun } = await setupTun({ availability: 'ready', state }, (platform) => {
    const data = JSON.parse(platform.files.get('settings.json')!)
    data.profiles = []
    data.activeProfileId = null
    platform.files.set('settings.json', JSON.stringify(data))
    platform.coreRunning = false
  })
  expect(tun.events).toEqual(['inspect', 'recover', 'inspect'])
  expect(app.store.getState().tun).toEqual(readyOff)
  expect(platform.coreRunning).toBe(false)
  expect(JSON.parse(platform.files.get('settings.json')!)).not.toHaveProperty('tun')
})

test('startup inspect failure attempts recovery and confirms off without activating TUN', async () => {
  const { app, tun } = await setupTun(readyOff, ({ tun }) => {
    vi.spyOn(tun, 'inspect').mockRejectedValueOnce(new Error('inspection unavailable'))
  })
  expect(tun.events).toEqual(['recover', 'inspect'])
  expect(app.store.getState().tun).toEqual(readyOff)
})

test('unknown startup recovery blocks Core/proxy/Backup until explicit recovery, never restarting TUN', async () => {
  const { app, platform, tun, transport } = await setupTun({ availability: 'ready', state: 'unknown' }, ({ tun }) => {
    vi.spyOn(tun, 'recover').mockImplementationOnce(async () => ({ availability: 'blocked', state: 'unknown', error: 'residue remains' }))
  })
  const original = new Map(platform.files)
  const incoming = replacement(await app.exportBackup())
  const start = vi.spyOn(platform, 'startCore')
  const set = vi.spyOn(platform, 'setSystemProxy')
  const apply = vi.spyOn(platform, 'applyRuntimeConfig')
  const requests = transport.requests.length
  expect(app.store.getState().tun).toMatchObject({ state: 'unknown', availability: 'blocked' })
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(false)
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
  expect((await app.run('setOverride', { yaml: 'rules: [new]' })).ok).toBe(false)
  expect((await app.run('selectProxy', { group: 'group', proxy: 'DIRECT' })).ok).toBe(false)
  await expect(app.importBackup(incoming)).rejects.toThrow('residue remains')
  expect(platform.files).toEqual(original)
  expect(transport.requests).toHaveLength(requests)
  for (const operation of [start, set, apply]) expect(operation).not.toHaveBeenCalled()

  tun.status = { ...readyOff }
  expect((await app.run('recoverTun', {})).ok).toBe(true)
  expect(app.store.getState().tun).toEqual(readyOff)
  expect(tun.events).not.toContain('start')
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(true)
})

test.each(['blocked', 'not-installed', 'unsupported'] as const)('%s/off leaves ordinary Core usable and refuses TUN before stopping it', async (availability) => {
  const { app, platform, tun } = await setupTun({ availability, state: 'off', error: 'TUN unavailable' }, (platform) => { platform.coreRunning = false })
  const stop = vi.spyOn(platform, 'stopCore')
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
  expect(stop).not.toHaveBeenCalled()
  expect(tun.events).not.toContain('start')
  expect((await app.run('startCore', {})).ok).toBe(true)
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(true)
})

test('TUN start waits for ordinary Core/proxy cleanup and serializes duplicate enables', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setSystemProxy', { enabled: true })
  const events = tun.events
  events.length = 0
  const clear = platform.clearSystemProxy.bind(platform)
  vi.spyOn(platform, 'clearSystemProxy').mockImplementation(async () => { events.push('proxy-clear'); await clear() })
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  const stop = platform.stopCore.bind(platform)
  vi.spyOn(platform, 'stopCore').mockImplementation(async () => { events.push('ordinary-stop'); enter(); await blocked; await stop() })
  const start = vi.spyOn(tun, 'start')
  const first = app.run('setTun', { enabled: true })
  await waiting
  const second = app.run('setTun', { enabled: true })
  expect(start).not.toHaveBeenCalled()
  expect(platform.systemProxy).not.toBeNull()
  release()
  expect((await first).ok).toBe(true)
  expect((await second).ok).toBe(true)
  expect(start).toHaveBeenCalledOnce()
  expect(start).toHaveBeenCalledWith(session)
  expect(events.indexOf('ordinary-stop')).toBeLessThan(events.indexOf('proxy-clear'))
  expect(events.indexOf('proxy-clear')).toBeLessThan(events.indexOf('start'))
  expect(events.at(-1)).toBe('inspect')
  expect(app.store.getState().tun).toEqual({ availability: 'ready', state: 'on' })
  expect(app.store.getState().systemProxy).toEqual({ enabled: false })
  expect(platform.systemProxy).toBeNull()
  expect(platform.coreRunning).toBe(false)
  expect(JSON.parse(platform.files.get('settings.json')!)).not.toHaveProperty('tun')
})

test('ordinary stop failure prevents TUN start and leaves the previous proxy visible', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setSystemProxy', { enabled: true })
  vi.spyOn(platform, 'stopCore').mockRejectedValue(new Error('ordinary cleanup unknown'))
  const start = vi.spyOn(tun, 'start')
  expect(await app.run('setTun', { enabled: true })).toEqual({ ok: false, error: 'ordinary cleanup unknown' })
  expect(start).not.toHaveBeenCalled()
  expect(app.store.getState().systemProxy).toEqual({ enabled: true })
  expect(app.store.getState().tun.state).toBe('off')
})

test('System Proxy waits for TUN stop/readback before ordinary start and proxy set', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  const events = tun.events
  events.length = 0
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  const stop = tun.stop.bind(tun)
  vi.spyOn(tun, 'stop').mockImplementation(async () => { enter(); await blocked; return stop() })
  const startCore = platform.startCore.bind(platform)
  const start = vi.spyOn(platform, 'startCore').mockImplementation(async () => { events.push('ordinary-start'); await startCore() })
  const setProxy = platform.setSystemProxy.bind(platform)
  const set = vi.spyOn(platform, 'setSystemProxy').mockImplementation(async (target) => { events.push('proxy-set'); await setProxy(target) })
  const pending = app.run('setSystemProxy', { enabled: true })
  await waiting
  expect(start).not.toHaveBeenCalled()
  expect(set).not.toHaveBeenCalled()
  release()
  expect((await pending).ok).toBe(true)
  expect(events.indexOf('stop')).toBeLessThan(events.indexOf('ordinary-start'))
  expect(events.indexOf('ordinary-start')).toBeLessThan(events.indexOf('proxy-set'))
  expect(app.store.getState().tun.state).toBe('off')
  expect(app.store.getState().systemProxy).toEqual({ enabled: true })
})

test.each(['startCore', 'setSystemProxy'] as const)('%s validates ordinary configuration before stopping working TUN', async command => {
  const { app, platform, tun } = await setupTun()
  expect((await app.run('setTun', { enabled: true })).ok).toBe(true)
  vi.spyOn(platform, 'applyRuntimeConfig').mockResolvedValue({ ok: false, error: 'invalid updated Profile' })
  const stop = vi.spyOn(tun, 'stop')
  const start = vi.spyOn(platform, 'startCore')
  const proxy = vi.spyOn(platform, 'setSystemProxy')
  const result = command === 'startCore' ? await app.run(command, {}) : await app.run(command, { enabled: true })
  expect(result).toEqual({ ok: false, error: 'invalid updated Profile' })
  expect(stop).not.toHaveBeenCalled()
  expect(start).not.toHaveBeenCalled()
  expect(proxy).not.toHaveBeenCalled()
  expect(app.store.getState().tun.state).toBe('on')
})

test('failed TUN stop blocks ordinary/proxy starts until recovery proves off', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  vi.spyOn(tun, 'stop').mockRejectedValue(new Error('TUN cleanup unknown'))
  const start = vi.spyOn(platform, 'startCore')
  const set = vi.spyOn(platform, 'setSystemProxy')
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(false)
  expect(app.store.getState().tun).toMatchObject({ availability: 'blocked', state: 'on', error: 'TUN cleanup unknown' })
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(false)
  expect(start).not.toHaveBeenCalled()
  expect(set).not.toHaveBeenCalled()
  expect((await app.run('recoverTun', {})).ok).toBe(true)
  expect(app.store.getState().tun.state).toBe('off')
  expect((await app.run('startCore', {})).ok).toBe(true)
})

test('claimed TUN start success without on readback is an error, with no false running state', async () => {
  const { app, tun } = await setupTun()
  vi.spyOn(tun, 'start').mockResolvedValue({ availability: 'ready', state: 'on' })
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
  expect(app.store.getState().tun).toMatchObject({ state: 'off', error: expect.stringMatching(/not confirmed on/) })
  expect(app.store.getState().core.status).toBe('stopped')
})

test('partial TUN start failure requires recovery and does not auto-start after recovery', async () => {
  const { app, tun } = await setupTun()
  vi.spyOn(tun, 'start').mockImplementationOnce(async () => {
    tun.status = { availability: 'ready', state: 'unknown' }
    throw new Error('partial start')
  })
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
  expect(app.store.getState().tun).toMatchObject({ state: 'unknown', availability: 'blocked' })
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect((await app.run('recoverTun', {})).ok).toBe(true)
  expect(app.store.getState().tun.state).toBe('off')
  expect(vi.mocked(tun.start)).toHaveBeenCalledOnce()
})

test.each(['start', 'stop', 'recover'] as const)('native notification rejects late TUN %s without reopening network or clearing the native lock', async (operation) => {
  const { app, platform, tun } = await setupTun()
  if (operation === 'stop') await app.run('setTun', { enabled: true })
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  vi.spyOn(tun, operation).mockImplementation(async () => {
    enter()
    await blocked
    tun.status = { availability: 'ready', state: operation === 'start' ? 'on' : 'off' }
    return { ...tun.status }
  })
  const start = vi.spyOn(platform, 'startCore')
  const set = vi.spyOn(platform, 'setSystemProxy')
  const pending = operation === 'recover' ? app.run('recoverTun', {}) : app.run('setTun', { enabled: operation === 'start' })
  await waiting
  app.notifyCoreStopped('Owner lost during TUN operation')
  const snapshot = app.store.getState()
  release()
  expect(await pending).toEqual({ ok: false, error: snapshot.core.error })
  expect(app.store.getState()).toBe(snapshot)
  expect(snapshot.tun.state).toBe('unknown')
  expect((await app.run('recoverTun', {})).ok).toBe(false)
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect(start).not.toHaveBeenCalled()
  expect(set).not.toHaveBeenCalled()
})

test('host quit bypasses a pending TUN start, closes the gate and rejects late success', async () => {
  const { app, tun, onQuit } = await setupTun()
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  vi.spyOn(tun, 'start').mockImplementation(async () => { enter(); await blocked; return { availability: 'ready', state: 'on' } })
  const pending = app.run('setTun', { enabled: true })
  await waiting
  expect((await app.run('quit', {})).ok).toBe(true)
  expect(onQuit).toHaveBeenCalledOnce()
  release()
  expect(await pending).toEqual({ ok: false, error: 'Application is closing' })
  expect(app.store.getState().tun.state).toBe('unknown')
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
})

test.each(['ordinary-stop', 'tun-start'] as const)('host dispose closes the gate while %s is pending and rejects late TUN activation', async (stage) => {
  const { app, platform, tun } = await setupTun()
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  const tunStart = vi.spyOn(tun, 'start')
  if (stage === 'ordinary-stop') {
    const stop = platform.stopCore.bind(platform)
    vi.spyOn(platform, 'stopCore').mockImplementation(async () => { enter(); await blocked; await stop() })
  } else {
    tunStart.mockImplementation(async () => { enter(); await blocked; tun.status = { availability: 'ready', state: 'on' }; return { ...tun.status } })
  }
  const ordinaryStart = vi.spyOn(platform, 'startCore')
  const proxy = vi.spyOn(platform, 'setSystemProxy')
  const pending = app.run('setTun', { enabled: true })
  await waiting
  app.dispose()
  const disposed = app.store.getState()
  release()
  expect(await pending).toEqual({ ok: false, error: 'Application is closing' })
  expect(app.store.getState()).toBe(disposed)
  expect(disposed.tun.state).not.toBe('on')
  expect(tunStart).toHaveBeenCalledTimes(stage === 'ordinary-stop' ? 0 : 1)
  expect((await app.run('setTun', { enabled: true })).ok).toBe(false)
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect(ordinaryStart).not.toHaveBeenCalled()
  expect(proxy).not.toHaveBeenCalled()
})

test('reloading active TUN conservatively stops it and requests manual re-enable without ordinary restart', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  const start = vi.spyOn(platform, 'startCore')
  const tunStart = vi.spyOn(tun, 'start')
  expect((await app.run('setOverride', { yaml: 'rules: [new]' })).ok).toBe(true)
  expect(app.store.getState().tun).toMatchObject({ state: 'off', error: expect.stringMatching(/Enable it manually/) })
  expect(app.store.getState().core.status).toBe('stopped')
  expect(platform.files.get('override.yaml')).toBe('rules: [new]')
  expect(start).not.toHaveBeenCalled()
  expect(tunStart).not.toHaveBeenCalled()
})

test.each(['reject', 'unknown'] as const)('Backup refuses to replace data when TUN stop is %s', async (failure) => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  const incoming = replacement(await app.exportBackup())
  const before = new Map(platform.files)
  vi.spyOn(tun, 'stop').mockImplementation(async () => {
    if (failure === 'reject') throw new Error('cannot stop TUN')
    tun.status = { availability: 'blocked', state: 'unknown', error: 'cleanup unknown' }
    return { ...tun.status }
  })
  const start = vi.spyOn(platform, 'startCore')
  await expect(app.importBackup(incoming)).rejects.toThrow()
  for (const [name, data] of before) expect(platform.files.get(name)).toBe(data)
  expect([...platform.files.keys()].filter((name) => !before.has(name))).toEqual([expect.stringMatching(/^backups\/pre-import-/)])
  expect(start).not.toHaveBeenCalled()
  expect(app.store.getState().tun.state).not.toBe('off')
})

test('Backup stops TUN and ordinary Core before replacing data, never restoring a TUN preference', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  const incoming = replacement(await app.exportBackup())
  const stop = vi.spyOn(tun, 'stop')
  const ordinaryStop = vi.spyOn(platform, 'stopCore')
  const write = platform.writeFileAtomic.bind(platform)
  vi.spyOn(platform, 'writeFileAtomic').mockImplementation(async (name, data) => {
    if (name === 'profiles/p2.yaml') {
      expect(stop).toHaveBeenCalledOnce()
      expect(ordinaryStop).toHaveBeenCalledOnce()
      expect(app.store.getState().tun.state).toBe('off')
    }
    await write(name, data)
  })
  await app.importBackup(incoming)
  expect(platform.files.get('profiles/p2.yaml')).toBe('replacement original')
  expect(JSON.parse(platform.files.get('settings.json')!)).not.toHaveProperty('tun')
  expect(tun.events.filter((event) => event === 'start')).toHaveLength(1)
})

test.each(['startCore', 'stopCore', 'setTun'] as const)('%s confirms active TUN stopped and only explicit ordinary start restarts Core', async (command) => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  const stop = vi.spyOn(tun, 'stop')
  const start = vi.spyOn(platform, 'startCore')
  const result = command === 'setTun' ? await app.run('setTun', { enabled: false }) : await app.run(command, {})
  expect(result.ok).toBe(true)
  expect(stop).toHaveBeenCalledOnce()
  expect(start).toHaveBeenCalledTimes(command === 'startCore' ? 1 : 0)
  expect(app.store.getState().tun.state).toBe('off')
})


test('native start refusal with confirmed off does not block ordinary fallback', async () => {
  const { app, tun } = await setupTun()
  vi.spyOn(tun, 'start').mockImplementation(async () => {
    tun.status = { availability: 'blocked', state: 'off', error: 'validated session unavailable' }
    return { ...tun.status }
  })
  expect(await app.run('setTun', { enabled: true })).toEqual({ ok: false, error: 'validated session unavailable' })
  expect(app.store.getState().tun).toMatchObject({ availability: 'blocked', state: 'off' })
  expect((await app.run('startCore', {})).ok).toBe(true)
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(true)
})

test('claimed TUN stop success without off readback prevents ordinary start', async () => {
  const { app, platform, tun } = await setupTun()
  await app.run('setTun', { enabled: true })
  vi.spyOn(tun, 'stop').mockResolvedValue({ ...readyOff })
  const start = vi.spyOn(platform, 'startCore')
  expect((await app.run('startCore', {})).ok).toBe(false)
  expect(app.store.getState().tun).toMatchObject({ state: 'on', availability: 'blocked' })
  expect(start).not.toHaveBeenCalled()
})

test('TUN transitions pause ordinary streams and retain subscriptions for explicit ordinary restart', async () => {
  const { app, transport } = await setupTun()
  app.subscribeTraffic(() => {})
  app.subscribeLogs(() => {})
  expect(transport.openStreams('/traffic')).toBe(1)
  expect(transport.openStreams('/logs')).toBe(1)
  expect((await app.run('setTun', { enabled: true })).ok).toBe(true)
  expect(transport.openStreams('/traffic')).toBe(0)
  expect(transport.openStreams('/logs')).toBe(0)
  expect((await app.run('setTun', { enabled: false })).ok).toBe(true)
  expect(transport.openStreams('/traffic')).toBe(0)
  expect((await app.run('startCore', {})).ok).toBe(true)
  expect(transport.openStreams('/traffic')).toBe(1)
  expect(transport.openStreams('/logs')).toBe(1)
  app.dispose()
})

test.each(['starting', 'confirmed'] as const)('notification during TUN %s publication cannot be followed by a late success', async (stage) => {
  const { app, tun } = await setupTun()
  const start = vi.spyOn(tun, 'start')
  let notified = false
  app.subscribe((snapshot) => {
    if (notified) return
    if (stage === 'starting' ? snapshot.tun.state === 'unknown' : snapshot.tun.state === 'on') {
      notified = true
      app.notifyCoreStopped('Owner lost during TUN publication')
    }
  })
  const result = await app.run('setTun', { enabled: true })
  expect(result).toEqual({ ok: false, error: app.store.getState().core.error })
  expect(app.store.getState().tun.state).toBe('unknown')
  expect(start).toHaveBeenCalledTimes(stage === 'starting' ? 0 : 1)
})

test('host quit remains available after Backup commit closes the ordinary Command queue', async () => {
  const { app, onQuit } = await setupTun()
  await app.importBackup(await app.exportBackup())
  expect((await app.run('quit', {})).ok).toBe(true)
  expect(onQuit).toHaveBeenCalledOnce()
})

test('resume waits behind a queued TUN enable and leaves the resulting TUN session active', async () => {
  const { app, platform, tun, transport } = await setupTun()
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  const start = tun.start.bind(tun)
  vi.spyOn(tun, 'start').mockImplementation(async () => { enter(); await blocked; return start() })
  const pending = app.run('setTun', { enabled: true })
  await waiting
  const resume = app.resumeCore()
  const ordinaryStart = vi.spyOn(platform, 'startCore')
  const stop = vi.spyOn(tun, 'stop')
  const requests = transport.requests.length
  release()
  expect((await pending).ok).toBe(true)
  await resume
  expect(app.store.getState().tun.state).toBe('on')
  expect(ordinaryStart).not.toHaveBeenCalled()
  expect(stop).not.toHaveBeenCalled()
  expect(transport.requests).toHaveLength(requests)
})

test('resume queued behind an uncertain TUN start refuses ordinary network writes', async () => {
  const { app, platform, tun, transport } = await setupTun()
  vi.spyOn(tun, 'start').mockImplementation(async () => {
    tun.status = { availability: 'blocked', state: 'unknown', error: 'partial activation' }
    throw new Error('partial activation')
  })
  const pending = app.run('setTun', { enabled: true })
  const resume = app.resumeCore()
  const ordinaryStart = vi.spyOn(platform, 'startCore')
  const proxy = vi.spyOn(platform, 'setSystemProxy')
  expect((await pending).ok).toBe(false)
  const requests = transport.requests.length
  await expect(resume).rejects.toThrow('partial activation')
  expect(ordinaryStart).not.toHaveBeenCalled()
  expect(proxy).not.toHaveBeenCalled()
  expect(transport.requests).toHaveLength(requests)
})

test.each(['quit', 'native-stop'] as const)('resume rejects a stale ordinary probe after %s without restarting or writing proxy', async (event) => {
  const { app, platform, transport } = await setupTun()
  await app.run('setSystemProxy', { enabled: true })
  let enter!: () => void
  let release!: () => void
  const waiting = new Promise<void>((resolve) => { enter = resolve })
  const blocked = new Promise<void>((resolve) => { release = resolve })
  vi.spyOn(platform, 'isCoreRunning').mockImplementation(async () => { enter(); await blocked; return false })
  const ordinaryStart = vi.spyOn(platform, 'startCore')
  const proxy = vi.spyOn(platform, 'setSystemProxy')
  const resume = app.resumeCore()
  await waiting
  if (event === 'quit') await app.run('quit', {})
  else app.notifyCoreStopped('Owner stopped during resume')
  const snapshot = app.store.getState()
  const requests = transport.requests.length
  release()
  await expect(resume).rejects.toThrow(event === 'quit' ? 'Application is closing' : 'Owner stopped during resume')
  expect(app.store.getState()).toBe(snapshot)
  expect(ordinaryStart).not.toHaveBeenCalled()
  expect(proxy).not.toHaveBeenCalled()
  expect(transport.requests).toHaveLength(requests)
})

test.each([true, false])('resume ordinary running=%s restores enabled proxy after stale connections or restart', async (running) => {
  const { app, platform, transport } = await setupTun()
  await app.run('setSystemProxy', { enabled: true })
  platform.coreRunning = running
  const events: string[] = []
  const start = platform.startCore.bind(platform)
  const proxy = platform.setSystemProxy.bind(platform)
  vi.spyOn(platform, 'startCore').mockImplementation(async () => { events.push('start'); await start() })
  vi.spyOn(platform, 'setSystemProxy').mockImplementation(async (settings) => { events.push('proxy'); await proxy(settings) })
  transport.on('DELETE', '/connections', () => { events.push('close'); return { status: 204, body: null } })
  await app.resumeCore()
  expect(events).toEqual([running ? 'close' : 'start', 'proxy'])
  expect(app.store.getState().systemProxy.enabled).toBe(true)
})

test('resume surfaces connection cleanup failure after restoring ordinary System Proxy', async () => {
  const { app, platform, transport } = await setupTun()
  await app.run('setSystemProxy', { enabled: true })
  transport.on('DELETE', '/connections', { status: 500, body: { message: 'close failed' } })
  const proxy = vi.spyOn(platform, 'setSystemProxy')
  await expect(app.resumeCore()).rejects.toThrow('close failed')
  expect(proxy).toHaveBeenCalledOnce()
  expect(app.store.getState().systemProxy.enabled).toBe(true)
})


test('native subscription reconciles behind Commands, never recovers automatically, and disposes its listener', async () => {
  let notify: (() => void) | undefined
  const unsubscribe = vi.fn(() => { notify = undefined })
  const { app, tun, platform } = await setupTun(readyOff, ({ tun }) => {
    Object.assign(tun, { subscribe: (listener: () => void) => { notify = listener; return unsubscribe } })
  })
  const inspect = vi.spyOn(tun, 'inspect')
  let release!: () => void
  const held = new Promise<void>(done => { release = done })
  const persisted = platform.writeFileAtomic.bind(platform)
  platform.writeFileAtomic = async (name, value) => { await held; await persisted(name, value) }
  const pending = app.run('setLanguage', { language: 'en' })
  await Promise.resolve()
  inspect.mockClear()
  tun.status = { availability: 'blocked', state: 'unknown', error: 'native owner connection lost' }
  const recover = vi.spyOn(tun, 'recover'), start = vi.spyOn(tun, 'start')
  notify!()
  await Promise.resolve()
  expect(inspect).not.toHaveBeenCalled()
  release()
  await pending
  await vi.waitFor(() => expect(app.store.getState().tun).toMatchObject({ state: 'unknown', error: 'native owner connection lost' }))
  expect(recover).not.toHaveBeenCalled()
  expect(start).not.toHaveBeenCalled()
  const late = notify!
  app.dispose()
  expect(unsubscribe).toHaveBeenCalledOnce()
  inspect.mockClear()
  late()
  await Promise.resolve()
  expect(inspect).not.toHaveBeenCalled()
})
