import { mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import type { TunStatus } from '@kuro/core'
import { createMacosTun, parseTunResponse, requestTunHelper } from './macos-tun'

const off: TunStatus = { availability: 'ready', state: 'off' }
const on: TunStatus = { availability: 'ready', state: 'on' }

test('absent installation is off and cannot be started', async () => {
  const request = vi.fn()
  const tun = createMacosTun({ endpointPresent: async () => false, request })
  expect(await tun.inspect()).toEqual({ availability: 'not-installed', state: 'off' })
  expect((await tun.recover()).state).toBe('off')
  await expect(tun.start()).rejects.toThrow('not installed')
  expect(request).not.toHaveBeenCalled()
})

test('unreadable or retained installation is unknown, never silently off', async () => {
  const tun = createMacosTun({ endpointPresent: async () => { throw new Error('retained state without socket') } })
  expect(await tun.inspect()).toEqual({ availability: 'blocked', state: 'unknown', error: 'retained state without socket' })
  await expect(tun.start()).rejects.toThrow('retained state')
})

test('blocked but proven-off helper does not receive state-changing requests', async () => {
  const status: TunStatus = { availability: 'blocked', state: 'off', error: 'client attestation incomplete' }
  const request = vi.fn(async (_operation: string) => status)
  const tun = createMacosTun({ endpointPresent: async () => true, request })
  expect(await tun.stop()).toEqual(status)
  await expect(tun.start()).rejects.toThrow('attestation incomplete')
  expect(request.mock.calls).toEqual([['status'], ['status']])
})

test('start and stop require independent status confirmation', async () => {
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on).mockResolvedValueOnce(on)
    .mockResolvedValueOnce(on).mockResolvedValueOnce(off).mockResolvedValueOnce(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request })
  expect(await tun.start()).toEqual(on)
  expect(await tun.stop()).toEqual(off)
  expect(request.mock.calls.flat()).toEqual(['status', 'start', 'status', 'status', 'stop', 'status'])
})

test('successful stop reply cannot override an unknown readback', async () => {
  const request = vi.fn().mockResolvedValueOnce(on).mockResolvedValueOnce(off)
    .mockResolvedValueOnce({ availability: 'blocked', state: 'unknown', error: 'readback failed' })
  const tun = createMacosTun({ endpointPresent: async () => true, request })
  await expect(tun.stop()).rejects.toThrow('readback failed')
})

test.each([
  {}, { version: 2, ok: true, status: off },
  { version: 1, ok: true, status: { availability: 'ready', state: 'unknown' } },
  { version: 1, ok: true, status: { ...off, command: '/bin/sh' } },
  { version: 1, ok: true, status: { availability: 'not-installed', state: 'off' } },
  { version: 1, ok: true, status: { availability: ['ready'], state: 'off' } },
  { version: 1, ok: true, status: { availability: 'ready', state: ['off'] } },
  { version: 1, ok: false, error: 'denied', status: off },
])('rejects malformed or ambiguous native response %j', value => {
  expect(() => parseTunResponse(JSON.stringify(value))).toThrow()
})

test('native denial is surfaced without a fabricated status', () => {
  expect(() => parseTunResponse('{"version":1,"ok":false,"error":"authorization denied"}')).toThrow('authorization denied')
})

test.skipIf(process.platform === 'win32')('real local socket exchanges bounded versioned frames without starting a service', async ({ onTestFinished }) => {
  const dir = await mkdtemp(join('/tmp', 'kuro-tun-wire-'))
  const path = join(dir, 's')
  let received = ''
  const server = createServer({ allowHalfOpen: true }, socket => {
    socket.on('data', chunk => { received += chunk.toString() })
    socket.on('end', () => socket.end(`${JSON.stringify({ version: 1, ok: true, status: off })}\n`))
  })
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(path, resolve) })
  onTestFinished(async () => { await new Promise<void>(resolve => server.close(() => resolve())); await rm(dir, { recursive: true, force: true }) })
  expect(await requestTunHelper('status', path)).toEqual(off)
  expect(received).toBe('{"version":1,"operation":"status"}\n')
})

test.skipIf(process.platform === 'win32')('hung peer has a deadline and cannot later publish success', async ({ onTestFinished }) => {
  const dir = await mkdtemp(join('/tmp', 'kt-timeout-'))
  const path = join(dir, 's')
  const sockets = new Set<import('node:net').Socket>()
  const server = createServer({ allowHalfOpen: true }, socket => { sockets.add(socket); socket.resume() })
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(path, resolve) })
  onTestFinished(async () => { for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve())); await rm(dir, { recursive: true, force: true }) })
  await expect(requestTunHelper('status', path, 30)).rejects.toThrow('timed out')
})
