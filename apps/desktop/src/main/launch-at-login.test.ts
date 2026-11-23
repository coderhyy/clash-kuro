import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'

const mocks = vi.hoisted(() => {
  const win = {
    isDestroyed: () => false, isMinimized: () => false,
    show: vi.fn(), focus: vi.fn(), once: vi.fn(), on: vi.fn(), loadFile: vi.fn(),
    webContents: { setWindowOpenHandler: vi.fn(), on: vi.fn() }
  }
  const app = {
    isPackaged: false, requestSingleInstanceLock: () => true, whenReady: async () => {},
    getAppPath: () => '/unused', getPath: vi.fn(), getVersion: () => '0.1.0',
    getLoginItemSettings: vi.fn(), on: vi.fn(),
    dock: { hide: vi.fn(), show: vi.fn() }
  }
  const snapshot = {
    resolvedLanguage: 'en', settings: { mixedPort: 7890 }, core: { status: 'stopped' },
    profiles: [], activeProfileId: 'p1'
  }
  const store = {
    store: { getState: () => snapshot, subscribe: vi.fn() },
    run: vi.fn(), refreshLaunchAtLogin: vi.fn()
  }
  return { win, app, store, scheduler: { start: vi.fn(), stop: vi.fn() }, window: vi.fn() }
})

vi.mock('electron', () => ({
  app: mocks.app,
  BrowserWindow: vi.fn(function () { mocks.window(); return mocks.win }),
  ipcMain: { handle: vi.fn(), on: vi.fn() }, dialog: {},
  Menu: { buildFromTemplate: vi.fn() }, nativeTheme: { shouldUseDarkColors: false },
  powerMonitor: { on: vi.fn() }, shell: {},
  Tray: vi.fn(function () { return { setContextMenu: vi.fn(), setToolTip: vi.fn() } })
}))
vi.mock('@kuro/api', () => ({ createMihomoClient: vi.fn() }))
vi.mock('@kuro/state', () => ({
  MAX_BACKUP_BYTES: 50 * 1024 * 1024, createAppStore: async () => mocks.store, buildTrayMenu: () => []
}))
vi.mock('./platform', () => ({
  createDesktopPlatform: () => ({ readFile: async () => null, cleanupStaleSystemProxy: vi.fn(), onResume: vi.fn() }),
  createSocketTransport: vi.fn(), createResumeHandler: vi.fn()
}))
vi.mock('./app/resident-startup', () => ({ prepareResidentStartup: async () => vi.fn() }))
vi.mock('./app/geo', () => ({ installGeoData: vi.fn() }))
vi.mock('./app/profiles', () => ({ createProfileSource: vi.fn() }))
vi.mock('./app/scheduler', () => ({ createUpdateScheduler: () => mocks.scheduler }))
vi.mock('./app/release-check', () => ({ checkForUpdate: async () => null }))
vi.mock('./tray-icon', () => ({ trayIcon: vi.fn() }))

const platformDescriptor = Object.getOwnPropertyDescriptor(process, 'platform')!
const argv = process.argv
let directory: string
beforeEach(async () => {
  vi.resetModules()
  vi.clearAllMocks()
  vi.stubEnv('KURO_SMOKE', '')
  directory = await mkdtemp(join(tmpdir(), 'kuro-login-start-'))
  mocks.app.getPath.mockReturnValue(directory)
  mocks.app.getLoginItemSettings.mockReturnValue({ wasOpenedAtLogin: false })
  mocks.store.run.mockResolvedValue({ ok: true })
})
afterEach(async () => {
  Object.defineProperty(process, 'platform', platformDescriptor)
  process.argv = argv
  vi.unstubAllEnvs()
  await rm(directory, { recursive: true, force: true })
})

async function start(os: NodeJS.Platform, args: string[] = [], openedAtLogin = false) {
  Object.defineProperty(process, 'platform', { value: os })
  process.argv = ['kuro', ...args]
  mocks.app.getLoginItemSettings.mockReturnValue({ wasOpenedAtLogin: openedAtLogin })
  await import('./index')
  await vi.waitFor(() => expect(mocks.scheduler.start).toHaveBeenCalledOnce())
}

test.each([
  ['win32', ['--hidden'], false, false],
  ['win32', [], false, true],
  ['darwin', [], true, false],
  ['darwin', ['--hidden'], false, true],
] satisfies Array<[NodeJS.Platform, string[], boolean, boolean]>)('%s startup %j (login=%s) opens window=%s', async (os, args, openedAtLogin, opensWindow) => {
  await start(os, args, openedAtLogin)
  expect(mocks.window).toHaveBeenCalledTimes(opensWindow ? 1 : 0)
  expect(mocks.app.dock.hide).toHaveBeenCalledTimes(os === 'darwin' && openedAtLogin ? 1 : 0)
  expect(mocks.store.run.mock.calls).toEqual([['startCore', {}]])
})

test('Windows hidden second-instance preserves Tray Mode and ordinary second-instance opens the window', async () => {
  await start('win32', ['--hidden'])
  const listener = mocks.app.on.mock.calls.find(([event]) => event === 'second-instance')![1]
  listener({}, ['kuro', '--hidden'])
  expect(mocks.window).not.toHaveBeenCalled()
  listener({}, ['kuro'])
  expect(mocks.window).toHaveBeenCalledOnce()
  listener({}, ['kuro', '--hidden'])
  expect(mocks.win.show).not.toHaveBeenCalled()
  expect(mocks.win.focus).not.toHaveBeenCalled()
})
