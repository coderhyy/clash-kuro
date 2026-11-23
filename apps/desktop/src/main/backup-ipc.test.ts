import { chmod, mkdtemp, readFile, rm, stat, truncate, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, beforeEach, expect, test, vi } from 'vitest'
import { MAX_BACKUP_BYTES } from '@kuro/state'
import { IPC } from './ipc-channels'

const mocks = vi.hoisted(() => {
  const handlers = new Map<string, (...args: any[]) => Promise<unknown>>()
  const win = {
    isDestroyed: () => false, once: vi.fn(), on: vi.fn(), loadFile: vi.fn(),
    webContents: { setWindowOpenHandler: vi.fn(), on: vi.fn() }
  }
  const snapshot = { resolvedLanguage: 'zh-CN', settings: { mixedPort: 7890 }, core: { status: 'stopped' }, profiles: [], activeProfileId: null }
  const store = {
    store: { getState: () => snapshot, subscribe: vi.fn() },
    exportBackup: vi.fn(), importBackup: vi.fn(), dispose: vi.fn()
  }
  const app = {
    requestSingleInstanceLock: () => true, whenReady: async () => {},
    getAppPath: () => '/unused', getPath: vi.fn(() => '/unused'), getVersion: () => '0.1.0',
    getLoginItemSettings: () => ({ wasOpenedAtLogin: false }),
    on: vi.fn(), relaunch: vi.fn(), exit: vi.fn()
  }
  const platform = { readFile: async () => null, cleanupStaleSystemProxy: vi.fn(), onResume: vi.fn(), shutdown: vi.fn() }
  const dialog = { showMessageBox: vi.fn(), showSaveDialog: vi.fn(), showOpenDialog: vi.fn() }
  return { handlers, win, store, app, platform, dialog }
})

vi.mock('electron', () => ({
  app: mocks.app, dialog: mocks.dialog,
  BrowserWindow: vi.fn(function () { return mocks.win }),
  ipcMain: { handle: (name: string, handler: (...args: any[]) => Promise<unknown>) => mocks.handlers.set(name, handler), on: vi.fn() },
  Menu: { buildFromTemplate: vi.fn() }, nativeTheme: { shouldUseDarkColors: false },
  powerMonitor: { on: vi.fn() }, shell: {},
  Tray: vi.fn(function () { return { setContextMenu: vi.fn(), setToolTip: vi.fn() } })
}))
vi.mock('@kuro/state', async (original) => ({
  ...await original<typeof import('@kuro/state')>(), createAppStore: async () => mocks.store, buildTrayMenu: () => []
}))
vi.mock('./platform', () => ({
  createDesktopPlatform: () => mocks.platform, createSocketTransport: vi.fn(), createResumeHandler: vi.fn()
}))
vi.mock('./app/geo', () => ({ installGeoData: vi.fn() }))
vi.mock('./app/resident-startup', () => ({ prepareResidentStartup: vi.fn(async () => vi.fn()) }))
vi.mock('./app/profiles', () => ({ createProfileSource: vi.fn() }))
vi.mock('./app/scheduler', () => ({ createUpdateScheduler: () => ({ start: vi.fn(), stop: vi.fn() }) }))
vi.mock('./app/release-check', () => ({ checkForUpdate: async () => null }))
vi.mock('./tray-icon', () => ({ trayIcon: vi.fn() }))

let directory: string
let path: string
const trusted = { sender: mocks.win.webContents }
const invoke = (channel: string, event = trusted) => mocks.handlers.get(channel)!(event)

beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), 'kuro-backup-ipc-'))
  mocks.app.getPath.mockReturnValue(directory)
  const os = vi.spyOn(process, 'platform', 'get').mockReturnValue('win32')
  try {
    await import('./index')
    await vi.waitFor(() => expect(mocks.app.on).toHaveBeenCalledWith('before-quit', expect.any(Function)))
  } finally {
    os.mockRestore()
  }
})
beforeEach(async () => {
  vi.clearAllMocks()
  path = join(directory, 'backup.json')
  await writeFile(path, 'saved backup')
  mocks.dialog.showMessageBox.mockResolvedValue({ response: 1 })
  mocks.dialog.showSaveDialog.mockResolvedValue({ canceled: false, filePath: path })
  mocks.dialog.showOpenDialog.mockResolvedValue({ canceled: false, filePaths: [path] })
  mocks.store.exportBackup.mockResolvedValue('exported secrets')
  mocks.store.importBackup.mockResolvedValue(undefined)
})
afterAll(async () => { await rm(directory, { recursive: true, force: true }) })

test('Backup IPC rejects untrusted senders before opening dialogs or touching data', async () => {
  for (const channel of [IPC.exportBackup, IPC.importBackup]) {
    expect(await invoke(channel, { sender: {} } as typeof trusted)).toEqual({ ok: false, error: 'untrusted sender' })
  }
  expect(mocks.dialog.showMessageBox).not.toHaveBeenCalled()
  expect(mocks.dialog.showOpenDialog).not.toHaveBeenCalled()
  expect(mocks.store.exportBackup).not.toHaveBeenCalled()
  expect(mocks.store.importBackup).not.toHaveBeenCalled()
})

test('export warns about secrets before offering a JSON save dialog and atomically writes private permissions', async () => {
  await chmod(path, 0o644)
  expect(await invoke(IPC.exportBackup)).toEqual({ ok: true })
  expect(mocks.dialog.showMessageBox).toHaveBeenCalledWith(mocks.win, expect.objectContaining({ message: '备份含订阅地址和密钥，请妥善保管', buttons: ['取消', '继续'] }))
  expect(mocks.dialog.showMessageBox.mock.invocationCallOrder[0]).toBeLessThan(mocks.dialog.showSaveDialog.mock.invocationCallOrder[0]!)
  expect(mocks.dialog.showSaveDialog).toHaveBeenCalledWith(mocks.win, expect.objectContaining({ defaultPath: expect.stringMatching(/^clash-kuro-backup-\d{4}-\d{2}-\d{2}\.json$/) }))
  expect(await readFile(path, 'utf8')).toBe('exported secrets')
  if (process.platform !== 'win32') expect((await stat(path)).mode & 0o777).toBe(0o600)
})

test('Backup dialogs follow the resolved language', async () => {
  const state = mocks.store.store.getState() as { resolvedLanguage: string }
  state.resolvedLanguage = 'en'
  try {
    expect(await invoke(IPC.exportBackup)).toEqual({ ok: true })
    expect(mocks.dialog.showMessageBox).toHaveBeenCalledWith(mocks.win, expect.objectContaining({ message: 'A Backup contains subscription URLs and secrets. Keep it safe.', buttons: ['Cancel', 'Continue'] }))
    expect(mocks.dialog.showSaveDialog).toHaveBeenCalledWith(mocks.win, expect.objectContaining({ filters: [{ name: 'Clash Kuro Backup', extensions: ['json'] }] }))
  } finally { state.resolvedLanguage = 'zh-CN' }
})

test('canceling the export warning never opens a save dialog', async () => {
  mocks.dialog.showMessageBox.mockResolvedValue({ response: 0 })
  expect(await invoke(IPC.exportBackup)).toBeNull()
  expect(mocks.dialog.showSaveDialog).not.toHaveBeenCalled()
  expect(mocks.store.exportBackup).not.toHaveBeenCalled()
})

test('canceling the save dialog never exports', async () => {
  mocks.dialog.showSaveDialog.mockResolvedValue({ canceled: true })
  expect(await invoke(IPC.exportBackup)).toBeNull()
  expect(mocks.store.exportBackup).not.toHaveBeenCalled()
})

test('an export error is returned without truncating an existing Backup', async () => {
  mocks.store.exportBackup.mockRejectedValue(new Error('missing Profile'))
  expect(await invoke(IPC.exportBackup)).toEqual({ ok: false, error: 'missing Profile' })
  expect(await readFile(path, 'utf8')).toBe('saved backup')
})

test('canceling open or confirmation never imports or relaunches', async () => {
  mocks.dialog.showOpenDialog.mockResolvedValueOnce({ canceled: true })
  expect(await invoke(IPC.importBackup)).toBeNull()
  expect(mocks.dialog.showMessageBox).not.toHaveBeenCalled()
  mocks.dialog.showMessageBox.mockResolvedValueOnce({ response: 0 })
  expect(await invoke(IPC.importBackup)).toBeNull()
  expect(mocks.store.importBackup).not.toHaveBeenCalled()
  expect(mocks.app.relaunch).not.toHaveBeenCalled()
})

test('import rejects files over 50 MB before reading them into the store', async () => {
  await truncate(path, MAX_BACKUP_BYTES + 1)
  expect(await invoke(IPC.importBackup)).toEqual({ ok: false, error: expect.stringContaining('50 MB') })
  expect(mocks.store.importBackup).not.toHaveBeenCalled()
  expect(mocks.app.relaunch).not.toHaveBeenCalled()
})

test('import errors return a readable result and do not relaunch', async () => {
  mocks.store.importBackup.mockRejectedValue(new Error('Invalid Backup'))
  expect(await invoke(IPC.importBackup)).toEqual({ ok: false, error: 'Invalid Backup' })
  expect(mocks.app.relaunch).not.toHaveBeenCalled()
})

test('a confirmed import reads only the main-process dialog path, then relaunches and shuts down', async () => {
  expect(await mocks.handlers.get(IPC.importBackup)!(trusted, '/renderer-supplied-path')).toEqual({ ok: true })
  expect(mocks.store.importBackup).toHaveBeenCalledWith('saved backup')
  expect(mocks.dialog.showOpenDialog.mock.invocationCallOrder[0]).toBeLessThan(mocks.dialog.showMessageBox.mock.invocationCallOrder[0]!)
  expect(mocks.store.importBackup.mock.invocationCallOrder[0]).toBeLessThan(mocks.app.relaunch.mock.invocationCallOrder[0]!)
  expect(mocks.app.relaunch.mock.invocationCallOrder[0]).toBeLessThan(mocks.platform.shutdown.mock.invocationCallOrder[0]!)
  expect(mocks.platform.shutdown).toHaveBeenCalledWith({ timeoutMs: 3000 })
  expect(mocks.app.exit).toHaveBeenCalledWith(0)
})
