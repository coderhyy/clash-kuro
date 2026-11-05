import { chmodSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, test, vi } from 'vitest'
import { FakePlatform } from '@kuro/core/fake'
import { FakeTransport } from '@kuro/api/fake'
import { FakeTunPlatform, fakeSnapshot } from '@kuro/state/fake'
import type { AppStore } from '@kuro/state'

const fixture = vi.hoisted(() => ({
  directory: '', platform: undefined as (FakePlatform & { tun: FakeTunPlatform; cleanupStaleSystemProxy: ReturnType<typeof vi.fn> }) | undefined,
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
vi.mock('./app/profiles', () => ({ createProfileSource: () => ({ buildRuntimeConfig: () => 'proxies: []', buildTunConfig: vi.fn() }) }))
vi.mock('./app/scheduler', () => ({ createUpdateScheduler: () => fixture.scheduler }))
vi.mock('./app/release-check', () => ({ checkForUpdate: fixture.release }))
vi.mock('./tray-icon', () => ({ trayIcon: vi.fn() }))

const descriptors = { platform: Object.getOwnPropertyDescriptor(process, 'platform')!, resourcesPath: Object.getOwnPropertyDescriptor(process, 'resourcesPath') }
const argv = process.argv
let directory: string | undefined
afterEach(() => {
  fixture.store?.dispose(); fixture.store = undefined
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
