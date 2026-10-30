import { describe, expect, it, vi } from 'vitest'
import { FakeBridge, fakeSnapshot } from '@tern/state/fake'
import type { StateSnapshot } from '@tern/state'
import { createSnapshotStore, newerSnapshot } from './use-snapshot'

describe('renderer snapshot cache', () => {
  it('accepts initial and equal versions but drops lower versions', () => {
    const current = fakeSnapshot({ version: 10 })
    expect(newerSnapshot(null, current)).toBe(current)
    expect(newerSnapshot(current, fakeSnapshot({ version: 9 }))).toBe(current)
    const equal = fakeSnapshot({ version: 10 })
    expect(newerSnapshot(current, equal)).toBe(equal)
    const next = fakeSnapshot({ version: 11 })
    expect(newerSnapshot(current, next)).toBe(next)
  })
  it('subscribes before the initial read and ignores a stale async response', async () => {
    const bridge = new FakeBridge()
    let resolve!: (snapshot: StateSnapshot) => void
    bridge.getSnapshot = () =>
      new Promise((done) => {
        resolve = done
      })
    const store = createSnapshotStore(bridge)
    const listener = vi.fn()
    const unsubscribe = store.subscribe(listener)
    bridge.publish(fakeSnapshot({ version: 5 }))
    resolve(fakeSnapshot({ version: 1 }))
    await Promise.resolve()
    expect(store.getSnapshot().snapshot?.version).toBe(5)
    expect(listener).toHaveBeenCalledTimes(1)
    bridge.publish(fakeSnapshot({ version: 4 }))
    expect(listener).toHaveBeenCalledTimes(1)
    unsubscribe()
    bridge.publish(fakeSnapshot({ version: 8 }))
    expect(store.getSnapshot().snapshot?.version).toBe(5)
  })
  it('cleans up a pending read, reconnects, and shares one subscription', async () => {
    const bridge = new FakeBridge()
    const subscribe = vi.spyOn(bridge, 'subscribe')
    const store = createSnapshotStore(bridge)
    const unsubscribe = store.subscribe(() => {})
    unsubscribe()
    await Promise.resolve()
    expect(store.getSnapshot().snapshot).toBeNull()
    const first = store.subscribe(() => {})
    const second = store.subscribe(() => {})
    await Promise.resolve()
    expect(store.getSnapshot().snapshot?.version).toBe(1)
    expect(subscribe).toHaveBeenCalledTimes(2)
    first()
    bridge.publish(fakeSnapshot({ version: 7 }))
    expect(store.getSnapshot().snapshot?.version).toBe(7)
    second()
  })
  it('exposes read errors and recovers on the next push', async () => {
    const bridge = new FakeBridge()
    bridge.getSnapshot = async () => {
      throw new Error('offline')
    }
    const store = createSnapshotStore(bridge)
    const unsubscribe = store.subscribe(() => {})
    await Promise.resolve()
    expect(store.getSnapshot().error).toContain('offline')
    bridge.publish(fakeSnapshot({ version: 2 }))
    expect(store.getSnapshot().error).toBeNull()
    unsubscribe()
  })
})
