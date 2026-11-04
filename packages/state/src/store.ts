import { createStore, type StoreApi } from 'zustand/vanilla'
import type { MihomoClient } from '@kuro/api'
import type { ControlChannel, Platform, Profile, Settings, TunSessionConfig, TunStatus } from '@kuro/core'
import { parseOverride } from '@kuro/core'
import { LOG_BUFFER_SIZE, type CommandInput, type CommandName, type CommandOutput, type CommandResult, type Language, type LanguagePreference, type StateBridge, type StateSnapshot } from './index'
import type { LogEntry, Traffic } from '@kuro/api'
import { createStreamHub } from './streams'
import { BACKUP_FORMAT, backupProfileFile, parseBackup, type Backup } from './backup'

export interface AppStoreDeps {
  platform: Platform
  client: MihomoClient
  systemLocale(): string
  /** Reads the Profile's original content; must not mutate it. */
  buildRuntimeConfig(input: { profile: Profile; settings: Settings; controlChannel: ControlChannel; override: string }): string | Promise<string>
  /** Admit a restricted session before stopping the currently working mode. */
  buildTunConfig?(input: { profile: Profile; settings: Settings; override: string }): TunSessionConfig | Promise<TunSessionConfig>
  /** Fetches/imports original content and returns updated metadata; rejects without destroying old content. */
  refreshProfile(profile: Profile): Promise<Profile>
  hooks?: {
    onOpenWindow?(): void | Promise<void>
    /** Owns full shutdown, including System Proxy cleanup and Core stop. */
    onQuit?(): void | Promise<void>
  }
}

export interface AppStore extends StateBridge {
  store: StoreApi<StateSnapshot>
  exportBackup(): Promise<string>
  importBackup(json: string): Promise<void>
  /** Re-read Launch at Login from the OS; the user may change it in System Settings. */
  refreshLaunchAtLogin(): Promise<void>
  /** Main-only: resume ordinary Core within the existing mode-transition queue. */
  resumeCore(): Promise<void>
  /** Main-only: unexpected native owner exit. Immediately blocks Core/proxy writes until app restart. */
  notifyCoreStopped(reason: string): void
  /** Close live streams; call on shutdown. */
  dispose(): void
}

/** settings.json as stored; unknown fields survive Backup round trips but are not part of the snapshot. */
export type SavedState = Pick<StateSnapshot, 'settings' | 'profiles' | 'activeProfileId'> & Record<string, unknown>
type PersistedState = Pick<StateSnapshot, 'settings' | 'profiles' | 'activeProfileId' | 'language'>

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function validateSettings(settings: Settings): void {
  if (!['rule', 'global', 'direct'].includes(settings.mode)) throw new Error('Invalid mode')
  if (!Number.isInteger(settings.mixedPort) || settings.mixedPort < 1 || settings.mixedPort > 65535) throw new Error('Invalid mixed-port')
  if (typeof settings.allowLan !== 'boolean') throw new Error('Invalid allow-lan')
  if (!['silent', 'error', 'warning', 'info', 'debug'].includes(settings.logLevel)) throw new Error('Invalid log-level')
}

function validateInterval(hours: number | null): void {
  if (hours !== null && (typeof hours !== 'number' || !Number.isFinite(hours) || hours <= 0)) throw new Error('Invalid update interval')
}

function validateProfile(profile: Profile): void {
  if (!profile || typeof profile.id !== 'string' || !profile.id || typeof profile.name !== 'string' || !profile.name.trim()) throw new Error('Invalid Profile')
  const source = profile.source
  if (!source || (source.kind !== 'local' && source.kind !== 'remote')) throw new Error('Invalid Profile source')
  if (source.kind === 'local' && (typeof source.path !== 'string' || !source.path.trim())) throw new Error('Invalid Profile path')
  if (source.kind === 'remote' && (typeof source.url !== 'string' || !/^https?:\/\/[^\s/]+(?:\/[^\s]*)?$/i.test(source.url))) throw new Error('Invalid Profile URL')
  if (profile.updatedAt !== null && (typeof profile.updatedAt !== 'number' || !Number.isFinite(profile.updatedAt) || profile.updatedAt < 0)) throw new Error('Invalid Profile update time')
  if (profile.lastError !== null && typeof profile.lastError !== 'string') throw new Error('Invalid Profile error')
  if (profile.subscriptionInfo !== null) {
    const info = profile.subscriptionInfo
    if (!info || [info.upload, info.download, info.total, info.expireAt ?? 0].some((value) => typeof value !== 'number' || !Number.isFinite(value) || value < 0)) throw new Error('Invalid Subscription Info')
  }
  validateInterval(profile.userUpdateIntervalHours)
  validateInterval(profile.serverUpdateIntervalHours)
}

export function validateSavedState(value: unknown): asserts value is SavedState {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid saved state')
  const initial = value as SavedState
  if (!initial.settings || typeof initial.settings !== 'object' || Array.isArray(initial.settings)) throw new Error('Invalid settings')
  validateSettings(initial.settings)
  if (!Array.isArray(initial.profiles)) throw new Error('Invalid saved Profiles')
  initial.profiles.forEach(validateProfile)
  if (new Set(initial.profiles.map((p) => p.id)).size !== initial.profiles.length) throw new Error('Duplicate Profile IDs')
  if (initial.activeProfileId !== null && !initial.profiles.some((p) => p.id === initial.activeProfileId)) throw new Error('Invalid Active Profile')
}

/** Hydrates settings.json before exposing the bridge. Commands share a queue except host-owned quit. */
export async function createAppStore(deps: AppStoreDeps): Promise<AppStore> {
  const { platform, client } = deps
  const saved = await platform.readFile('settings.json')
  const initial: unknown = saved === null ? {
    settings: { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' },
    profiles: [],
    activeProfileId: null
  } : JSON.parse(saved)
  validateSavedState(initial)
  // A missing or unknown language (old settings.json or Backup) falls back instead of blocking startup.
  const language: LanguagePreference = ['system', 'zh-CN', 'en'].includes(initial.language as string) ? initial.language as LanguagePreference : 'system'
  function resolveLanguage(language: LanguagePreference): Language {
    return language === 'system' ? (deps.systemLocale().startsWith('zh') ? 'zh-CN' : 'en') : language
  }
  const running = await platform.isCoreRunning()
  const launchAtLogin = await platform.getLaunchAtLogin()
  const override = await platform.readFile('override.yaml') ?? ''
  const store = createStore<StateSnapshot>(() => ({
    settings: initial.settings,
    profiles: initial.profiles,
    activeProfileId: initial.activeProfileId,
    language,
    resolvedLanguage: resolveLanguage(language),
    version: 0,
    core: { status: running ? 'running' : 'stopped', error: null },
    proxyGroups: [],
    proxies: {},
    systemProxy: { enabled: false },
    tun: { availability: 'unsupported', state: 'off' },
    update: null,
    launchAtLogin,
    override
  }))

  let restartError: string | null = null
  let tunError: string | null = null
  let closing = false
  let tunTransition = false
  const coreUp = () => restartError === null && tunError === null && !closing && !tunTransition && store.getState().tun.state === 'off' && store.getState().core.status === 'running'
  const traffic = createStreamHub<Traffic>({ open: (onData, onClose) => client.traffic(onData, onClose), shouldConnect: coreUp })
  const logs = createStreamHub<LogEntry>({ open: (onData, onClose) => client.logs(onData, onClose), shouldConnect: coreUp, buffer: LOG_BUFFER_SIZE })

  function change(patch: Partial<StateSnapshot>): void {
    store.setState((state) => ({ ...patch, version: state.version + 1 }))
    if (patch.core || patch.tun) { traffic.wake(); logs.wake() }
  }

  function requireNativeSession(): void {
    if (restartError !== null) throw new Error(restartError)
    if (closing) throw new Error('Application is closing')
  }

  function requireSession(): void {
    requireNativeSession()
    if (tunError !== null) throw new Error(tunError)
  }

  function blockTun(error: unknown, status: TunStatus = { availability: 'blocked', state: 'unknown' }): void {
    tunError = message(error)
    traffic.wake()
    logs.wake()
    change({ tun: { ...status, availability: 'blocked', error: tunError }, systemProxy: { enabled: false, unknown: true } })
  }

  async function inspectTun(): Promise<TunStatus> {
    if (!platform.tun) return store.getState().tun
    const status = await platform.tun.inspect()
    requireNativeSession()
    change({ tun: { ...status } })
    requireNativeSession()
    if (status.state === 'unknown') blockTun(status.error ?? 'TUN state is unknown; recover before changing the network.', status)
    return status
  }

  async function performTun(operation: 'start' | 'stop' | 'recover', config?: TunSessionConfig): Promise<TunStatus> {
    requireNativeSession()
    if (!platform.tun) throw new Error('TUN is unsupported')
    if (operation === 'start' && !config) throw new Error('TUN configuration admission is unavailable')
    let observed: TunStatus | undefined
    tunTransition = true
    try {
      change({ tun: { availability: store.getState().tun.availability, state: 'unknown' } })
      requireNativeSession()
      const result = operation === 'start' ? await platform.tun.start(config!) : await platform.tun[operation]()
      requireNativeSession()
      observed = await inspectTun()
      requireNativeSession()
      const expected = operation === 'start' ? 'on' : 'off'
      if (result.state !== expected || observed.state !== expected || (operation === 'start' && (result.availability !== 'ready' || observed.availability !== 'ready'))) {
        throw new Error(result.error ?? observed.error ?? `TUN ${operation} was not confirmed ${expected}`)
      }
      if (operation !== 'start') tunError = null
      return observed
    } catch (error) {
      requireNativeSession()
      if (!observed) {
        try { observed = await inspectTun() } catch { /* No readback means the network remains unknown. */ }
        requireNativeSession()
      }
      if (observed?.state === 'off') {
        tunError = null
        change({ tun: { ...observed, error: message(error) } })
      } else blockTun(error, observed)
      throw error
    } finally { tunTransition = false }
  }

  async function stopTunIfNeeded(beforeStop?: () => Promise<void>): Promise<boolean> {
    requireSession()
    let status: TunStatus
    try { status = await inspectTun() } catch (error) {
      requireNativeSession()
      blockTun(error)
      throw error
    }
    requireSession()
    if (status.state === 'off') return false
    await beforeStop?.()
    requireSession()
    await performTun('stop')
    requireSession()
    change({ core: { status: 'stopped', error: null }, proxyGroups: [], proxies: {} })
    requireSession()
    return true
  }

  function tunStoppedForReload(): void {
    change({ tun: { ...store.getState().tun, error: 'TUN was stopped for configuration changes. Enable it manually.' } })
  }

  async function persist(patch: Partial<PersistedState>): Promise<void> {
    const { settings, profiles, activeProfileId, language } = { ...store.getState(), ...patch }
    const resolvedLanguage = patch.language === undefined ? store.getState().resolvedLanguage : resolveLanguage(language)
    await platform.writeFileAtomic('settings.json', JSON.stringify({ settings, profiles, activeProfileId, language }))
    change({ ...patch, resolvedLanguage })
  }

  function profile(id: string): Profile {
    const found = store.getState().profiles.find((p) => p.id === id)
    if (!found) throw new Error(`Unknown Profile: ${id}`)
    return found
  }

  async function syncProxies(): Promise<void> {
    requireSession()
    const { groups, proxies } = await client.getProxyGroups()
    requireSession()
    change({ proxyGroups: groups, proxies })
  }

  async function prepareRuntime(selected: Profile, settings = store.getState().settings, override = store.getState().override): Promise<void> {
    requireSession()
    const yaml = await deps.buildRuntimeConfig({ profile: selected, settings, controlChannel: platform.controlChannel(), override })
    requireSession()
    const result = await platform.applyRuntimeConfig(yaml)
    requireSession()
    if (!result.ok) throw new Error(result.error)
  }

  async function start(): Promise<void> {
    requireSession()
    await stopTunIfNeeded()
    requireSession()
    change({ core: { status: 'starting', error: null } })
    try {
      requireSession()
      await platform.startCore()
      requireSession()
    } catch (error) {
      requireSession()
      change({ core: { status: 'error', error: message(error) } })
      throw error
    }
    change({ core: { status: 'running', error: null } })
    await syncProxies()
  }

  async function reloadIfRunning(): Promise<void> {
    requireSession()
    if (await stopTunIfNeeded()) {
      await stop()
      tunStoppedForReload()
      return
    }
    requireSession()
    const running = await platform.isCoreRunning()
    requireSession()
    if (!running) return
    const restoreProxy = store.getState().systemProxy.enabled
    // Platform has no hot-reload operation; validate/replace before stopping the old Core.
    await stop()
    await start()
    if (restoreProxy) await setSystemProxy(true)
  }

  async function setSystemProxy(enabled: boolean): Promise<void> {
    requireSession()
    if (typeof enabled !== 'boolean') throw new Error('Invalid System Proxy toggle')
    if (!enabled) {
      await platform.clearSystemProxy()
      requireSession()
      change({ systemProxy: { enabled: false } })
      return
    }
    if (await stopTunIfNeeded(async () => {
      const id = store.getState().activeProfileId
      if (id === null) throw new Error('No Active Profile')
      await prepareRuntime(profile(id))
    })) {
      await start()
    }
    const running = await platform.isCoreRunning()
    requireSession()
    if (!running) throw new Error('Core is not running')
    const target = { host: '127.0.0.1', port: store.getState().settings.mixedPort }
    try {
      await platform.setSystemProxy({ ...target, bypass: ['localhost', '127.0.0.1', '::1'] })
      requireSession()
      change({ systemProxy: { enabled: true } })
    } catch (error) {
      requireSession()
      change({ systemProxy: { enabled: false, manualRequired: target } })
      throw error
    }
  }

  async function stop(): Promise<void> {
    if (restartError !== null) return
    requireSession()
    await stopTunIfNeeded()
    requireSession()
    await platform.stopCore()
    requireSession()
    change({ core: { status: 'stopped', error: null }, systemProxy: { enabled: false }, proxyGroups: [], proxies: {} })
  }

  async function readLaunchAtLogin(): Promise<void> {
    const next = await platform.getLaunchAtLogin()
    if (next !== store.getState().launchAtLogin) change({ launchAtLogin: next })
  }

  const handlers: { [K in CommandName]: (input: CommandInput<K>) => Promise<CommandOutput<K>> } = {
    async setLanguage({ language }) {
      if (!['system', 'zh-CN', 'en'].includes(language)) throw new Error('Invalid language')
      await persist({ language })
    },
    async setMode({ mode }) {
      const settings = { ...store.getState().settings, mode }
      validateSettings(settings)
      await persist({ settings })
      if (restartError !== null || tunError !== null || closing) return
      if (await stopTunIfNeeded()) {
        await stop()
        tunStoppedForReload()
        return
      }
      const running = await platform.isCoreRunning()
      if (running && restartError === null && tunError === null && !closing) await client.setMode(mode)
    },
    async selectProxy({ group, proxy }) {
      requireSession()
      if (typeof group !== 'string' || !group || typeof proxy !== 'string' || !proxy) throw new Error('Invalid Proxy selection')
      if (store.getState().tun.state !== 'off') throw new Error('TUN proxy selection requires a validated broker')
      await client.selectProxy(group, proxy)
      await syncProxies()
    },
    async setSystemProxy({ enabled }) {
      await setSystemProxy(enabled)
    },
    async setTun({ enabled }) {
      if (typeof enabled !== 'boolean') throw new Error('Invalid TUN toggle')
      requireSession()
      if (!enabled) { await stopTunIfNeeded(); return }
      if (!platform.tun) throw new Error('TUN is unsupported')
      let status: TunStatus
      try { status = await inspectTun() } catch (error) {
        requireNativeSession()
        blockTun(error)
        throw error
      }
      requireSession()
      if (status.availability !== 'ready') throw new Error(status.error ?? `TUN is ${status.availability}`)
      if (status.state === 'on') return
      if (store.getState().activeProfileId === null) throw new Error('No Active Profile')
      if (!deps.buildTunConfig) throw new Error('TUN configuration admission is unavailable')
      const current = store.getState()
      const config = await deps.buildTunConfig({ profile: profile(current.activeProfileId!), settings: current.settings, override: current.override })
      requireSession()
      await stop()
      requireSession()
      await performTun('start', config)
      requireSession()
      change({ core: { status: 'running', error: null }, proxyGroups: [], proxies: {} })
      requireSession()
    },
    async recoverTun() {
      requireNativeSession()
      if (!platform.tun) return
      await performTun('recover')
      requireNativeSession()
      const running = await platform.isCoreRunning()
      requireNativeSession()
      change({ core: { status: running ? 'running' : 'stopped', error: null } })
      requireNativeSession()
    },
    async setLaunchAtLogin({ enabled }) {
      if (typeof enabled !== 'boolean') throw new Error('Invalid Launch at Login toggle')
      const status = store.getState().launchAtLogin
      if (status === 'unsupported' || status === 'unpackaged') throw new Error(`Launch at Login is ${status}`)
      try {
        await platform.setLaunchAtLogin(enabled)
      } finally {
        await readLaunchAtLogin()
      }
    },
    async importProfile({ name, source }) {
      let id = `p-${Date.now()}`
      while (store.getState().profiles.some((p) => p.id === id)) id += '-1'
      const candidate: Profile = { id, name, source, updatedAt: null, lastError: null, subscriptionInfo: null, serverUpdateIntervalHours: null, userUpdateIntervalHours: null }
      validateProfile(candidate)
      const refreshed = await deps.refreshProfile(candidate)
      validateProfile(refreshed)
      if (refreshed.id !== id) throw new Error('refreshProfile changed Profile ID')
      await persist({ profiles: [...store.getState().profiles, refreshed] })
      return { profileId: id }
    },
    async updateProfile({ profileId }) {
      const previous = profile(profileId)
      let refreshed: Profile
      try {
        refreshed = await deps.refreshProfile(previous)
        validateProfile(refreshed)
        if (refreshed.id !== previous.id) throw new Error('refreshProfile changed Profile ID')
        if (store.getState().activeProfileId === profileId) await prepareRuntime(refreshed)
      } catch (error) {
        await persist({ profiles: store.getState().profiles.map((p) => p.id === profileId ? { ...previous, lastError: message(error) } : p) })
        throw error
      }
      await persist({ profiles: store.getState().profiles.map((p) => p.id === profileId ? refreshed : p) })
      if (store.getState().activeProfileId === profileId) await reloadIfRunning()
    },
    async removeProfile({ profileId }) {
      profile(profileId)
      if (store.getState().activeProfileId === profileId) await stop()
      await persist({
        profiles: store.getState().profiles.filter((p) => p.id !== profileId),
        activeProfileId: store.getState().activeProfileId === profileId ? null : store.getState().activeProfileId
      })
    },
    async setActiveProfile({ profileId }) {
      const selected = profile(profileId)
      await prepareRuntime(selected)
      await persist({ activeProfileId: profileId })
      await reloadIfRunning()
    },
    async updateSettings({ settings: patch, profileUpdateIntervalHours }) {
      if (!patch || typeof patch !== 'object' || Object.keys(patch).some((key) => !['mixedPort', 'allowLan', 'logLevel'].includes(key))) throw new Error('Invalid settings patch')
      const state = store.getState()
      const settings = { ...state.settings, ...patch }
      validateSettings(settings)
      let profiles = state.profiles
      if (profileUpdateIntervalHours !== undefined) {
        const { profileId, hours } = profileUpdateIntervalHours
        profile(profileId)
        validateInterval(hours)
        profiles = profiles.map((p) => p.id === profileId ? { ...p, userUpdateIntervalHours: hours } : p)
      }
      const configChanged = Object.keys(patch).length > 0
      if (configChanged && state.activeProfileId !== null) await prepareRuntime(profile(state.activeProfileId), settings)
      await persist({ settings, profiles })
      if (configChanged) await reloadIfRunning()
    },
    async startCore() {
      requireSession()
      const prepared = await stopTunIfNeeded(async () => {
        const id = store.getState().activeProfileId
        if (id === null) throw new Error('No Active Profile')
        await prepareRuntime(profile(id))
      })
      requireSession()
      const running = await platform.isCoreRunning()
      requireSession()
      if (running) return
      const id = store.getState().activeProfileId
      if (id === null) throw new Error('No Active Profile')
      if (!prepared) await prepareRuntime(profile(id))
      await start()
    },
    async stopCore() {
      await stop()
    },
    async openWindow() {
      await deps.hooks?.onOpenWindow?.()
    },
    async quit() {
      if (deps.hooks?.onQuit) {
        closing = true
        traffic.close()
        logs.close()
        if (platform.tun && store.getState().tun.state !== 'off') {
          change({ tun: { availability: 'blocked', state: 'unknown', error: 'Application is closing; network cleanup is pending.' } })
        }
        await deps.hooks.onQuit()
      } else {
        if (tunError !== null && restartError === null) await performTun('recover')
        await stop()
        closing = true
      }
    },
    async setOverride({ yaml }) {
      if (typeof yaml !== 'string') throw new Error('Invalid Override YAML')
      const parsed = parseOverride(yaml)
      if (!parsed.ok) throw new Error(parsed.error)
      const { activeProfileId, settings } = store.getState()
      if (activeProfileId !== null) await prepareRuntime(profile(activeProfileId), settings, yaml)
      await platform.writeFileAtomic('override.yaml', yaml)
      change({ override: yaml })
      if (activeProfileId !== null) await reloadIfRunning()
    }
  }

  if (platform.tun) {
    try { await inspectTun() } catch (error) { blockTun(error) }
    try {
      if (store.getState().tun.state !== 'off') await performTun('recover')
      const currentRunning = await platform.isCoreRunning()
      change({ core: { status: currentRunning ? 'running' : 'stopped', error: null } })
    } catch (error) {
      if (store.getState().tun.state !== 'off') blockTun(error, store.getState().tun)
    }
  }

  // A blocked or failing System Proxy probe must not prevent the app from starting.
  const currentProxy = await platform.getSystemProxy().catch(() => null)
  if (tunError === null && currentProxy?.host === '127.0.0.1' && currentProxy.port === initial.settings.mixedPort) change({ systemProxy: { enabled: true } })
  if (coreUp()) await syncProxies()
  let pending: Promise<unknown> = Promise.resolve()
  let restartRequired = false
  function assertNotImported(): void {
    if (restartRequired) throw new Error('Backup import requires an application restart')
  }
  function enqueue<T>(task: () => Promise<T>): Promise<T> {
    const result = pending.then(task)
    pending = result.catch(() => {})
    return result
  }

  async function exportBackup(): Promise<string> {
    assertNotImported()
    const { settings, profiles, activeProfileId } = store.getState()
    const saved: unknown = JSON.parse((await platform.readFile('settings.json')) ?? JSON.stringify({ settings, profiles, activeProfileId }))
    validateSavedState(saved)
    const contents = await Promise.all(saved.profiles.map(async (profile) => {
      const content = await platform.readFile(backupProfileFile(profile.id))
      if (content === null) throw new Error(`Profile content is missing: ${profile.id}`)
      return [profile.id, content] as const
    }))
    const backup: Backup = {
      format: BACKUP_FORMAT, version: 1, createdAt: new Date().toISOString(),
      settings: saved, profiles: Object.fromEntries(contents), override: await platform.readFile('override.yaml')
    }
    return JSON.stringify(backup)
  }

  /** Writes a Backup's files, removing Profile contents only `others` had; settings.json goes last as the commit point. */
  async function writeBackupFiles(backup: Backup, others: string[]): Promise<void> {
    for (const profile of backup.settings.profiles) await platform.writeFileAtomic(backupProfileFile(profile.id), backup.profiles[profile.id]!)
    if (backup.override === null) await platform.removeFile('override.yaml')
    else await platform.writeFileAtomic('override.yaml', backup.override)
    for (const id of others) {
      if (!Object.hasOwn(backup.profiles, id)) await platform.removeFile(backupProfileFile(id))
    }
    await platform.writeFileAtomic('settings.json', JSON.stringify(backup.settings))
  }

  return {
    store,
    resumeCore: () => enqueue(async () => {
      assertNotImported()
      requireSession()
      const snapshot = store.getState()
      if (snapshot.core.status !== 'running' || snapshot.tun.state !== 'off') return
      const restoreProxy = snapshot.systemProxy.enabled
      const running = await platform.isCoreRunning()
      requireSession()
      if (running) {
        try { await client.closeAllConnections() }
        finally {
          requireSession()
          if (restoreProxy) await setSystemProxy(true)
        }
      } else {
        await handlers.startCore({})
        requireSession()
        if (restoreProxy) await setSystemProxy(true)
      }
    }),
    exportBackup: () => enqueue(exportBackup),
    importBackup: (json) => enqueue(async () => {
      assertNotImported()
      requireSession()
      const backup = parseBackup(json)
      const previous = store.getState().profiles
      const recoveryFile = `backups/pre-import-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
      const current = await exportBackup()
      await platform.writeFileAtomic(recoveryFile, current)
      // Restored as-is on failure, even if it would not pass parseBackup (e.g. a hand-edited override.yaml).
      const recovery = JSON.parse(current) as Backup
      await stop()
      requireSession()
      // A partial write must not let queued Commands persist stale metadata over imported files.
      restartRequired = true
      try {
        await writeBackupFiles(backup, previous.map((p) => p.id))
      } catch (error) {
        try {
          await writeBackupFiles(recovery, backup.settings.profiles.map((p) => p.id))
        } catch (restoreError) {
          throw new Error(`Backup import failed: ${message(error)}. Restoring the previous data also failed (${message(restoreError)}); restart the application and restore ${recoveryFile}`)
        }
        // Disk matches the store again, so Commands are safe; Core stays stopped until the user starts it.
        restartRequired = false
        throw new Error(`Backup import failed: ${message(error)}. The previous data was restored.`)
      }
    }),
    notifyCoreStopped(reason) {
      if (restartError !== null) return
      restartError = `${reason}. Restart the app before starting Core or changing System Proxy; System Proxy cleanup is unknown.`
      traffic.close()
      logs.close()
      change({
        core: { status: 'stopped', error: restartError, restartRequired: true },
        systemProxy: { enabled: false, unknown: true },
        ...(platform.tun ? { tun: { availability: 'blocked' as const, state: 'unknown' as const, error: restartError } } : {}),
        proxyGroups: [], proxies: {}
      })
    },
    getSnapshot: async () => store.getState(),
    refreshLaunchAtLogin: () => enqueue(readLaunchAtLogin),
    subscribeTraffic: (listener) => traffic.subscribe(listener),
    subscribeLogs: (listener) => logs.subscribe(listener),
    dispose() { closing = true; traffic.close(); logs.close() },
    subscribe: (listener) => store.subscribe(listener),
    run<K extends CommandName>(name: K, input: CommandInput<K>): Promise<CommandResult<K>> {
      const execute = async (): Promise<CommandResult<K>> => {
        try {
          if (name !== 'quit') assertNotImported()
          if (!Object.hasOwn(handlers, name) || input === null || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid command')
          return { ok: true, value: await handlers[name](input) }
        } catch (error) {
          return { ok: false, error: message(error) }
        }
      }
      if (name === 'quit' && deps.hooks?.onQuit) return execute()
      return enqueue(execute)
    }
  }
}
