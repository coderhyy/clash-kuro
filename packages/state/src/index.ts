import type { LogEntry, ProxyGroup, Proxy, Traffic } from '@tern/api'
import type { Mode, Profile, ProfileSource, Settings } from '@tern/core'

export type CoreStatus = 'stopped' | 'starting' | 'running' | 'error'

export type SystemProxyStatus =
  | { enabled: false }
  | { enabled: true }
  /** macOS `networksetup` refused (ADR-0009); UI tells the user to set it manually. */
  | { enabled: false; manualRequired: { host: string; port: number } }

/** Full state the main process pushes to renderers. Always complete; renderers never patch it. */
export interface StateSnapshot {
  /** Bumped on every change so subscribers can drop stale snapshots. */
  version: number
  core: { status: CoreStatus; error: string | null }
  settings: Settings
  profiles: Profile[]
  activeProfileId: string | null
  proxyGroups: ProxyGroup[]
  proxies: Record<string, Proxy>
  systemProxy: SystemProxyStatus
  /** Newer release on GitHub, if any (ADR-0010). */
  update: { version: string; url: string } | null
}

/** Typed requests from the window or tray to the main process (CONTEXT.md: Command). */
export interface Commands {
  setMode(input: { mode: Mode }): void
  selectProxy(input: { group: string; proxy: string }): void
  setSystemProxy(input: { enabled: boolean }): void
  importProfile(input: { name: string; source: ProfileSource }): { profileId: string }
  updateProfile(input: { profileId: string }): void
  removeProfile(input: { profileId: string }): void
  setActiveProfile(input: { profileId: string }): void
  updateSettings(input: { settings: Partial<Omit<Settings, 'mode'>>; profileUpdateIntervalHours?: { profileId: string; hours: number | null } }): void
  startCore(input: Record<string, never>): void
  stopCore(input: Record<string, never>): void
  openWindow(input: Record<string, never>): void
  quit(input: Record<string, never>): void
}

export type CommandName = keyof Commands
export type CommandInput<K extends CommandName> = Parameters<Commands[K]>[0]
export type CommandOutput<K extends CommandName> = ReturnType<Commands[K]>

/** Errors come back as a readable message; never throw across IPC. */
export type CommandResult<K extends CommandName> =
  | { ok: true; value: CommandOutput<K> }
  | { ok: false; error: string }

/** What a renderer sees of the main process (exposed by preload). */
export interface StateBridge {
  getSnapshot(): Promise<StateSnapshot>
  subscribe(listener: (snapshot: StateSnapshot) => void): () => void
  run<K extends CommandName>(name: K, input: CommandInput<K>): Promise<CommandResult<K>>
  /** Live events, not part of the snapshot. Core's WebSocket stays open only while someone is subscribed. */
  subscribeTraffic(listener: (traffic: Traffic) => void): () => void
  /** Replays the recent buffer (at most LOG_BUFFER_SIZE entries), then streams new entries. */
  subscribeLogs(listener: (entry: LogEntry) => void): () => void
}

export const LOG_BUFFER_SIZE = 500

export * from './store'
export * from './tray'
export * from './snapshot'
export * from './streams'
