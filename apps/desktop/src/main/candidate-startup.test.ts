import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { once } from 'node:events'
import { mkdirSync, chmodSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, test, vi } from 'vitest'
import { FakePlatform } from '@kuro/core/fake'
import { FakeTransport } from '@kuro/api/fake'
import { FakeTunPlatform, fakeSnapshot } from '@kuro/state/fake'
import type { AppStore } from '@kuro/state'
import type { Platform, TunPlatform, TunStatus } from '@kuro/core'


const fixture = vi.hoisted(() => ({
  directory: '', realProfiles: false, platform: undefined as (Platform & { tun: TunPlatform; cleanupStaleSystemProxy(port: number): Promise<void> }) | undefined,
  store: undefined as AppStore | undefined,
  app: { isPackaged: true, requestSingleInstanceLock: () => true, whenReady: async () => {},
    getAppPath: () => fixture.directory, getPath: vi.fn(), setPath: vi.fn(),
    getVersion: () => '0.1.0', getLocale: () => 'en', getLoginItemSettings: () => ({ wasOpenedAtLogin: false }),
    on: vi.fn(), exit: vi.fn(), dock: { show: vi.fn(), hide: vi.fn() } },
  window: vi.fn(), scheduler: { start: vi.fn(), stop: vi.fn() }, release: vi.fn(async () => null),
}))
vi.mock('electron', () => ({
  app: fixture.app, ipcMain: { handle: vi.fn(), on: vi.fn() }, dialog: {},
  BrowserWindow: vi.fn(function () { fixture.window(); return { once: vi.fn(), on: vi.fn(), loadFile: vi.fn(),
    isDestroyed: () => false, webContents: { setWindowOpenHandler: vi.fn(), on: vi.fn(), send: vi.fn() } } }),
  Menu: { buildFromTemplate: vi.fn() }, nativeTheme: { shouldUseDarkColors: false }, powerMonitor: { on: vi.fn() }, shell: {},
  Tray: vi.fn(function () { return { setContextMenu: vi.fn(), setToolTip: vi.fn(), setImage: vi.fn() } }),
}))
vi.mock('@kuro/state', async original => ({
  ...await original<typeof import('@kuro/state')>(), buildTrayMenu: () => [],
  createAppStore: async (...args: Parameters<typeof import('@kuro/state').createAppStore>) => {
    const real = await original<typeof import('@kuro/state')>()
    fixture.store = await real.createAppStore(...args)
    return fixture.store
  },
}))
vi.mock('./platform', () => ({ createDesktopPlatform: () => fixture.platform, createSocketTransport: () => new FakeTransport()
  .on('GET', '/proxies', { status: 200, body: { proxies: {} } }) }))
vi.mock('./platform/macos-tun', () => ({ createMacosTun: () => fixture.platform!.tun }))
vi.mock('./app/geo', () => ({ installGeoData: vi.fn() }))
vi.mock('./app/resident-startup', () => ({ prepareResidentStartup: vi.fn() }))
vi.mock('./app/profiles', async original => {
  const real = await original<typeof import('./app/profiles')>()
  return { createProfileSource: (...args: Parameters<typeof real.createProfileSource>) => fixture.realProfiles
    ? real.createProfileSource(...args) : { buildRuntimeConfig: () => 'proxies: []', buildTunConfig: vi.fn() } }
})
vi.mock('./app/scheduler', () => ({ createUpdateScheduler: () => fixture.scheduler }))
vi.mock('./app/release-check', () => ({ checkForUpdate: fixture.release }))
vi.mock('./tray-icon', () => ({ trayIcon: vi.fn() }))

const descriptors = { platform: Object.getOwnPropertyDescriptor(process, 'platform')!, resourcesPath: Object.getOwnPropertyDescriptor(process, 'resourcesPath') }
const argv = process.argv
let directory: string | undefined
afterEach(() => {
  fixture.store?.dispose(); fixture.store = undefined; fixture.realProfiles = false
  Object.defineProperty(process, 'platform', descriptors.platform)
  if (descriptors.resourcesPath) Object.defineProperty(process, 'resourcesPath', descriptors.resourcesPath)
  else Reflect.deleteProperty(process, 'resourcesPath')
  process.argv = argv
  vi.unstubAllEnvs()
  if (directory) rmSync(directory, { recursive: true, force: true })
})

test.runIf(typeof process.getuid === 'function').each([
  [true, false], [true, true], [false, false],
])('actual main finite=%s with recovery blocked=%s preserves TUN admission and gates only automatic product actions', async (finite, blocked) => {
  vi.resetModules(); vi.clearAllMocks(); vi.stubEnv('KURO_SMOKE', '')
  directory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-candidate-start-'))); chmodSync(directory, 0o700)
  fixture.directory = directory
  fixture.app.getPath.mockReturnValue(directory)
  writeFileSync(join(directory, 'package.json'), JSON.stringify(finite
    ? { kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false, kuroSourceCommit: 'a'.repeat(40) } : {}))
  Object.defineProperty(process, 'platform', { value: 'darwin' })
  Object.defineProperty(process, 'resourcesPath', { configurable: true, value: directory })
  process.argv = ['kuro']
  const platform = Object.assign(new FakePlatform(), {
    tun: new FakeTunPlatform({ availability: 'blocked', state: 'unknown', error: 'owned residue' }), cleanupStaleSystemProxy: vi.fn(),
  })
  fixture.platform = platform
  const snapshot = fakeSnapshot()
  platform.files.set('settings.json', JSON.stringify({ settings: snapshot.settings, profiles: snapshot.profiles, activeProfileId: 'p1' }))
  if (blocked) vi.spyOn(platform.tun, 'recover').mockImplementation(async () => platform.tun.status)
  else platform.tun.status.availability = 'ready'
  const inspect = vi.spyOn(platform.tun, 'inspect'), recover = vi.spyOn(platform.tun, 'recover')
  const start = vi.spyOn(platform, 'startCore'), fetch = vi.spyOn(platform, 'fetchText')
  const proxyWrite = vi.spyOn(platform, 'setSystemProxy'), tunStart = vi.spyOn(platform.tun, 'start')
  await import('./index')
  await vi.waitFor(() => expect(fixture.window).toHaveBeenCalledOnce())
  // Drain the actual main startup continuation after window creation.
  await new Promise(resolve => setTimeout(resolve, 0))
  expect(fixture.app.exit).not.toHaveBeenCalled()
  expect(inspect).toHaveBeenCalled(); expect(recover).toHaveBeenCalledOnce()
  expect(fixture.store!.store.getState().tun.state).toBe(blocked ? 'unknown' : 'off')
  expect(tunStart).not.toHaveBeenCalled()
  if (finite) {
    expect(platform.cleanupStaleSystemProxy).not.toHaveBeenCalled()
    expect(start).not.toHaveBeenCalled(); expect(fetch).not.toHaveBeenCalled()
    expect(fixture.scheduler.start).not.toHaveBeenCalled(); expect(fixture.release).not.toHaveBeenCalled()
  } else {
    expect(platform.cleanupStaleSystemProxy).toHaveBeenCalledOnce(); expect(start).toHaveBeenCalledOnce()
    expect(fixture.scheduler.start).toHaveBeenCalledOnce(); expect(fixture.release).toHaveBeenCalledOnce()
  }
  const resume = vi.spyOn(fixture.store!, 'resumeCore')
  platform.resume()
  expect(resume).toHaveBeenCalledTimes(finite ? 0 : 1)
  expect(proxyWrite).not.toHaveBeenCalled()
  if (blocked) {
    expect(await fixture.store!.run('startCore', {})).toMatchObject({ ok: false })
    expect(await fixture.store!.run('setSystemProxy', { enabled: true })).toMatchObject({ ok: false })
    expect(start).not.toHaveBeenCalled(); expect(proxyWrite).not.toHaveBeenCalled()
  }
})

test.runIf(typeof process.getuid === 'function')('actual finite main recovers fresh blocked/off with the real adapter/store before showing ready', async () => {
  vi.resetModules(); vi.clearAllMocks(); vi.stubEnv('KURO_SMOKE', '')
  directory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-candidate-start-'))); chmodSync(directory, 0o700)
  fixture.directory = directory; fixture.app.getPath.mockReturnValue(directory)
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false, kuroSourceCommit: 'a'.repeat(40) }))
  Object.defineProperty(process, 'platform', { value: 'darwin' })
  Object.defineProperty(process, 'resourcesPath', { configurable: true, value: directory })
  process.argv = ['kuro']
  const real = await vi.importActual<typeof import('./platform/macos-tun')>('./platform/macos-tun')
  let status: TunStatus = { availability: 'blocked', state: 'off', error: 'authenticated recovery is required before a new TUN session' }
  const request = vi.fn(async (operation: string) => {
    if (operation === 'recover') status = { availability: 'ready', state: 'off' }
    return status
  })
  const open = vi.fn(), tun = real.createMacosTun({ endpointPresent: async () => true, request, open })
  const platform = Object.assign(new FakePlatform(), { tun, cleanupStaleSystemProxy: vi.fn() })
  fixture.platform = platform
  const start = vi.spyOn(platform, 'startCore'), proxy = vi.spyOn(platform, 'setSystemProxy')
  await import('./index')
  await vi.waitFor(() => expect(fixture.window).toHaveBeenCalledOnce())
  expect(fixture.store!.store.getState().tun).toEqual({ availability: 'ready', state: 'off' })
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'recover', 'status', 'status'])
  expect(open).not.toHaveBeenCalled(); expect(start).not.toHaveBeenCalled(); expect(proxy).not.toHaveBeenCalled()
  expect(platform.cleanupStaleSystemProxy).not.toHaveBeenCalled(); expect(fixture.scheduler.start).not.toHaveBeenCalled(); expect(fixture.release).not.toHaveBeenCalled()
})


// build-macos-helper.mjs supplies its freshly compiled ordinary-UID test binary.
// The signed native relay tests the actual peer policy; it is not Electron/root acceptance.
test.runIf(process.platform === 'darwin' && Boolean(process.env.KURO_ADMISSION_FIXTURE)).each([
  'fresh', 'residue', 'recovery-failed', 'auth-only', 'identity', 'invalid-config', 'finalizing', 'start-failed',
] as const)('authenticated native admission %s: installed identity -> startup recovery -> finite V2 dispatch', async mode => {
  vi.resetModules(); vi.clearAllMocks(); vi.stubEnv('KURO_SMOKE', '')
  directory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-candidate-start-'))); chmodSync(directory, 0o700)
  fixture.directory = directory; fixture.realProfiles = true; fixture.app.getPath.mockReturnValue(directory)
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false, kuroSourceCommit: 'a'.repeat(40) }))
  Object.defineProperty(process, 'platform', { value: 'darwin' })
  Object.defineProperty(process, 'resourcesPath', { configurable: true, value: directory }); process.argv = ['kuro']
  const child = spawn(process.env.KURO_ADMISSION_FIXTURE!, ['--admission-chain', mode], { stdio: ['pipe', 'pipe', 'pipe'] })
  const exited = once(child, 'exit')
  let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes.toString() })
  const lines = createInterface({ input: child.stdout }), output = lines[Symbol.asyncIterator]()
  const next = async (): Promise<Record<string, any>> => {
    const line = await output.next(); if (line.done) throw new Error(`native admission fixture exited: ${stderr}`)
    return JSON.parse(line.value)
  }
  const command = async (value: string) => { child.stdin.write(`${value}\n`); return next() }
  const real = await vi.importActual<typeof import('./platform/macos-tun')>('./platform/macos-tun')
  let tun: ReturnType<typeof real.createMacosTun> | undefined
  let activated = false
  let rejection: string | undefined, recoveryRejection: string | undefined
  try {
    const endpoints = await next()
    expect(endpoints.initial).toMatchObject({ availability: 'blocked', state: ['residue', 'recovery-failed'].includes(mode) ? 'unknown' : 'off' })
    const request = vi.fn(async (operation: 'status' | 'stop' | 'recover') => {
      try { return await real.requestTunHelper(operation, endpoints.front) } catch (error) {
        if (operation === 'recover') recoveryRejection = error instanceof Error ? error.message : String(error)
        throw error
      }
    })
    const open = vi.fn((config: Parameters<typeof real.openTunHelperSession>[0]) => real.openTunHelperSession(config, endpoints.front))
    tun = real.createMacosTun({ endpointPresent: async () => true, request, open })
    const desktop = await vi.importActual<typeof import('./platform')>('./platform')
    const exec = vi.fn<import('./platform').Exec>(async (_file, args) => ({ stdout: args[0] === '-listallnetworkservices' ? 'Wi-Fi' : 'Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0', stderr: '' }))
    const platform = desktop.createDesktopPlatform({ os: 'darwin', dataDir: directory, corePath: join(directory, 'must-not-run'), mixedPort: 7890, tun, exec,
      spawn: () => { throw new Error('ordinary Core must never be spawned by the finite candidate') } })
    fixture.platform = Object.assign(platform, { tun: platform.tun! })
    const snapshot = fakeSnapshot()
    writeFileSync(join(directory, 'settings.json'), JSON.stringify({ settings: snapshot.settings, profiles: snapshot.profiles, activeProfileId: snapshot.activeProfileId }))
    mkdirSync(join(directory, 'profiles'), { mode: 0o700 })
    const profile = `proxies: []
rules: ["MATCH,DIRECT"]
dns:
  enable: true
  ipv6: true
  enhanced-mode: redir-host
  nameserver: [192.0.2.53]
  default-nameserver: [192.0.2.53]
  proxy-server-nameserver: [192.0.2.53]
`
    writeFileSync(join(directory, 'profiles/p1.yaml'), profile)
    const ordinary = vi.spyOn(platform, 'startCore'), stopped = vi.spyOn(platform, 'stopCore'), proxy = vi.spyOn(platform, 'setSystemProxy'), stale = vi.spyOn(platform, 'cleanupStaleSystemProxy')
    await import('./index'); await vi.waitFor(() => expect(fixture.window).toHaveBeenCalledOnce())
    const state = fixture.store!.store.getState().tun
    expect(request.mock.calls.flat().filter(value => value === 'recover')).toHaveLength(1)
    if (mode === 'recovery-failed' || mode === 'auth-only') {
      expect(state).toMatchObject({ availability: 'blocked', state: mode === 'recovery-failed' ? 'unknown' : 'off' })
      expect(state.error).toMatch(mode === 'auth-only' ? /installed manifest does not explicitly permit/ : /DNS: remove failed/)
      const denied = await fixture.store!.run('setTun', { enabled: true }); expect(denied.ok).toBe(false)
      if (!denied.ok) rejection = denied.error
      expect(fixture.store!.store.getState().tun.error).toMatch(mode === 'auth-only' ? /installed manifest does not explicitly permit/ : /DNS: remove failed/)
      expect(rejection).toMatch(mode === 'auth-only' ? /installed manifest does not explicitly permit/ : /DNS: remove failed/)
      expect(open).not.toHaveBeenCalled()
      expect(recoveryRejection).toMatch(mode === 'auth-only' ? /installed manifest does not explicitly permit/ : /DNS: remove failed/)
    } else {
      expect(state).toEqual({ availability: 'ready', state: 'off' })
      if (mode === 'identity' || mode === 'invalid-config') {
        const admitted = (await import('@kuro/core')).createTunSessionConfig(profile, 'rule', '')
        const { createConnection } = await import('node:net')
        const response = await new Promise<string>((resolve, reject) => {
          const socket = createConnection(mode === 'identity' ? endpoints.backend : endpoints.front); let bytes = ''
          socket.once('connect', () => socket.end(`${JSON.stringify({ version: 2, operation: 'open', config: mode === 'invalid-config' ? { ...admitted, command: '/bin/sh' } : admitted })}\n`))
          socket.on('data', chunk => { bytes += chunk.toString() }); socket.once('end', () => resolve(bytes)); socket.once('error', reject)
        })
        const rejected = JSON.parse(response); expect(rejected.ok).toBe(false); rejection = rejected.error
        expect(rejected.error).toMatch(mode === 'identity' ? /client|peer|identity|harden|signature/i : /unsupported|unknown|closed|field/i)
      } else if (mode === 'start-failed') {
        const started = await fixture.store!.run('setTun', { enabled: true })
        expect(started.ok).toBe(false)
        if (!started.ok) rejection = started.error
        expect(rejection).toMatch(/route/i)
        expect((await fixture.store!.run('recoverTun', {})).ok).toBe(true)
        expect(fixture.store!.store.getState().tun).toEqual({ availability: 'ready', state: 'off' })
      } else {
        const started = await fixture.store!.run('setTun', { enabled: true }); activated = started.ok; expect(started).toEqual({ ok: true })
        expect(fixture.store!.store.getState().tun).toEqual({ availability: 'ready', state: 'on' })
        expect(open).toHaveBeenCalledOnce()
        expect(open.mock.calls[0]![0]).toMatchObject({ template: 'macos-dual-stack-v1', rules: [{ type: 'MATCH', target: 'DIRECT' }] })
        // Includes real V2 sequence/stop and independent V1 readback. The finalizing
        // fixture holds the owner worker after ACK, deterministically keeping busy true.
        expect((await fixture.store!.run('recoverTun', {})).ok).toBe(true)
        expect(fixture.store!.store.getState().tun).toEqual({ availability: 'ready', state: 'off' })
        if (mode === 'finalizing') {
          const stats = await command('stats'); expect(stats.finalizing).toBe(true); expect(stats.recoverRefusals).toBe(0)
          await command('release')
        }
      }
    }
    const stats = await command('stats')
    expect(stats.starts).toBe(['fresh', 'residue', 'finalizing', 'start-failed'].includes(mode) ? 1 : 0)
    expect(stats.applications).toBe(mode === 'start-failed' ? 0 : stats.starts)
    expect(stats.opens).toBe(['recovery-failed', 'auth-only'].includes(mode) ? 0 : 1)
    expect(stats.authorizations).toBeGreaterThanOrEqual(mode === 'auth-only' ? 0 : 1)
    expect(stats.dnsJournalAbsent).toBe(mode !== 'recovery-failed')
    expect(stats.ownerAbsent).toBe(true); expect(stats.workAbsent).toBe(true)
    expect(stats.routeWrites).toBe(0)
    if (stats.starts === 1) {
      expect(stats.networkPrepares).toBe(1)
      expect(stats.observedRouteCount).toBe(mode === 'start-failed' ? 0 : 5)
    }
    if (mode === 'start-failed') { expect(stats.probes).toBe(0); expect(stats.dnsAdds).toBe(0) }
    if (mode === 'residue') expect(stats.dnsRemovals).toBe(2)
    process.stdout.write(`native-admission-evidence ${JSON.stringify({ mode, ...stats, rejection, recoveryRejection })}\n`)
    expect(ordinary).not.toHaveBeenCalled(); expect(proxy).not.toHaveBeenCalled(); expect(stale).not.toHaveBeenCalled()
    if (stats.starts === 1) {
      expect(stopped).toHaveBeenCalled(); expect(exec.mock.calls.some(([, args]) => args[0] === '-getwebproxy')).toBe(true)
      expect(exec.mock.calls.some(([, args]) => args[0] === '-getsecurewebproxy')).toBe(true)
    }
    expect(exec.mock.calls.every(([, args]) => args[0]?.startsWith('-get') || args[0] === '-listallnetworkservices')).toBe(true)
  } finally {
    try { if (tun && activated) await tun.stop() } finally {
      child.stdin.end('quit\n'); const [code, signal] = await exited; lines.close()
      expect({ code, signal, stderr: stderr.replace(/^.*replacing existing signature\n/gm, '') }).toEqual({ code: 0, signal: null, stderr: '' })
    }
  }
}, 15000)
