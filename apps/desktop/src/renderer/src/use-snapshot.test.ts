import { expect, test } from 'vitest'
import { FakeBridge, fakeSnapshot } from '@kuro/state/fake'
import { createSnapshotView } from './use-snapshot'

test('view returns a stable object until the snapshot changes, and drops older versions', async () => {
  const bridge = new FakeBridge(fakeSnapshot({ version: 3 }))
  const view = createSnapshotView(bridge)
  const off = view.subscribe(() => {})
  await Promise.resolve()
  const first = view.getSnapshot()
  expect(first.snapshot?.version).toBe(3)
  expect(view.getSnapshot()).toBe(first)
  bridge.publish(fakeSnapshot({ version: 2 }))
  expect(view.getSnapshot()).toBe(first)
  bridge.publish(fakeSnapshot({ version: 4 }))
  expect(view.getSnapshot().snapshot?.version).toBe(4)
  off()
})

test('an initial read failure becomes an error value, not a throw', async () => {
  const bridge = new FakeBridge()
  bridge.getSnapshot = () => Promise.reject(new Error('ipc down'))
  const view = createSnapshotView(bridge)
  view.subscribe(() => {})
  await new Promise((r) => setTimeout(r, 0))
  expect(view.getSnapshot()).toEqual({ snapshot: null, error: 'Error: ipc down' })
})
