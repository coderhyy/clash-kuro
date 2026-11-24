import type { TunSessionConfig } from './tun-config'

export type Mode = 'rule' | 'global' | 'direct'
export type LogLevel = 'silent' | 'error' | 'warning' | 'info' | 'debug'

export type ProfileSource = { kind: 'remote'; url: string } | { kind: 'local'; path: string }

/** From the `subscription-userinfo` response header. Bytes; `expireAt` is a Unix timestamp in seconds. */
export interface SubscriptionInfo {
  upload: number
  download: number
  total: number
  expireAt?: number
}

export interface Profile {
  id: string
  name: string
  source: ProfileSource
  /** Unix ms of the last successful fetch/import. */
  updatedAt: number | null
  /** Set when the last update failed; old content is kept. */
  lastError: string | null
  subscriptionInfo: SubscriptionInfo | null
  /** From `profile-update-interval`; null when the server did not send it. */
  serverUpdateIntervalHours: number | null
  /** User override; wins over the server value. */
  userUpdateIntervalHours: number | null
}

/** App-managed Fields that the user controls (CONTEXT.md). Control Channel is filled in by the desktop app. */
export interface Settings {
  mode: Mode
  mixedPort: number
  allowLan: boolean
  logLevel: LogLevel
}

export type ControlChannel = { kind: 'unix'; path: string } | { kind: 'pipe'; name: string }

export interface SystemProxySettings {
  host: string
  port: number
  bypass: string[]
}

export type ValidationResult = { ok: true } | { ok: false; error: string }

export interface FetchResult {
  status: number
  /** Header names lower-cased. */
  headers: Record<string, string>
  body: string
}

/** Observed TUN state, never a persisted enable preference. Unknown must block new network writers. */
export interface TunStatus {
  availability: 'unsupported' | 'not-installed' | 'ready' | 'blocked'
  state: 'off' | 'on' | 'unknown'
  error?: string
}

/** The adapter owns configuration admission and exact Core/network cleanup evidence. */
export interface TunPlatform {
  /** Invalidates an observed state; consumers must inspect, never infer cleanup or restart. */
  subscribe?(listener: () => void): () => void
  inspect(): Promise<TunStatus>
  recover(): Promise<TunStatus>
  start(config: TunSessionConfig): Promise<TunStatus>
  stop(): Promise<TunStatus>
}

/**
 * System capabilities injected into the shared packages (ADR-0001).
 * File names are relative to the app data directory.
 */
export interface Platform {
  tun?: TunPlatform
  readFile(name: string): Promise<string | null>
  /** Write to a temp file and rename into place. */
  writeFileAtomic(name: string, data: string): Promise<void>
  removeFile(name: string): Promise<void>

  /** Validate with `mihomo -t`; on success atomically replace the Runtime Config (ADR-0003). */
  applyRuntimeConfig(yaml: string): Promise<ValidationResult>
  /** Start Core with the current Runtime Config. Resolves once the Control Channel answers. */
  startCore(): Promise<void>
  /**
   * Own System Proxy cleanup before stopping Core; resolve only when both are confirmed.
   * Reject failed/unknown cleanup or stop. A native owner may still stop Core after its cleanup deadline.
   */
  stopCore(): Promise<void>
  isCoreRunning(): Promise<boolean>
  controlChannel(): ControlChannel

  getSystemProxy(): Promise<SystemProxySettings | null>
  setSystemProxy(settings: SystemProxySettings): Promise<void>
  clearSystemProxy(): Promise<void>

  /** HTTP GET for profiles. `viaCore` routes through Core's mixed-port. */
  fetchText(url: string, options: { viaCore: boolean; userAgent: string }): Promise<FetchResult>
  /** Subscribe to system resume; returns an unsubscribe function. */
  onResume(listener: () => void): () => void

  /** Launch at Login as the OS reports it; never persisted by the app (CONTEXT.md). */
  getLaunchAtLogin(): Promise<LaunchAtLoginStatus>
  setLaunchAtLogin(enabled: boolean): Promise<void>
}

/** `unpackaged`: dev build, registering would add the bare Electron binary. `requires-approval`: macOS waits for the user in System Settings. */
export type LaunchAtLoginStatus = 'unsupported' | 'unpackaged' | 'disabled' | 'enabled' | 'requires-approval'

export * from './config'
export * from './profile-update'

export * from './tun-config'
