import { expect, test, vi } from 'vitest'
import { FakeBridge, fakeSnapshot } from './fake'
import { createSnapshotCache } from './index'

test('fetches complete state on every mount, ignores older/equal versions and unsubscribes', async () => {
  const bridge = new FakeBridge()
  const cache = createSnapshotCache(bridge)
  const notify = vi.fn()
  expect(cache.getSnapshot()).toBeNull()
  const off = cache.subscribe(notify)
  await Promise.resolve()
  expect(cache.getSnapshot()).toEqual(bridge.snapshot)
  bridge.publish(fakeSnapshot({ version: 3, activeProfileId: null }))
  bridge.publish(fakeSnapshot({ version: 2 }))
  bridge.publish(fakeSnapshot({ version: 3 }))
  expect(cache.getSnapshot()?.activeProfileId).toBeNull()
  expect(notify).toHaveBeenCalledTimes(2)
  off()
  bridge.publish(fakeSnapshot({ version: 4 }))
  expect(cache.getSnapshot()?.version).toBe(3)
  const rebuilt = createSnapshotCache(bridge)
  const close = rebuilt.subscribe(() => {})
  await Promise.resolve()
  expect(rebuilt.getSnapshot()).toEqual(bridge.snapshot)
  close()
})

test('a newer subscription wins over a late initial getSnapshot response', async () => {
  const bridge = new FakeBridge()
  let resolve!: (snapshot: ReturnType<typeof fakeSnapshot>) => void
  bridge.getSnapshot = () => new Promise((done) => { resolve = done })
  const cache = createSnapshotCache(bridge)
  const off = cache.subscribe(() => {})
  bridge.publish(fakeSnapshot({ version: 5 }))
  resolve(fakeSnapshot({ version: 1 }))
  await Promise.resolve()
  expect(cache.getSnapshot()?.version).toBe(5)
  off()
})

test('disposes in-flight requests and supports Strict Mode resubscription', async () => {
  const bridge = new FakeBridge()
  const cache = createSnapshotCache(bridge)
  const notify = vi.fn()
  cache.subscribe(notify)()
  await Promise.resolve()
  expect(notify).not.toHaveBeenCalled()
  const off = cache.subscribe(notify)
  await Promise.resolve()
  expect(cache.getSnapshot()?.version).toBe(1)
  off()
})

test('surfaces initial fetch errors instead of an unhandled rejection, and can retry', async () => {
  const bridge = new FakeBridge()
  const original = bridge.getSnapshot.bind(bridge)
  bridge.getSnapshot = async () => { throw new Error('IPC unavailable') }
  const cache = createSnapshotCache(bridge)
  const off = cache.subscribe(() => {})
  await Promise.resolve()
  expect(() => cache.getSnapshot()).toThrow('IPC unavailable')
  off()
  bridge.getSnapshot = original
  const close = cache.subscribe(() => {})
  await Promise.resolve()
  expect(cache.getSnapshot()?.version).toBe(1)
  close()
})
