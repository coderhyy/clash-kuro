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

/**
 * System capabilities injected into the shared packages (ADR-0001).
 * File names are relative to the app data directory.
 */
export interface Platform {
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
