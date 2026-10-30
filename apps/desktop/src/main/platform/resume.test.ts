import { EventEmitter } from 'node:events'
import { expect, test, vi } from 'vitest'
import { createDesktopPlatform } from './index'
import { createResumeHandler } from './resume'

test.each([true, false])('resume running=%s closes stale connections or restarts, then reapplies proxy', async (running) => {
  const order: string[] = []
  const platform = { isCoreRunning: async () => running, startCore: async () => { order.push('start') } }
  const handler = createResumeHandler({
    platform, client: { closeAllConnections: async () => { order.push('close') } },
    reapplySystemProxy: async () => { order.push('proxy') },
  })
  await Promise.all([handler(), handler()])
  expect(order).toEqual([running ? 'close' : 'start', 'proxy'])
  await handler()
  expect(order).toHaveLength(4)
})

test('reapplies proxy and surfaces errors even when connection cleanup fails', async () => {
  const reapplySystemProxy = vi.fn(async () => {})
  const handler = createResumeHandler({
    platform: { isCoreRunning: async () => true, startCore: async () => {} },
    closeAllConnections: async () => { throw new Error('offline') }, reapplySystemProxy,
  })
  await expect(handler()).rejects.toThrow('offline')
  expect(reapplySystemProxy).toHaveBeenCalledOnce()
})

test('requires a connection cleanup implementation', () => {
  expect(() => createResumeHandler({
    platform: { isCoreRunning: async () => true, startCore: async () => {} }, reapplySystemProxy: async () => {},
  })).toThrow('requires')
})

test('failed restart never enables a proxy pointing at a dead Core', async () => {
  const reapplySystemProxy = vi.fn(async () => {})
  const handler = createResumeHandler({
    platform: { isCoreRunning: async () => false, startCore: async () => { throw new Error('port occupied') } },
    closeAllConnections: async () => {}, reapplySystemProxy,
  })
  await expect(handler()).rejects.toThrow('port occupied')
  expect(reapplySystemProxy).not.toHaveBeenCalled()
})

test('powerMonitor is injected and can be unsubscribed', () => {
  const powerMonitor = new EventEmitter()
  const platform = createDesktopPlatform({ dataDir: '/tmp/tern-resume', corePath: '/unused', mixedPort: 17890, powerMonitor })
  const listener = vi.fn()
  const off = platform.onResume(listener)
  powerMonitor.emit('resume')
  off()
  powerMonitor.emit('resume')
  expect(listener).toHaveBeenCalledOnce()
})
