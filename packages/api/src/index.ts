import type { LogLevel, Mode } from '@tern/core'

export interface HttpRequest {
  method: 'GET' | 'PUT' | 'PATCH' | 'DELETE'
  /** e.g. `/proxies/GLOBAL`; caller encodes path segments. */
  path: string
  body?: unknown
}

export interface HttpResponse {
  status: number
  /** Parsed JSON, or null for an empty body. */
  body: unknown
}

export interface StreamHandle {
  close(): void
}

/** How the client reaches Core; injected by the host (unix socket, named pipe, or a fake). */
export interface Transport {
  request(req: HttpRequest): Promise<HttpResponse>
  /** Open a WebSocket on `path`; each text frame is JSON-parsed and passed to `onMessage`. */
  stream(path: string, onMessage: (data: unknown) => void, onClose?: (error?: Error) => void): StreamHandle
}

export interface Proxy {
  name: string
  type: string
  /** Latest delay in ms; null when untested or timed out. */
  delay: number | null
}

export interface ProxyGroup {
  name: string
  type: string
  /** Currently selected member. */
  now: string
  all: string[]
}

export interface CoreConfig {
  mode: Mode
  mixedPort: number
  allowLan: boolean
  logLevel: LogLevel
}

export interface Traffic {
  up: number
  down: number
}

export interface LogEntry {
  level: LogLevel
  payload: string
}

export interface ConnectionsSummary {
  uploadTotal: number
  downloadTotal: number
  count: number
}

/** Typed mihomo REST/WebSocket client. Errors reject with a readable message. */
export interface MihomoClient {
  getConfig(): Promise<CoreConfig>
  setMode(mode: Mode): Promise<void>
  getProxyGroups(): Promise<{ groups: ProxyGroup[]; proxies: Record<string, Proxy> }>
  selectProxy(group: string, proxy: string): Promise<void>
  closeAllConnections(): Promise<void>
  /** `onClose` fires once when the stream ends, whether Core dropped it or `close()` was called. */
  traffic(onData: (t: Traffic) => void, onClose?: (error?: Error) => void): StreamHandle
  logs(onData: (l: LogEntry) => void, onClose?: (error?: Error) => void): StreamHandle
  connections(onData: (c: ConnectionsSummary) => void, onClose?: (error?: Error) => void): StreamHandle
}

export * from './client'
