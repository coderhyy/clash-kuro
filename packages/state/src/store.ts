import { createStore, type StoreApi } from 'zustand/vanilla'
import type { MihomoClient } from '@tern/api'
import type { ControlChannel, Platform, Profile, Settings } from '@tern/core'
import { LOG_BUFFER_SIZE, type CommandInput, type CommandName, type CommandOutput, type CommandResult, type StateBridge, type StateSnapshot } from './index'
import type { LogEntry, Traffic } from '@tern/api'
import { createStreamHub } from './streams'

export interface AppStoreDeps {
  platform: Platform
  client: MihomoClient
  /** Reads the Profile's original content; must not mutate it. */
  buildRuntimeConfig(input: { profile: Profile; settings: Settings; controlChannel: ControlChannel }): string | Promise<string>
  /** Fetches/imports original content and returns updated metadata; rejects without destroying old content. */
  refreshProfile(profile: Profile): Promise<Profile>
  hooks?: {
    onOpenWindow?(): void | Promise<void>
    onQuit?(): void | Promise<void>
  }
}

export interface AppStore extends StateBridge {
  store: StoreApi<StateSnapshot>
  /** Close live streams; call on shutdown. */
  dispose(): void
}

type SavedState = Pick<StateSnapshot, 'settings' | 'profiles' | 'activeProfileId'>

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

/** Hydrates settings.json before exposing the bridge. All commands share one execution queue. */
export async function createAppStore(deps: AppStoreDeps): Promise<AppStore> {
  const { platform, client } = deps
  const saved = await platform.readFile('settings.json')
  const initial: SavedState = saved === null ? {
    settings: { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' },
    profiles: [],
    activeProfileId: null
  } : JSON.parse(saved)
  validateSettings(initial.settings)
  if (!Array.isArray(initial.profiles)) throw new Error('Invalid saved Profiles')
  initial.profiles.forEach(validateProfile)
  if (new Set(initial.profiles.map((p) => p.id)).size !== initial.profiles.length) throw new Error('Duplicate Profile IDs')
  if (initial.activeProfileId !== null && !initial.profiles.some((p) => p.id === initial.activeProfileId)) throw new Error('Invalid Active Profile')
  const running = await platform.isCoreRunning()
  const store = createStore<StateSnapshot>(() => ({
    ...initial,
    version: 0,
    core: { status: running ? 'running' : 'stopped', error: null },
    proxyGroups: [],
    proxies: {},
    systemProxy: { enabled: false },
    update: null
  }))

  const coreUp = () => store.getState().core.status === 'running'
  const traffic = createStreamHub<Traffic>({ open: (onData, onClose) => client.traffic(onData, onClose), shouldConnect: coreUp })
  const logs = createStreamHub<LogEntry>({ open: (onData, onClose) => client.logs(onData, onClose), shouldConnect: coreUp, buffer: LOG_BUFFER_SIZE })

  function change(patch: Partial<StateSnapshot>): void {
    store.setState((state) => ({ ...patch, version: state.version + 1 }))
    if (patch.core?.status === 'running') { traffic.wake(); logs.wake() }
  }

  async function persist(patch: Partial<SavedState>): Promise<void> {
    const { settings, profiles, activeProfileId } = { ...store.getState(), ...patch }
    await platform.writeFileAtomic('settings.json', JSON.stringify({ settings, profiles, activeProfileId }))
    change(patch)
  }

  function profile(id: string): Profile {
    const found = store.getState().profiles.find((p) => p.id === id)
    if (!found) throw new Error(`Unknown Profile: ${id}`)
    return found
  }

  async function syncProxies(): Promise<void> {
    const { groups, proxies } = await client.getProxyGroups()
    change({ proxyGroups: groups, proxies })
  }

  async function prepareRuntime(selected: Profile, settings = store.getState().settings): Promise<void> {
    const yaml = await deps.buildRuntimeConfig({ profile: selected, settings, controlChannel: platform.controlChannel() })
    const result = await platform.applyRuntimeConfig(yaml)
    if (!result.ok) throw new Error(result.error)
  }

  async function start(): Promise<void> {
    change({ core: { status: 'starting', error: null } })
    try {
      await platform.startCore()
    } catch (error) {
      change({ core: { status: 'error', error: message(error) } })
      throw error
    }
    change({ core: { status: 'running', error: null } })
    await syncProxies()
  }

  async function reloadIfRunning(): Promise<void> {
    if (!await platform.isCoreRunning()) return
    const restoreProxy = store.getState().systemProxy.enabled
    // Platform has no hot-reload operation; validate/replace before stopping the old Core.
    await stop()
    await start()
    if (restoreProxy) await setSystemProxy(true)
  }

  async function setSystemProxy(enabled: boolean): Promise<void> {
    if (typeof enabled !== 'boolean') throw new Error('Invalid System Proxy toggle')
    if (!enabled) {
      await platform.clearSystemProxy()
      change({ systemProxy: { enabled: false } })
      return
    }
    if (!await platform.isCoreRunning()) throw new Error('Core is not running')
    const target = { host: '127.0.0.1', port: store.getState().settings.mixedPort }
    try {
      await platform.setSystemProxy({ ...target, bypass: ['localhost', '127.0.0.1', '::1'] })
      change({ systemProxy: { enabled: true } })
    } catch (error) {
      change({ systemProxy: { enabled: false, manualRequired: target } })
      throw error
    }
  }

  async function stop(): Promise<void> {
    // Do not stop Core if clearing System Proxy failed: that would leave a dead proxy behind.
    await setSystemProxy(false)
    await platform.stopCore()
    change({ core: { status: 'stopped', error: null }, proxyGroups: [], proxies: {} })
  }

  const handlers: { [K in CommandName]: (input: CommandInput<K>) => Promise<CommandOutput<K>> } = {
    async setMode({ mode }) {
      const settings = { ...store.getState().settings, mode }
      validateSettings(settings)
      await persist({ settings })
      if (await platform.isCoreRunning()) await client.setMode(mode)
    },
    async selectProxy({ group, proxy }) {
      if (typeof group !== 'string' || !group || typeof proxy !== 'string' || !proxy) throw new Error('Invalid Proxy selection')
      await client.selectProxy(group, proxy)
      await syncProxies()
    },
    async setSystemProxy({ enabled }) {
      await setSystemProxy(enabled)
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
      if (await platform.isCoreRunning()) return
      const id = store.getState().activeProfileId
      if (id === null) throw new Error('No Active Profile')
      await prepareRuntime(profile(id))
      await start()
    },
    async stopCore() {
      await stop()
    },
    async openWindow() {
      await deps.hooks?.onOpenWindow?.()
    },
    async quit() {
      await stop()
      await deps.hooks?.onQuit?.()
    }
  }

  const currentProxy = await platform.getSystemProxy()
  if (currentProxy?.host === '127.0.0.1' && currentProxy.port === initial.settings.mixedPort) change({ systemProxy: { enabled: true } })
  if (running) await syncProxies()
  let pending: Promise<unknown> = Promise.resolve()
  return {
    store,
    getSnapshot: async () => store.getState(),
    subscribeTraffic: (listener) => traffic.subscribe(listener),
    subscribeLogs: (listener) => logs.subscribe(listener),
    dispose() { traffic.close(); logs.close() },
    subscribe: (listener) => store.subscribe(listener),
    run<K extends CommandName>(name: K, input: CommandInput<K>): Promise<CommandResult<K>> {
      const result = pending.then(async (): Promise<CommandResult<K>> => {
        try {
          if (!Object.hasOwn(handlers, name) || input === null || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid command')
          return { ok: true, value: await handlers[name](input) }
        } catch (error) {
          return { ok: false, error: message(error) }
        }
      })
      pending = result
      return result
    }
  }
}
