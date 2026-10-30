/** IPC channel names shared by main and preload. */
export const IPC = {
  getSnapshot: 'kuro:getSnapshot',
  run: 'kuro:run',
  snapshot: 'kuro:snapshot',
  /** Renderer → main: start/stop a live stream; main → renderer: stream events. */
  streamSubscribe: 'kuro:stream:subscribe',
  streamUnsubscribe: 'kuro:stream:unsubscribe',
  traffic: 'kuro:traffic',
  logs: 'kuro:logs',
  pickProfileFile: 'kuro:pickProfileFile'
} as const

export type StreamKind = 'traffic' | 'logs'
