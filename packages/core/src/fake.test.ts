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

test('stopCore clears System Proxy while Core is still running', async () => {
  const p = new FakePlatform()
  p.coreRunning = true
  p.systemProxy = { host: '127.0.0.1', port: 7890, bypass: [] }
  const clear = p.clearSystemProxy.bind(p)
  p.clearSystemProxy = async () => {
    expect(p.coreRunning).toBe(true)
    await clear()
  }

  await p.stopCore()

  expect(p.systemProxy).toBeNull()
  expect(p.coreRunning).toBe(false)
})

test('stopCore refuses to stop Core when System Proxy cleanup fails', async () => {
  const p = new FakePlatform()
  p.coreRunning = true
  p.systemProxy = { host: '127.0.0.1', port: 7890, bypass: [] }
  p.clearSystemProxy = async () => { throw new Error('cleanup failed') }

  await expect(p.stopCore()).rejects.toThrow('cleanup failed')

  expect(p.coreRunning).toBe(true)
  expect(p.systemProxy).not.toBeNull()
})
