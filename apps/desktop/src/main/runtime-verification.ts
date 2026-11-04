import { lstatSync, mkdirSync, readdirSync, realpathSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { lstat } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import type { MihomoClient } from '@kuro/api'
import { createAppStore, parseBackup, type CommandName } from '@kuro/state'
import type { Platform } from '@kuro/core'
import type { App, BrowserWindow, IpcMain } from 'electron'
import { IPC } from './ipc-channels'

const FLAG = '--kuro-runtime-verification='
const AUTH_FLAG = '--kuro-auth-verification='
export const AUTH_SOCKET = '/var/run/dev.kuro.tun/auth.sock'
export function inspectPackagedArguments(args: string[]): { directory?: string; authenticate?: true; error?: string } {
  let authenticate: true | undefined
  let directory: string | undefined
  let error: string | undefined
  for (const arg of args) {
    if ((arg.startsWith(FLAG) || arg.startsWith(AUTH_FLAG)) && directory === undefined) {
      authenticate = arg.startsWith(AUTH_FLAG) ? true : undefined
      directory = arg.slice(authenticate ? AUTH_FLAG.length : FLAG.length)
      if (!directory) error = 'Verification directory is required'
    }
    else if (arg !== '--hidden' && !/^-psn_\d+_\d+$/.test(arg)) error = `Unsupported packaged launch argument: ${arg.split('=')[0]}`
  }
  return { directory, ...(authenticate ? { authenticate } : {}), error }
}

/** This value comes only from the package.json sealed inside app.getAppPath(). */
export function assertObservationCandidateLaunch(metadata: unknown, directory?: string): void {
  if (metadata && typeof metadata === 'object' && 'kuroAuthObservationOnly' in metadata
    && metadata.kuroAuthObservationOnly === true && !directory) {
    throw new Error('This authentication observation candidate cannot start normally; use its isolated auth/runtime verification mode')
  }
}

/** Only a fresh private OS-temp child can receive Chromium data/report writes. */
export function prepareVerificationDirectory(directory: string): Record<'userData' | 'sessionData' | 'crashDumps', string> {
  const root = realpathSync(tmpdir())
  const target = resolve(directory)
  if (target !== directory || dirname(target) !== root || !/^kuro-electron-runtime-[A-Za-z0-9_-]+$/.test(basename(target))) throw new Error('Verification requires a fresh private OS-temp directory')
  let current = target
  while (current !== root) {
    const info = lstatSync(current)
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077)) throw new Error('Unprotected verification directory')
    current = dirname(current)
  }
  if (realpathSync(target) !== target || readdirSync(target).length) throw new Error('Verification directory must be canonical and empty')
  const paths = { userData: join(target, 'userData'), sessionData: join(target, 'sessionData'), crashDumps: join(target, 'crashDumps') }
  for (const path of Object.values(paths)) mkdirSync(path, { mode: 0o700 })
  return paths
}

class AuthenticationRejected extends Error {}

/** The read-only auth service returns no lease, token, status or start capability. */
export function parseAuthenticationResponse(text: string): true {
  if (!text.endsWith('\n') || text.trim().includes('\n')) throw new Error('Invalid authentication response framing')
  const value: unknown = JSON.parse(text)
  // The success envelope is flat and scalar. Counting lexical keys rejects duplicate/escaped duplicate keys.
  const count = text.match(/"(?:[^"\\]|\\.)*"\s*:/g)?.length ?? 0
  if (!value || typeof value !== 'object' || Array.isArray(value) || count !== 3 || Object.keys(value).length !== 3) throw new Error('Invalid authentication response')
  const response = value as Record<string, unknown>
  if (response.version !== 1) throw new Error('Invalid authentication version')
  if (response.ok === true && response.authenticated === true) return true
  if (response.ok === false && typeof response.error === 'string' && response.error.length > 0 && response.error.length <= 4096) throw new AuthenticationRejected(response.error)
  throw new Error('Invalid authentication response')
}

/** Fixed operation and root-owned endpoint only; this transport cannot request any TUN operation. */
export async function requestAuthenticationProbe(): Promise<true> {
  const directory = await lstat(dirname(AUTH_SOCKET))
  const endpoint = await lstat(AUTH_SOCKET)
  if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== 0 || (directory.mode & 0o022)
    || !endpoint.isSocket() || endpoint.isSymbolicLink() || endpoint.uid !== 0) throw new Error('Untrusted authentication endpoint')
  return new Promise((resolve, reject) => {
    const socket = createConnection(AUTH_SOCKET)
    let bytes = Buffer.alloc(0), settled = false
    const finish = (error?: Error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      if (error) reject(error)
      else resolve(true)
    }
    const timer = setTimeout(() => finish(new Error('Authentication response timed out')), 2000)
    socket.once('connect', () => socket.end('{"version":1,"operation":"authenticate"}\n'))
    socket.on('data', chunk => {
      if (bytes.length + chunk.length > 8192) { finish(new Error('Authentication response exceeds limit')); return }
      bytes = Buffer.concat([bytes, chunk])
    })
    socket.once('end', () => {
      try { parseAuthenticationResponse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); finish() }
      catch (error) { finish(error as Error) }
    })
    socket.once('error', error => finish(error))
    socket.once('close', () => { if (!settled) finish(new Error('Authentication service disconnected without a complete response')) })
  })
}

/** Separate from UI verification and production main: no Platform, renderer, IPC or Core is constructed. */
export async function runAuthenticationVerification(options: { app: Pick<App, 'getPath' | 'exit'>; directory: string }): Promise<void> {
  let authenticated = false, nativeRejected = false, error: string | undefined
  try { authenticated = await requestAuthenticationProbe() }
  catch (failure) { nativeRejected = failure instanceof AuthenticationRejected; error = failure instanceof Error ? failure.message : String(failure) }
  const { app, directory } = options
  const report = { version: 1, mode: 'authenticate-only', ok: authenticated, authenticated, nativeRejected, error,
    endpoint: AUTH_SOCKET, executable: process.execPath, directory, userData: app.getPath('userData'), sessionData: app.getPath('sessionData'),
    realPlatformCreated: false, realCoreStarted: false, systemNetworkWrites: false }
  writeFileSync(join(directory, 'result.json'), JSON.stringify(report, null, 2), { flag: 'wx', mode: 0o600 })
  app.exit(authenticated ? 0 : 1)
}

/** No real Platform, socket transport, OS reads, child processes or fetch exist here. */
export function verificationCapabilities() {
  const files = new Map<string, string>()
  const denied: string[] = []
  const refuse = (operation: string): never => { denied.push(operation); throw new Error(`Runtime verification forbids ${operation}`) }
  const off = () => ({ availability: 'blocked' as const, state: 'off' as const, error: 'Isolated runtime verification; real TUN disabled' })
  const platform: Platform = {
    readFile: async name => files.get(name) ?? null,
    writeFileAtomic: async (name, value) => { files.set(name, value) },
    removeFile: async name => { files.delete(name) },
    applyRuntimeConfig: async () => ({ ok: false, error: 'Runtime verification forbids Core validation' }),
    startCore: async () => refuse('Core start'),
    // These confirm only the isolated model, which never acquired OS ownership.
    stopCore: async () => {}, isCoreRunning: async () => false,
    controlChannel: () => refuse('Core control channel'),
    getSystemProxy: async () => null, clearSystemProxy: async () => {},
    setSystemProxy: async () => refuse('System Proxy'),
    fetchText: async () => refuse('network fetch'),
    onResume: () => () => {},
    getLaunchAtLogin: async () => 'unsupported',
    setLaunchAtLogin: async () => refuse('Launch at Login'),
    tun: { inspect: async () => off(), recover: async () => off(), stop: async () => off(), start: async () => refuse('TUN start') }
  }
  const unavailable = async (): Promise<never> => refuse('Core API')
  const client: MihomoClient = {
    getConfig: unavailable, setMode: unavailable, getProxyGroups: unavailable, selectProxy: unavailable, closeAllConnections: unavailable,
    traffic: () => refuse('Core stream'), logs: () => refuse('Core stream'), connections: () => refuse('Core stream')
  }
  return { files, denied, platform, client }
}

export const safeWebPreferences = (preload: string) => ({ preload, sandbox: true, contextIsolation: true, nodeIntegration: false, devTools: false })

/** This entry only lowers capabilities; it never changes helper authorization. */
export async function runRuntimeVerification(options: { app: App; window: BrowserWindow; ipc: IpcMain; directory: string; renderer: string }): Promise<void> {
  const { app, window, ipc, directory } = options
  const capabilities = verificationCapabilities()
  const store = await createAppStore({ ...capabilities, systemLocale: () => 'en',
    buildRuntimeConfig: () => { throw new Error('Runtime verification forbids Runtime Config') },
    refreshProfile: async () => { throw new Error('Runtime verification forbids Profile fetch') }
  })
  const trusted = (event: { sender: unknown }) => event.sender === window.webContents
  let backup: string | undefined
  ipc.handle(IPC.getSnapshot, event => { if (!trusted(event)) throw new Error('untrusted sender'); return store.store.getState() })
  ipc.handle(IPC.run, (event, name: CommandName, input: unknown) => trusted(event) ? store.run(name, input as never) : { ok: false, error: 'untrusted sender' })
  ipc.handle(IPC.exportBackup, async event => { if (!trusted(event)) throw new Error('untrusted sender'); backup = await store.exportBackup(); parseBackup(backup); return { ok: true } })
  ipc.handle(IPC.importBackup, async event => { if (!trusted(event) || !backup) throw new Error('No isolated Backup'); await store.importBackup(backup); return { ok: true } })
  ipc.on(IPC.streamSubscribe, () => {})
  ipc.on(IPC.streamUnsubscribe, () => {})
  window.webContents.on('will-navigate', event => event.preventDefault())
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.session.webRequest.onBeforeRequest((details, callback) => callback({ cancel: !details.url.startsWith('file://') }))
  await window.loadFile(options.renderer)
  window.show()
  const ui = await window.webContents.executeJavaScript(`(async () => {
    for (let attempt=0; !document.getElementById('root').childElementCount && attempt<150; attempt++) await new Promise(resolve=>setTimeout(resolve,20));
    const before = await window.kuro.getSnapshot();
    const language = await window.kuro.run('setLanguage', {language:'en'});
    const override = await window.kuro.run('setOverride', {yaml:'# isolated runtime verification'});
    const core = await window.kuro.run('startCore', {});
    const tun = await window.kuro.run('setTun', {enabled:true});
    const login = await window.kuro.run('setLaunchAtLogin', {enabled:true});
    const snapshot = await window.kuro.getSnapshot();
    const exported = await window.kuroFiles.exportBackup();
    const imported = await window.kuroFiles.importBackup();
    return {body:document.body.innerText, rootChildren:document.getElementById('root').childElementCount,
      cssLoaded:[...document.styleSheets].some(sheet=>sheet.href && sheet.href.includes('/assets/')),
      isolated:before.profiles.length===0 && before.activeProfileId===null, language,override,core,tun,login,
      snapshot,exported,imported, href:location.href, devtools:typeof window.require};
  })()`)
  if (!ui.isolated || !ui.rootChildren || !ui.cssLoaded || !ui.language.ok || !ui.override.ok || ui.core.ok || ui.tun.ok || ui.login.ok || !ui.exported.ok || !ui.imported.ok || ui.snapshot.resolvedLanguage !== 'en') throw new Error('Isolated UI/IPC assertions failed')
  for (const action of [() => capabilities.platform.startCore(), () => capabilities.platform.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] }), () => capabilities.platform.fetchText('https://invalid.invalid', { viaCore: false, userAgent: 'verification' })]) {
    try { await action(); throw new Error('Forbidden capability unexpectedly succeeded') } catch (error) { if (!(error instanceof Error) || !error.message.startsWith('Runtime verification forbids')) throw error }
  }
  if (window.webContents.isDevToolsOpened()) throw new Error('Production DevTools opened')
  const restored = JSON.parse(capabilities.files.get('settings.json') ?? '{}')
  if (restored.language !== 'en' || capabilities.files.get('override.yaml') !== '# isolated runtime verification') throw new Error('Isolated Backup roundtrip failed')
  const report = { version: 1, ok: true, runtime: process.versions, userData: app.getPath('userData'), sessionData: app.getPath('sessionData'), directory,
    ui, denied: capabilities.denied, files: [...capabilities.files.keys()], realPlatformCreated: false, realCoreStarted: false, realNetworkUsed: false }
  writeFileSync(join(directory, 'result.json'), JSON.stringify(report, null, 2), { flag: 'wx', mode: 0o600 })
  store.dispose()
  window.destroy()
  app.exit(0)
}
