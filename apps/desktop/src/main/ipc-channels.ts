/** IPC channel names shared by main and preload. */
export const IPC = {
  getSnapshot: 'tern:getSnapshot',
  run: 'tern:run',
  snapshot: 'tern:snapshot',
  /** Renderer → main: start/stop a live stream; main → renderer: stream events. */
  streamSubscribe: 'tern:stream:subscribe',
  streamUnsubscribe: 'tern:stream:unsubscribe',
  traffic: 'tern:traffic',
  logs: 'tern:logs',
  pickProfileFile: 'tern:pickProfileFile'
} as const

export type StreamKind = 'traffic' | 'logs'
