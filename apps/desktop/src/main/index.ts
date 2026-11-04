import { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, powerMonitor, shell, Tray, type IpcMainEvent, type IpcMainInvokeEvent } from 'electron'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { appendFile, mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { createMihomoClient } from '@kuro/api'
import { buildTrayMenu, createAppStore, MAX_BACKUP_BYTES, type AppStore, type CommandName } from '@kuro/state'
import { createDesktopPlatform, createSocketTransport } from './platform'
import { createMacosTun } from './platform/macos-tun'
import { createProfileSource } from './app/profiles'
import { createUpdateScheduler } from './app/scheduler'
import { checkForUpdate } from './app/release-check'
import { installGeoData } from './app/geo'
import { prepareResidentStartup } from './app/resident-startup'
import { IPC, type BackupResult, type StreamKind } from './ipc-channels'
import { trayIcon } from './tray-icon'
import { t } from '../shared/i18n'
import { assertObservationCandidateLaunch, inspectPackagedArguments, prepareVerificationDirectory, runAuthenticationVerification, runRuntimeVerification, safeWebPreferences } from './runtime-verification'

// KURO_RELEASE_REPO=owner/name overrides the release source (e.g. for forks).
const RELEASE_REPO = process.env.KURO_RELEASE_REPO ?? 'coderhyy/clash-kuro'
const SHUTDOWN_TIMEOUT_MS = 3_000

let verificationDirectory: string | undefined
let authenticationOnly = false
let startupRefused = false
if (app.isPackaged) {
  try {
    const launch = inspectPackagedArguments(process.argv.slice(1))
    // Chromium may parse switches before JS. Dynamic CDP negatives must also pass.
    if (launch.error) throw new Error(launch.error)
    const sealedMetadata: unknown = JSON.parse(readFileSync(join(app.getAppPath(), 'package.json'), 'utf8'))
    assertObservationCandidateLaunch(sealedMetadata, launch.directory)
    verificationDirectory = launch.directory
    authenticationOnly = launch.authenticate === true
    if (verificationDirectory) {
      const paths = prepareVerificationDirectory(verificationDirectory)
      for (const [name, path] of Object.entries(paths)) app.setPath(name as 'userData' | 'sessionData' | 'crashDumps', path)
      app.disableHardwareAcceleration()
    }
  } catch (error) {
    startupRefused = true
    console.error(error instanceof Error ? error.message : String(error))
    app.exit(64)
  }
}

if (startupRefused) {
  // No production platform, profiles or Core are created on a refused launch.
} else if (verificationDirectory) {
  const directory = verificationDirectory
  void app.whenReady().then(async () => {
    if (authenticationOnly) {
      await runAuthenticationVerification({ app, directory })
      return
    }
    const window = new BrowserWindow({ show: false, width: 960, height: 640,
      webPreferences: safeWebPreferences(join(__dirname, '../preload/index.js')) })
    await runRuntimeVerification({ app, window, ipc: ipcMain, directory, renderer: join(__dirname, '../renderer/index.html') })
  }).catch(error => { console.error(error); app.exit(1) })
} else if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  void main()
}

async function main(): Promise<void> {
  await app.whenReady()
  if (process.env.KURO_SMOKE) {
    console.log('KURO_SMOKE_OK')
    app.quit()
    return
  }

  const resources = app.isPackaged ? join(process.resourcesPath, 'core') : join(app.getAppPath(), 'resources', 'core', `${process.platform}-${process.arch}`)
  const geoDir = app.isPackaged ? join(process.resourcesPath, 'core', 'geo') : join(app.getAppPath(), 'resources', 'core', 'geo')
  const corePath = join(resources, process.platform === 'win32' ? 'mihomo.exe' : 'mihomo')
  const sysproxyHelperPath = process.platform === 'win32'
    ? app.isPackaged ? join(process.resourcesPath, 'bin', 'kuro-sysproxy.exe') : join(app.getAppPath(), 'resources', 'win', 'x64', 'kuro-sysproxy.exe')
    : undefined
  const dataDir = join(app.getPath('userData'), 'data')
  let startResident: Awaited<ReturnType<typeof prepareResidentStartup>> | undefined
  try {
    await mkdir(dataDir, { recursive: true })
    if (sysproxyHelperPath) startResident = await prepareResidentStartup({ dataDir, helperPath: sysproxyHelperPath })
  } catch (error) {
    dialog.showErrorBox('System Proxy owner unavailable', error instanceof Error ? error.message : String(error))
    app.exit(1)
    return
  }
  const userAgent = `ClashKuro/${app.getVersion()} (clash.meta)`

  let store: AppStore | undefined
  const platform = createDesktopPlatform({
    tun: process.platform === 'darwin' ? createMacosTun() : undefined,
    dataDir, corePath, sysproxyHelperPath, userAgent, powerMonitor, loginItemApp: app, startResident,
    onResidentStopped: reason => store?.notifyCoreStopped(reason),
    mixedPort: () => store?.store.getState().settings.mixedPort ?? 7890
  })
  const client = createMihomoClient(createSocketTransport(() => platform.controlChannel()))
  const profiles = createProfileSource({ platform, userAgent, isCoreRunning: () => platform.isCoreRunning() })

  await installGeoData(geoDir, dataDir)

  let win: BrowserWindow | null = null
  let tray: Tray | null = null
  let quitting = false

  // One line per exit step, so logoff/shutdown cleanup can be checked after the next login.
  function logExit(line: string): void {
    // Diagnostics never delay native cleanup; the native bounded report is authoritative.
    void appendFile(join(dataDir, 'exit.log'), `${new Date().toISOString()} ${line}\n`).catch(() => {})
  }

  async function exit(trigger = 'quit'): Promise<void> {
    if (quitting) return
    quitting = true
    const started = Date.now()
    let exitCode = 0
    logExit(`exit start (${trigger})`)
    try {
      scheduler.stop()
      app_.dispose()
      await platform.shutdown({ timeoutMs: SHUTDOWN_TIMEOUT_MS })
      logExit('cleanup completed')
    } catch (error) {
      exitCode = 1
      logExit(`cleanup FAILED; state may be unknown: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      logExit(`exit done in ${Date.now() - started} ms`)
      app.exit(exitCode)
    }
  }

  function showWindow(): void {
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
      return
    }
    void app.dock?.show()
    win = new BrowserWindow({
      width: 960, height: 640, minWidth: 720, minHeight: 520, title: 'Clash Kuro', show: false,
      backgroundColor: nativeTheme.shouldUseDarkColors ? '#1f2430' : '#f8f9fa',
      webPreferences: safeWebPreferences(join(__dirname, '../preload/index.js'))
    })
    win.once('ready-to-show', () => win?.show())
    // The user may toggle the login item in System Settings while we run.
    win.on('focus', () => void app_.refreshLaunchAtLogin().catch((error) => console.warn('Launch at Login read failed:', error)))
    // ADR-0004: closing destroys the window (default behaviour); main keeps state, tray stays.
    win.on('closed', () => {
      win = null
      if (!quitting) app.dock?.hide()
    })
    win.webContents.setWindowOpenHandler(({ url }) => {
      if (url.startsWith('https://')) void shell.openExternal(url)
      return { action: 'deny' }
    })
    win.webContents.on('will-navigate', (event) => event.preventDefault())
    if (!app.isPackaged && process.env.ELECTRON_RENDERER_URL) void win.loadURL(process.env.ELECTRON_RENDERER_URL)
    else void win.loadFile(join(__dirname, '../renderer/index.html'))
  }

  const app_ = await createAppStore({
    platform, client,
    systemLocale: () => app.getLocale(),
    buildRuntimeConfig: (input) => profiles.buildRuntimeConfig(input),
    buildTunConfig: (input) => profiles.buildTunConfig(input),
    refreshProfile: (profile) => profiles.refreshProfile(profile),
    hooks: { onOpenWindow: showWindow, onQuit: () => void exit() }
  })
  store = app_

  // Store startup reconciles TUN first, including with no active Profile. Unknown ownership forbids new proxy writes.
  if (!startResident && app_.store.getState().tun.state === 'off') try {
    await platform.cleanupStaleSystemProxy(app_.store.getState().settings.mixedPort)
  } catch (error) { console.warn('Stale System Proxy cleanup failed:', error) }

  const scheduler = createUpdateScheduler({
    profiles: () => app_.store.getState().profiles,
    update: (profileId) => app_.run('updateProfile', { profileId })
  })

  // Only our own window may talk to the main process.
  const trusted = (event: IpcMainEvent | IpcMainInvokeEvent) => !!win && !win.isDestroyed() && event.sender === win.webContents
  ipcMain.handle(IPC.getSnapshot, (event) => {
    if (!trusted(event)) throw new Error('untrusted sender')
    return app_.store.getState()
  })
  ipcMain.handle(IPC.run, (event, name: CommandName, input: unknown) => {
    if (!trusted(event)) return { ok: false, error: 'untrusted sender' }
    // The store validates the name and payload shape; anything else comes back as a CommandResult error.
    return app_.run(name, input as never)
  })
  ipcMain.handle(IPC.pickProfileFile, async (event) => {
    if (!trusted(event) || !win) return null
    const language = app_.store.getState().resolvedLanguage
    const result = await dialog.showOpenDialog(win, { title: t('import', {}, language), buttonLabel: t('openFile', {}, language), properties: ['openFile'], filters: [{ name: 'YAML', extensions: ['yaml', 'yml'] }] })
    return result.canceled ? null : result.filePaths[0] ?? null
  })
  ipcMain.handle(IPC.openLoginItemsSettings, async (event) => {
    if (!trusted(event) || process.platform !== 'darwin') return
    await shell.openExternal('x-apple.systempreferences:com.apple.LoginItems-Settings.extension')
  })
  ipcMain.handle(IPC.exportBackup, async (event): Promise<BackupResult> => {
    if (!trusted(event) || !win) return { ok: false, error: 'untrusted sender' }
    const language = app_.store.getState().resolvedLanguage
    try {
      const warning = await dialog.showMessageBox(win, {
        type: 'warning', message: t('backupExportWarning', {}, language),
        buttons: [t('cancel', {}, language), t('continue', {}, language)], defaultId: 0, cancelId: 0
      })
      if (warning.response !== 1) return null
      const result = await dialog.showSaveDialog(win, {
        defaultPath: `clash-kuro-backup-${new Date().toISOString().slice(0, 10)}.json`,
        filters: [{ name: t('backupFileType', {}, language), extensions: ['json'] }]
      })
      if (result.canceled || !result.filePath) return null
      const content = await app_.exportBackup()
      const temporary = `${result.filePath}.${randomUUID()}.tmp`
      try {
        await writeFile(temporary, content, { flag: 'wx', mode: 0o600 })
        await rename(temporary, result.filePath)
      } finally { await rm(temporary, { force: true }) }
      return { ok: true }
    } catch (error) { return { ok: false, error: error instanceof Error ? error.message : String(error) } }
  })
  ipcMain.handle(IPC.importBackup, async (event): Promise<BackupResult> => {
    if (!trusted(event) || !win) return { ok: false, error: 'untrusted sender' }
    const language = app_.store.getState().resolvedLanguage
    try {
      const result = await dialog.showOpenDialog(win, {
        properties: ['openFile'], filters: [{ name: t('backupFileType', {}, language), extensions: ['json'] }]
      })
      if (result.canceled) return null
      const path = result.filePaths[0]
      if (!path) return null
      const confirmation = await dialog.showMessageBox(win, {
        type: 'warning', message: t('backupImportConfirm', {}, language),
        detail: t('backupImportDetail', {}, language),
        buttons: [t('cancel', {}, language), t('backupImportSubmit', {}, language)], defaultId: 0, cancelId: 0
      })
      if (confirmation.response !== 1) return null
      if ((await stat(path)).size > MAX_BACKUP_BYTES) throw new Error(t('backupTooLarge', {}, language))
      await app_.importBackup(await readFile(path, 'utf8'))
      app.relaunch()
      await exit()
      return { ok: true }
    } catch (error) { return { ok: false, error: error instanceof Error ? error.message : String(error) } }
  })
  const streams = new Map<string, () => void>()
  ipcMain.on(IPC.streamSubscribe, (event, kind: StreamKind, id: string) => {
    if (!trusted(event) || typeof id !== 'string' || streams.has(id) || (kind !== 'traffic' && kind !== 'logs')) return
    const sender = event.sender
    const send = (value: unknown) => { if (!sender.isDestroyed()) sender.send(kind === 'traffic' ? IPC.traffic : IPC.logs, id, value) }
    const off = kind === 'traffic' ? app_.subscribeTraffic(send) : app_.subscribeLogs(send)
    streams.set(id, off)
    // A destroyed window can't unsubscribe; drop its streams so Tray Mode holds no WebSocket.
    sender.once('destroyed', () => { streams.get(id)?.(); streams.delete(id) })
  })
  ipcMain.on(IPC.streamUnsubscribe, (_event, id: string) => {
    streams.get(id)?.()
    streams.delete(id)
  })

  const trayOpen = trayIcon(true), trayClosed = trayIcon(false)
  let trayRunning = false
  function renderTray(): void {
    if (!tray) return
    const snapshot = app_.store.getState()
    tray.setContextMenu(Menu.buildFromTemplate(buildTrayMenu(snapshot).flatMap((item, i, all) => [
      ...(i > 0 && all[i - 1]!.type !== item.type ? [{ type: 'separator' as const }] : []),
      {
        label: t(item.label, {}, snapshot.resolvedLanguage),
        type: item.type,
        checked: item.checked ?? false,
        enabled: item.enabled ?? true,
        click: () => void app_.run(item.command.name, item.command.input as never).then((result) => {
          if (!result.ok && item.command.name === 'quit') void exit()
          else if (!result.ok) dialog.showErrorBox(t('app', {}, app_.store.getState().resolvedLanguage), result.error)
        })
      }
    ])))
    tray.setToolTip(`Clash Kuro · ${t(snapshot.core.status, {}, snapshot.resolvedLanguage)}`)
    const running = snapshot.core.status === 'running'
    if (running !== trayRunning) tray.setImage(running ? trayOpen : trayClosed)
    trayRunning = running
  }

  app_.store.subscribe((snapshot) => {
    if (win && !win.isDestroyed()) win.webContents.send(IPC.snapshot, snapshot)
    renderTray()
  })

  tray = new Tray(trayClosed)
  renderTray()

  platform.onResume(() => {
    // Check ownership inside the same queue as mode changes, not before entering it.
    app_.resumeCore().catch((error) => console.warn('Resume recovery failed:', error))
  })

  app.on('second-instance', (_event, argv) => {
    if (process.platform !== 'win32' || !argv.includes('--hidden')) showWindow()
  })
  app.on('activate', showWindow)
  app.on('window-all-closed', () => { /* Tray Mode: keep running. */ })
  app.on('before-quit', (event) => {
    // exit() always ends in app.exit(), which skips before-quit; a quit that arrives mid-cleanup must wait for it.
    event.preventDefault()
    void exit()
  })
  // macOS/Linux only; Windows never emits powerMonitor 'shutdown'.
  powerMonitor.on('shutdown', () => void exit())
  // Windows session cleanup belongs exclusively to the native owner, including Tray Mode.
  // Launch at Login starts straight in Tray Mode (CONTEXT.md: 开机自启).
  if (process.platform === 'darwin' && app.getLoginItemSettings().wasOpenedAtLogin) app.dock?.hide()
  else if (process.platform !== 'win32' || !process.argv.includes('--hidden')) showWindow()
  if (app_.store.getState().activeProfileId) {
    const result = await app_.run('startCore', {})
    if (!result.ok) console.warn('Core did not start:', result.error)
  }
  scheduler.start()
  void checkForUpdate({ repo: RELEASE_REPO, currentVersion: app.getVersion() }).then((update) => {
    if (update) app_.store.setState((s) => ({ ...s, update, version: s.version + 1 }))
  })
}
