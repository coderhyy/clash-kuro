import type { StreamHandle } from '@kuro/api'

export interface StreamHub<T> {
  subscribe(listener: (value: T) => void): () => void
  /** Call when Core may have (re)started; opens the stream if anyone is listening. */
  wake(): void
  close(): void
}

/**
 * Ref-counted Core stream: opens on the first subscriber, closes after the last.
 * Reconnects while listeners remain and `shouldConnect()` holds (Core restarts drop the socket).
 */
export function createStreamHub<T>(options: {
  open(onData: (value: T) => void, onClose: (error?: Error) => void): StreamHandle
  shouldConnect(): boolean
  /** Keep the last N values and replay them to new subscribers; 0 disables. */
  buffer?: number
  retryMs?: number
}): StreamHub<T> {
  const listeners = new Set<(value: T) => void>()
  const recent: T[] = []
  let handle: StreamHandle | null = null
  let retry: ReturnType<typeof setTimeout> | null = null

  function emit(value: T) {
    if (options.buffer) {
      recent.push(value)
      if (recent.length > options.buffer) recent.splice(0, recent.length - options.buffer)
    }
    for (const listener of listeners) listener(value)
  }

  function connect() {
    if (handle || retry !== null || !listeners.size || !options.shouldConnect()) return
    let current: StreamHandle | null = null
    let closed = false
    current = options.open(
      (value) => { if (!closed) emit(value) },
      () => {
        closed = true
        if (handle === current) handle = null
        if (!listeners.size) return
        retry = setTimeout(() => { retry = null; connect() }, options.retryMs ?? 1000)
      }
    )
    if (!closed) handle = current
  }

  function disconnect() {
    if (retry !== null) clearTimeout(retry)
    retry = null
    const current = handle
    handle = null
    current?.close()
  }

  return {
    subscribe(listener) {
      listeners.add(listener)
      for (const value of recent) listener(value)
      connect()
      return () => {
        listeners.delete(listener)
        if (!listeners.size) disconnect()
      }
    },
    wake: connect,
    close() {
      listeners.clear()
      disconnect()
    }
  }
}
