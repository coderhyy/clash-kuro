import { expect, test } from 'vitest'
import { FakeBridge, fakeSnapshot } from './fake'

test('records commands and publishes snapshots', async () => {
  const b = new FakeBridge()
  const seen: number[] = []
  const off = b.subscribe((s) => seen.push(s.version))
  expect(await b.run('setMode', { mode: 'global' })).toMatchObject({ ok: true })
  b.publish(fakeSnapshot({ version: 2 }))
  off()
  b.publish(fakeSnapshot({ version: 3 }))
  expect(b.calls).toEqual([{ name: 'setMode', input: { mode: 'global' } }])
  expect(seen).toEqual([2])
  expect((await b.getSnapshot()).version).toBe(3)
})
