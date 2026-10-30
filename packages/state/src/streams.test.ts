import { expect, test, vi } from 'vitest'
import { FakeTransport } from '@tern/api/fake'
import { createStreamHub } from './streams'

function hub(t: FakeTransport, connect = () => true, buffer = 0) {
  return createStreamHub<unknown>({
    open: (onData, onClose) => t.stream('/logs', onData, onClose),
    shouldConnect: connect,
    buffer,
    retryMs: 10
  })
}

test('opens only while subscribed', () => {
  const t = new FakeTransport()
  const h = hub(t)
  expect(t.openStreams('/logs')).toBe(0)
  const offA = h.subscribe(() => {})
  const offB = h.subscribe(() => {})
  expect(t.openStreams('/logs')).toBe(1)
  offA()
  expect(t.openStreams('/logs')).toBe(1)
  offB()
  expect(t.openStreams('/logs')).toBe(0)
})

test('keeps a bounded buffer and replays it', () => {
  const t = new FakeTransport()
  const h = hub(t, () => true, 2)
  const off = h.subscribe(() => {})
  for (const n of [1, 2, 3]) t.push('/logs', n)
  off()
  const got: unknown[] = []
  h.subscribe((v) => got.push(v))
  t.push('/logs', 4)
  expect(got).toEqual([2, 3, 4])
})

test('waits for Core, then reconnects after the stream drops', async () => {
  vi.useFakeTimers()
  const t = new FakeTransport()
  let running = false
  const h = hub(t, () => running)
  h.subscribe(() => {})
  expect(t.openStreams('/logs')).toBe(0)
  running = true
  h.wake()
  expect(t.openStreams('/logs')).toBe(1)
  t.drop('/logs')
  expect(t.openStreams('/logs')).toBe(0)
  await vi.advanceTimersByTimeAsync(10)
  expect(t.openStreams('/logs')).toBe(1)
  vi.useRealTimers()
})
