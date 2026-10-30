import { expect, test } from 'vitest'
import { FakePlatform } from './fake'

test('applyRuntimeConfig keeps the old config when validation fails', async () => {
  const p = new FakePlatform()
  expect(await p.applyRuntimeConfig('a')).toEqual({ ok: true })
  p.validate = () => ({ ok: false, error: 'bad' })
  expect(await p.applyRuntimeConfig('b')).toEqual({ ok: false, error: 'bad' })
  expect(p.runtimeConfig).toBe('a')
})

test('onResume unsubscribes', () => {
  const p = new FakePlatform()
  let n = 0
  const off = p.onResume(() => n++)
  p.resume()
  off()
  p.resume()
  expect(n).toBe(1)
})
