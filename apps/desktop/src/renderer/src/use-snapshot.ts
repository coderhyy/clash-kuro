import { useMemo, useSyncExternalStore } from 'react'
import type { StateBridge, StateSnapshot } from '@tern/state'
import { createSnapshotCache } from '@tern/state'

/** Shared cache from @tern/state (drops older versions); errors surface as a value for the connection screen. */
export function createSnapshotView(bridge: StateBridge) {
  const inner = createSnapshotCache(bridge)
  let last = { snapshot: null as StateSnapshot | null, error: null as string | null }
  return {
    subscribe: inner.subscribe,
    getSnapshot() {
      let next
      try { next = { snapshot: inner.getSnapshot(), error: null } } catch (error) { next = { snapshot: last.snapshot, error: String(error) } }
      if (next.snapshot !== last.snapshot || next.error !== last.error) last = next
      return last
    }
  }
}

export function useSnapshot(bridge: StateBridge): { snapshot: StateSnapshot | null; error: string | null } {
  const cache = useMemo(() => createSnapshotView(bridge), [bridge])
  return useSyncExternalStore(cache.subscribe, cache.getSnapshot)
}
