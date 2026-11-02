import { createServer } from 'node:net'
import { createSocket } from 'node:dgram'
import { expect, test } from 'vitest'
import { reserveTestPort } from './test-ports'

test('allocator holds both protocols, reports occupied candidates and releases without retrying test work', async () => {
  const busy = await reserveTestPort(), next = await reserveTestPort()
  await next.release()
  try {
    const result = await reserveTestPort([busy.port, next.port])
    try {
      expect(result.port).toBe(next.port)
      expect(result.rejected).toEqual([{ port: busy.port, protocol: 'TCP', code: 'EADDRINUSE' }])
      const probe = createServer()
      try { await expect(new Promise<void>((resolve, reject) => probe.once('error', reject).listen(result.port, '127.0.0.1', resolve))).rejects.toThrow() }
      finally { if (probe.listening) await new Promise<void>(resolve => probe.close(() => resolve())) }
    } finally { await result.release() }
    await expect(reserveTestPort([busy.port])).rejects.toThrow('No isolated TCP/UDP test port')
  } finally { await busy.release() }
})

test('UDP-only occupancy cannot be selected and does not leak the attempted TCP reservation', async () => {
  const occupied = await reserveTestPort(), next = await reserveTestPort()
  await occupied.release(); await next.release()
  const udp = createSocket('udp4')
  await new Promise<void>((resolve, reject) => udp.once('error', reject).bind(occupied.port, '127.0.0.1', resolve))
  try {
    const result = await reserveTestPort([occupied.port, next.port])
    try {
      expect(result.rejected).toEqual([{ port: occupied.port, protocol: 'UDP', code: 'EADDRINUSE' }])
      const tcp = createServer()
      await new Promise<void>((resolve, reject) => tcp.once('error', reject).listen(occupied.port, '127.0.0.1', resolve))
      await new Promise<void>(resolve => tcp.close(() => resolve()))
    } finally { await result.release() }
    await expect(reserveTestPort([0])).rejects.toThrow('Invalid test port')
  } finally { await new Promise<void>(resolve => udp.close(resolve)) }
})
