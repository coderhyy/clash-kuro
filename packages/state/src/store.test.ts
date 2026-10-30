import { expect, test, vi } from 'vitest'
import { FakePlatform } from '@kuro/core/fake'
import { FakeTransport } from '@kuro/api/fake'
import { createMihomoClient } from '@kuro/api'
import { fakeSnapshot } from './fake'
import { createAppStore, type AppStoreDeps } from './index'

async function setup(running = true) {
  const platform = new FakePlatform()
  const snapshot = fakeSnapshot()
  const metadata = { settings: snapshot.settings, profiles: snapshot.profiles, activeProfileId: snapshot.activeProfileId }
  platform.files.set('settings.json', JSON.stringify(metadata))
  platform.runtimeConfig = 'old config'
  platform.coreRunning = running
  let selected = '香港 01'
  const transport = new FakeTransport()
    .on('GET', '/proxies', () => ({ status: 200, body: { proxies: {
      group: { type: 'Selector', all: ['香港 01', '日本 01'], now: selected },
      '香港 01': { type: 'Trojan', history: [{ delay: 82 }] },
      '日本 01': { type: 'Vmess', history: [] }
    } } }))
    .on('PATCH', '/configs', { status: 204, body: null })
    .on('PUT', '/proxies/group', (req) => { selected = (req.body as { name: string }).name; return { status: 204, body: null } })
  const deps: AppStoreDeps = {
    platform,
    client: createMihomoClient(transport),
    buildRuntimeConfig: vi.fn(({ profile, settings }) => `${profile.id}:${settings.mode}:${settings.mixedPort}`),
    refreshProfile: vi.fn(async (profile) => ({ ...profile, updatedAt: 123, lastError: null })),
    hooks: { onOpenWindow: vi.fn(), onQuit: vi.fn() }
  }
  const app = await createAppStore(deps)
  return { app, platform, transport, deps, metadata }
}

test('hydrates the main-process vanilla store; each publication increments version', async () => {
  const { app, metadata } = await setup()
  expect(app.store.getState()).toMatchObject({ ...metadata, core: { status: 'running', error: null }, proxyGroups: [{ now: '香港 01' }] })
  const versions: number[] = []
  const off = app.subscribe((state) => versions.push(state.version))
  const initial = (await app.getSnapshot()).version
  await app.run('setMode', { mode: 'global' })
  await app.run('selectProxy', { group: 'group', proxy: '日本 01' })
  expect(versions).toEqual([initial + 1, initial + 2])
  expect((await app.getSnapshot()).proxyGroups[0]?.now).toBe('日本 01')
  off()
  await app.run('setMode', { mode: 'direct' })
  expect(versions).toHaveLength(2)
})

test('persists mode before PATCH; re-created stores recover it from disk', async () => {
  const { app, platform, transport, deps } = await setup()
  transport.on('PATCH', '/configs', () => {
    expect(JSON.parse(platform.files.get('settings.json')!).settings.mode).toBe('global')
    return { status: 204, body: null }
  })
  expect(await app.run('setMode', { mode: 'global' })).toEqual({ ok: true, value: undefined })
  const reopened = await createAppStore(deps)
  expect((await reopened.getSnapshot()).settings.mode).toBe('global')
})

test('failed persistence never PATCHes Core or publishes unsaved mode', async () => {
  const { app, platform, transport } = await setup()
  platform.writeFileAtomic = async () => { throw new Error('disk full') }
  const version = app.store.getState().version
  expect(await app.run('setMode', { mode: 'global' })).toEqual({ ok: false, error: 'disk full' })
  expect(transport.requests.some((r) => r.method === 'PATCH')).toBe(false)
  expect(app.store.getState().settings.mode).toBe('rule')
  expect(app.store.getState().version).toBe(version)
})

test('a rejected Core PATCH preserves the saved desired mode; later commands still run', async () => {
  const { app, transport, platform } = await setup()
  transport.on('PATCH', '/configs', { status: 500, body: { message: 'Core rejected mode' } })
  expect(await app.run('setMode', { mode: 'global' })).toEqual({ ok: false, error: 'Core rejected mode' })
  expect(app.store.getState().settings.mode).toBe('global')
  expect(JSON.parse(platform.files.get('settings.json')!).settings.mode).toBe('global')
  expect((await app.run('openWindow', {})).ok).toBe(true)
})

test('serializes overlapping commands so writes and Core updates cannot race', async () => {
  const { app, platform, transport } = await setup()
  const modes: string[] = []
  const write = platform.writeFileAtomic.bind(platform)
  platform.writeFileAtomic = async (name, data) => {
    await Promise.resolve()
    modes.push(JSON.parse(data).settings.mode)
    await write(name, data)
  }
  await Promise.all([app.run('setMode', { mode: 'global' }), app.run('setMode', { mode: 'direct' })])
  expect(modes).toEqual(['global', 'direct'])
  expect(transport.requests.filter((r) => r.method === 'PATCH').map((r) => r.body)).toEqual([{ mode: 'global' }, { mode: 'direct' }])
  expect(app.store.getState().settings.mode).toBe('direct')
})

test('mode can change while stopped without calling an unavailable Core', async () => {
  const { app, transport } = await setup(false)
  expect((await app.run('setMode', { mode: 'direct' })).ok).toBe(true)
  expect(transport.requests).toEqual([])
})

test('imports remote and local Profiles, updates, persists interval, and removes metadata without deleting originals', async () => {
  const { app, deps, platform } = await setup(false)
  for (const source of [{ kind: 'remote' as const, url: 'https://example.com/new' }, { kind: 'local' as const, path: '/local.yaml' }]) {
    const result = await app.run('importProfile', { name: 'new', source })
    expect(result.ok).toBe(true)
    if (!result.ok) throw new Error(result.error)
    const profileId = result.value.profileId
    expect(app.store.getState().profiles.find((p) => p.id === profileId)).toMatchObject({ source, updatedAt: 123 })
    expect((await app.run('updateProfile', { profileId })).ok).toBe(true)
    expect((await app.run('updateSettings', { settings: {}, profileUpdateIntervalHours: { profileId, hours: 4 } })).ok).toBe(true)
    expect(app.store.getState().profiles.find((p) => p.id === profileId)?.userUpdateIntervalHours).toBe(4)
    platform.files.set(`${profileId}.yaml`, 'original')
    expect((await app.run('removeProfile', { profileId })).ok).toBe(true)
    expect(platform.files.get(`${profileId}.yaml`)).toBe('original')
  }
  expect(deps.refreshProfile).toHaveBeenCalledTimes(4)
  expect(app.store.getState().profiles).toHaveLength(1)
})

test('refresh failure retains old metadata and marks lastError', async () => {
  const { app, deps } = await setup()
  const previous = app.store.getState().profiles[0]!
  deps.refreshProfile = async () => { throw new Error('offline') }
  expect(await app.run('updateProfile', { profileId: 'p1' })).toEqual({ ok: false, error: 'offline' })
  expect(app.store.getState().profiles[0]).toEqual({ ...previous, lastError: 'offline' })
})

test('active refresh validates/replaces Runtime Config before restarting Core', async () => {
  const { app, platform, deps } = await setup()
  const stop = vi.spyOn(platform, 'stopCore')
  const start = vi.spyOn(platform, 'startCore')
  expect((await app.run('updateProfile', { profileId: 'p1' })).ok).toBe(true)
  expect(deps.buildRuntimeConfig).toHaveBeenCalledWith(expect.objectContaining({ profile: expect.objectContaining({ id: 'p1', updatedAt: 123 }), controlChannel: platform.controlChannel() }))
  expect(platform.runtimeConfig).toBe('p1:rule:7890')
  expect(stop).toHaveBeenCalledOnce()
  expect(start).toHaveBeenCalledOnce()
  expect(app.store.getState().core.status).toBe('running')
})

test('failed runtime validation retains old config, Active Profile, and running Core', async () => {
  const { app, platform } = await setup()
  platform.validate = () => ({ ok: false, error: 'invalid YAML' })
  const stop = vi.spyOn(platform, 'stopCore')
  expect(await app.run('setActiveProfile', { profileId: 'p1' })).toEqual({ ok: false, error: 'invalid YAML' })
  expect(platform.runtimeConfig).toBe('old config')
  expect(platform.coreRunning).toBe(true)
  expect(stop).not.toHaveBeenCalled()
  expect(app.store.getState().activeProfileId).toBe('p1')
  expect((await app.run('updateProfile', { profileId: 'p1' })).ok).toBe(false)
  expect(app.store.getState().profiles[0]?.lastError).toBe('invalid YAML')
})

test('activates a Profile while stopped, then starts Core with generated Runtime Config', async () => {
  const { app, platform } = await setup(false)
  expect((await app.run('setActiveProfile', { profileId: 'p1' })).ok).toBe(true)
  expect(platform.coreRunning).toBe(false)
  expect((await app.run('startCore', {})).ok).toBe(true)
  expect(platform.coreRunning).toBe(true)
  expect(app.store.getState().core.status).toBe('running')
  const start = vi.spyOn(platform, 'startCore')
  expect((await app.run('startCore', {})).ok).toBe(true)
  expect(start).not.toHaveBeenCalled()
})

test('start errors are CommandResults and publish error Core status', async () => {
  const { app, platform } = await setup(false)
  platform.startCore = async () => { throw new Error('port occupied') }
  expect(await app.run('startCore', {})).toEqual({ ok: false, error: 'port occupied' })
  expect(app.store.getState().core).toEqual({ status: 'error', error: 'port occupied' })
})

test('System Proxy uses the mixed-port, toggles off, and reports manual setup on denial', async () => {
  const { app, platform } = await setup()
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(true)
  expect(platform.systemProxy).toMatchObject({ host: '127.0.0.1', port: 7890 })
  expect(app.store.getState().systemProxy).toEqual({ enabled: true })
  expect((await app.run('setSystemProxy', { enabled: false })).ok).toBe(true)
  expect(platform.systemProxy).toBeNull()
  platform.setSystemProxy = async () => { throw new Error('permission denied') }
  expect(await app.run('setSystemProxy', { enabled: true })).toEqual({ ok: false, error: 'permission denied' })
  expect(app.store.getState().systemProxy).toEqual({ enabled: false, manualRequired: { host: '127.0.0.1', port: 7890 } })
})

test('a settings change reloads Core and retargets an enabled System Proxy', async () => {
  const { app, platform } = await setup()
  await app.run('setSystemProxy', { enabled: true })
  expect((await app.run('updateSettings', { settings: { mixedPort: 9000, allowLan: true, logLevel: 'debug' } })).ok).toBe(true)
  expect(platform.runtimeConfig).toBe('p1:rule:9000')
  expect(platform.systemProxy?.port).toBe(9000)
  expect(app.store.getState().settings).toEqual({ mode: 'rule', mixedPort: 9000, allowLan: true, logLevel: 'debug' })
})

test('restart failure cannot leave System Proxy pointing at a stopped Core', async () => {
  const { app, platform } = await setup()
  await app.run('setSystemProxy', { enabled: true })
  platform.startCore = async () => { throw new Error('restart failed') }
  expect(await app.run('updateSettings', { settings: { mixedPort: 9000 } })).toEqual({ ok: false, error: 'restart failed' })
  expect(platform.coreRunning).toBe(false)
  expect(platform.systemProxy).toBeNull()
  expect(app.store.getState()).toMatchObject({ core: { status: 'error' }, systemProxy: { enabled: false } })
})

test('interval-only changes persist without restarting Core, and support removing the override', async () => {
  const { app, platform, deps } = await setup()
  const stop = vi.spyOn(platform, 'stopCore')
  await app.run('updateSettings', { settings: {}, profileUpdateIntervalHours: { profileId: 'p1', hours: 6 } })
  await app.run('updateSettings', { settings: {}, profileUpdateIntervalHours: { profileId: 'p1', hours: null } })
  expect(stop).not.toHaveBeenCalled()
  expect(deps.buildRuntimeConfig).not.toHaveBeenCalled()
  expect(app.store.getState().profiles[0]?.userUpdateIntervalHours).toBeNull()
})

test('stop/quit clear System Proxy before stopping Core; host callbacks receive commands', async () => {
  const { app, platform, deps } = await setup()
  const events: string[] = []
  platform.clearSystemProxy = async () => { events.push('clear') }
  platform.stopCore = async () => { events.push('stop'); platform.coreRunning = false }
  deps.hooks!.onQuit = () => { events.push('quit') }
  expect((await app.run('openWindow', {})).ok).toBe(true)
  expect(deps.hooks!.onOpenWindow).toHaveBeenCalledOnce()
  expect((await app.run('stopCore', {})).ok).toBe(true)
  expect((await app.run('quit', {})).ok).toBe(true)
  expect(events).toEqual(['clear', 'stop', 'clear', 'stop', 'quit'])
  expect(app.store.getState()).toMatchObject({ core: { status: 'stopped' }, proxyGroups: [], proxies: {}, systemProxy: { enabled: false } })
})

test('refuses to stop or quit if System Proxy cannot be cleared', async () => {
  const { app, platform, deps } = await setup()
  platform.clearSystemProxy = async () => { throw new Error('cannot clear proxy') }
  const stop = vi.spyOn(platform, 'stopCore')
  expect((await app.run('quit', {})).ok).toBe(false)
  expect(stop).not.toHaveBeenCalled()
  expect(deps.hooks!.onQuit).not.toHaveBeenCalled()
})

test('removing the Active Profile safely stops Core and clears the selection', async () => {
  const { app, platform } = await setup()
  expect((await app.run('removeProfile', { profileId: 'p1' })).ok).toBe(true)
  expect(app.store.getState()).toMatchObject({ profiles: [], activeProfileId: null, core: { status: 'stopped' } })
  expect(platform.coreRunning).toBe(false)
  expect(await app.run('startCore', {})).toEqual({ ok: false, error: 'No Active Profile' })
})

test('validates command payloads and never throws errors across the bridge', async () => {
  const { app } = await setup()
  const run = app.run as (name: string, input: unknown) => Promise<{ ok: boolean; error?: string }>
  for (const [name, input] of [
    ['toString', {}], ['unknown', {}], ['setMode', null], ['setMode', { mode: 'bad' }],
    ['setSystemProxy', { enabled: 'yes' }], ['selectProxy', { group: '', proxy: 'x' }],
    ['importProfile', { name: '', source: { kind: 'local', path: 'x' } }],
    ['importProfile', { name: 'bad URL', source: { kind: 'remote', url: 'file:///x' } }],
    ['updateProfile', { profileId: 'missing' }], ['removeProfile', { profileId: 'missing' }],
    ['setActiveProfile', { profileId: 'missing' }], ['updateSettings', { settings: { mixedPort: 0 } }],
    ['updateSettings', { settings: { mode: 'direct' } }],
    ['updateSettings', { settings: {}, profileUpdateIntervalHours: { profileId: 'p1', hours: -1 } }]
  ] as const) expect(await run(name, input)).toMatchObject({ ok: false })
})

test('empty storage gets defaults, corrupt storage is not silently overwritten', async () => {
  const { deps } = await setup(false)
  const platform = new FakePlatform()
  const app = await createAppStore({ ...deps, platform })
  expect(app.store.getState()).toMatchObject({ profiles: [], activeProfileId: null, core: { status: 'stopped' } })
  platform.files.set('settings.json', 'broken json')
  await expect(createAppStore({ ...deps, platform })).rejects.toThrow()
  expect(platform.files.get('settings.json')).toBe('broken json')
})

test('invalid persisted metadata is rejected without modifying disk', async () => {
  const { deps, platform, metadata } = await setup(false)
  for (const patch of [
    { updatedAt: -1 }, { lastError: 42 }, { subscriptionInfo: { upload: -1, download: 0, total: 0 } },
    { userUpdateIntervalHours: 0 }, { serverUpdateIntervalHours: -1 }
  ]) {
    const data = JSON.stringify({ ...metadata, profiles: [{ ...metadata.profiles[0], ...patch }] })
    platform.files.set('settings.json', data)
    await expect(createAppStore(deps)).rejects.toThrow('Invalid')
    expect(platform.files.get('settings.json')).toBe(data)
  }
})

test('traffic and logs are events: Core streams open only while subscribed and Core runs', async () => {
  const { app, transport } = await setup(false)
  const traffic: unknown[] = []
  const offTraffic = app.subscribeTraffic((t) => traffic.push(t))
  expect(transport.openStreams('/traffic')).toBe(0)
  const before = app.store.getState().version
  await app.run('startCore', {})
  expect(transport.openStreams('/traffic')).toBe(1)
  expect(transport.openStreams('/logs')).toBe(0)
  transport.push('/traffic', { up: 1, down: 2 })
  expect(traffic).toEqual([{ up: 1, down: 2 }])
  expect(app.store.getState().version - before).toBeLessThan(5)
  offTraffic()
  expect(transport.openStreams('/traffic')).toBe(0)
  const offLogs = app.subscribeLogs(() => {})
  expect(transport.openStreams('/logs')).toBe(1)
  app.dispose()
  expect(transport.openStreams('/logs')).toBe(0)
  offLogs()
})
