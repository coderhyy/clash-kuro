import { useCallback, useMemo, useSyncExternalStore } from 'react'
import type { CommandInput, CommandName, StateBridge, StateSnapshot } from './index'
import { createSnapshotCache } from './snapshot'

/** null until the first full snapshot arrives; bridge errors reach the React error boundary. */
export function useSnapshot(bridge: StateBridge): StateSnapshot | null {
  const cache = useMemo(() => createSnapshotCache(bridge), [bridge])
  return useSyncExternalStore(cache.subscribe, cache.getSnapshot, cache.getSnapshot)
}

export function useCommand<K extends CommandName>(bridge: StateBridge, name: K) {
  return useCallback((input: CommandInput<K>) => bridge.run(name, input), [bridge, name])
}
