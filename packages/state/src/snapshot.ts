import type { StateBridge, StateSnapshot } from './index'

/** One cache per mounted consumer. Subscribe before fetching so an IPC race cannot lose updates. */
export function createSnapshotCache(bridge: StateBridge) {
  let snapshot: StateSnapshot | null = null
  let failure: Error | null = null
  let generation = 0
  return {
    getSnapshot(): StateSnapshot | null {
      if (failure) throw failure
      return snapshot
    },
    subscribe(notify: () => void): () => void {
      const current = ++generation
      function receive(next: StateSnapshot): void {
        if (current !== generation || (snapshot !== null && next.version <= snapshot.version)) return
        snapshot = next
        failure = null
        notify()
      }
      const off = bridge.subscribe(receive)
      void bridge.getSnapshot().then(receive, (error: unknown) => {
        if (current !== generation || snapshot !== null) return
        failure = error instanceof Error ? error : new Error(String(error))
        notify()
      })
      return () => { ++generation; off() }
    }
  }
}
