import { expect, test } from 'vitest'
import { FakeTransport } from './fake'

test('routes requests and records them', async () => {
  const t = new FakeTransport().on('GET', '/configs', { status: 200, body: { mode: 'rule' } })
  expect(await t.request({ method: 'GET', path: '/configs' })).toEqual({ status: 200, body: { mode: 'rule' } })
  expect((await t.request({ method: 'GET', path: '/nope' })).status).toBe(404)
  expect(t.requests).toHaveLength(2)
})

test('streams receive pushes until closed', () => {
  const t = new FakeTransport()
  const got: unknown[] = []
  const h = t.stream('/traffic', (d) => got.push(d))
  t.push('/traffic', 1)
  h.close()
  t.push('/traffic', 2)
  expect(got).toEqual([1])
  expect(t.openStreams('/traffic')).toBe(0)
})
