import { useMemo, useSyncExternalStore } from 'react'
import type { StateBridge, StateSnapshot } from '@tern/state'

export function newerSnapshot(
  current: StateSnapshot | null,
  next: StateSnapshot
): StateSnapshot {
  return current && next.version < current.version ? current : next
}

export function createSnapshotStore(bridge: StateBridge) {
  let state: { snapshot: StateSnapshot | null; error: string | null } = {
    snapshot: null,
    error: null
  }
  const listeners = new Set<() => void>()
  let unsubscribe: (() => void) | undefined
  let generation = 0
  function notify() {
    for (const listener of listeners) listener()
  }
  return {
    getSnapshot: () => state,
    subscribe(listener: () => void) {
      listeners.add(listener)
      if (listeners.size === 1) {
        const activeGeneration = ++generation
        const receive = (next: StateSnapshot) => {
          if (activeGeneration !== generation) return
          const snapshot = newerSnapshot(state.snapshot, next)
          if (snapshot === state.snapshot && !state.error) return
          state = { snapshot, error: null }
          notify()
        }
        // Subscribe before reading: a slow initial read must not overwrite a live update.
        unsubscribe = bridge.subscribe(receive)
        void (async () => {
          try {
            receive(await bridge.getSnapshot())
          } catch (error) {
            if (activeGeneration !== generation) return
            state = { ...state, error: String(error) }
            notify()
          }
        })()
      }
      return () => {
        listeners.delete(listener)
        if (!listeners.size) {
          ++generation
          unsubscribe?.()
          unsubscribe = undefined
        }
      }
    }
  }
}

// shortcut: renderer-local cache, replace with @tern/state/react during integration.
export function useSnapshot(bridge: StateBridge) {
  const store = useMemo(() => createSnapshotStore(bridge), [bridge])
  return useSyncExternalStore(store.subscribe, store.getSnapshot)
}
