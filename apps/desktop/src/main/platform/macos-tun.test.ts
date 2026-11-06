import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Socket } from 'node:net'
import { join } from 'node:path'
import { expect, onTestFinished, test, vi } from 'vitest'
import type { TunSessionConfig, TunStatus } from '@kuro/core'
import { FakePlatform } from '@kuro/core/fake'
import { FakeTransport } from '@kuro/api/fake'
import { createMihomoClient } from '@kuro/api'
import { createAppStore } from '@kuro/state'
import { fakeSnapshot } from '@kuro/state/fake'
import { createMacosTun, openTunHelperSession, parseTunResponse, requestTunHelper } from './macos-tun'

const off: TunStatus = { availability: 'ready', state: 'off' }
const on: TunStatus = { availability: 'ready', state: 'on' }
const config: TunSessionConfig = {
  version: 1, template: 'macos-dual-stack-v1', mode: 'rule', proxies: [], groups: [],
  rules: [{ type: 'MATCH', value: '', target: 'DIRECT', noResolve: false }],
  dns: { nameservers: ['192.0.2.53'], bootstrap: ['2001:db8::53'], proxyNameservers: ['192.0.2.54'], policies: [] },
}
const sessionId = '46c21f68-d929-4bf9-8adf-de4f27a33809'
const opened = { version: 2, ok: true, session: sessionId, leaseMilliseconds: 15000, sequence: 0, status: on }


test('absent installation is off and cannot be started', async () => {
  const request = vi.fn()
  const tun = createMacosTun({ endpointPresent: async () => false, request })
  expect(await tun.inspect()).toEqual({ availability: 'not-installed', state: 'off' })
  expect((await tun.recover()).state).toBe('off')
  await expect(tun.start(config)).rejects.toThrow('not installed')
  expect(request).not.toHaveBeenCalled()
})

test('unreadable or retained installation is unknown, never silently off', async () => {
  const tun = createMacosTun({ endpointPresent: async () => { throw new Error('retained state without socket') } })
  expect(await tun.inspect()).toEqual({ availability: 'blocked', state: 'unknown', error: 'retained state without socket' })
  await expect(tun.start(config)).rejects.toThrow('retained state')
})

test('blocked but proven-off helper does not receive state-changing requests', async () => {
  const status: TunStatus = { availability: 'blocked', state: 'off', error: 'client attestation incomplete' }
  const request = vi.fn(async (_operation: string) => status)
  const tun = createMacosTun({ endpointPresent: async () => true, request })
  expect(await tun.stop()).toEqual(status)
  await expect(tun.start(config)).rejects.toThrow('attestation incomplete')
  expect(request.mock.calls).toEqual([['status'], ['status']])
})

test('start carries a validated copy over V2 and stop requires independent status confirmation', async () => {
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on).mockResolvedValueOnce(off)
  const owner = { stop: vi.fn(async () => off), error: () => undefined, disconnect: vi.fn() }
  const open = vi.fn(async (_config: TunSessionConfig) => owner)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open })
  expect(await tun.start(config)).toEqual(on)
  expect(open.mock.calls[0]![0]).toEqual(config)
  expect(open.mock.calls[0]![0]).not.toBe(config)
  expect(await tun.stop()).toEqual(off)
  expect(owner.stop).toHaveBeenCalledOnce()
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status'])
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

test('invalid configuration is rejected before any endpoint or transport access', async () => {
  const present = vi.fn(async () => true)
  const request = vi.fn()
  const open = vi.fn()
  const tun = createMacosTun({ endpointPresent: present, request, open })
  const bad = { ...config, command: '/bin/sh' }
  await expect(tun.start(bad)).rejects.toThrow('unsupported field')
  await expect(openTunHelperSession(bad, '/nonexistent')).rejects.toThrow('unsupported field')
  expect(present).not.toHaveBeenCalled()
  expect(request).not.toHaveBeenCalled()
  expect(open).not.toHaveBeenCalled()
})

test('a failed start readback disconnects its session; a disconnected owner stays unknown until proven off', async () => {
  let failure: Error | undefined
  const owner = { stop: vi.fn(async () => { throw failure }), error: () => failure,
    disconnect: vi.fn(() => { failure = new Error('session disconnected') }) }
  const request = vi.fn().mockResolvedValueOnce(off).mockRejectedValueOnce(new Error('readback failed'))
    .mockResolvedValueOnce(on).mockResolvedValueOnce(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await expect(tun.start(config)).rejects.toThrow('readback failed')
  expect(owner.disconnect).toHaveBeenCalledOnce()
  expect(await tun.inspect()).toEqual({ availability: 'blocked', state: 'unknown', error: 'session disconnected' })
  expect(await tun.inspect()).toEqual(off)
})

test('active stop attempts session cleanup even when preflight status is unreadable, then reads status independently', async () => {
  const owner = { stop: vi.fn(async () => { throw new Error('lost stop reply') }), error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on).mockResolvedValueOnce(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  expect(await tun.stop()).toEqual(off)
  expect(owner.stop).toHaveBeenCalledOnce()
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status'])
})

test('an active session stop acknowledgement cannot override an unknown independent readback', async () => {
  const owner = { stop: vi.fn(async () => off), error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on)
    .mockResolvedValueOnce({ availability: 'blocked', state: 'unknown', error: 'cleanup journal retained' })
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  await expect(tun.stop()).rejects.toThrow('cleanup journal retained')
  expect(owner.disconnect).toHaveBeenCalledOnce()
})

// These are unprivileged temporary sockets; fixtures do not attest the production helper or start Core.
async function fixture(onFrame: (frame: Record<string, unknown>, socket: Socket) => void) {
  const dir = await mkdtemp(join('/tmp', 'kt-v2-'))
  const path = join(dir, 's')
  const sockets = new Set<Socket>()
  const server = createServer(socket => {
    sockets.add(socket)
    let bytes = ''
    socket.on('data', data => {
      bytes += data.toString()
      while (bytes.includes('\n')) {
        const index = bytes.indexOf('\n')
        const frame = JSON.parse(bytes.slice(0, index)) as Record<string, unknown>
        bytes = bytes.slice(index + 1)
        onFrame(frame, socket)
      }
    })
    socket.on('error', () => {})
  })
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(path, resolve) })
  return { path, dispose: async () => {
    for (const socket of sockets) socket.destroy()
    await new Promise<void>(resolve => server.close(() => resolve()))
    await rm(dir, { recursive: true, force: true })
  } }
}
function reply(socket: Socket, value: unknown) { socket.write(`${JSON.stringify(value)}\n`) }

test.skipIf(process.platform === 'win32')('V2 sends the complete config, bounded heartbeats and exact monotonically sequenced stop', async ({ onTestFinished }) => {
  const frames: Record<string, unknown>[] = []
  let heartbeat!: () => void
  const heartbeatReceived = new Promise<void>(resolve => { heartbeat = resolve })
  const peer = await fixture((frame, socket) => {
    frames.push(frame)
    if (frame.operation === 'open') reply(socket, opened)
    else if (frame.operation === 'heartbeat') {
      reply(socket, { version: 2, ok: true, sequence: frame.sequence })
      heartbeat()
    } else reply(socket, { version: 2, ok: true, sequence: frame.sequence, status: off })
  })
  onTestFinished(peer.dispose)
  const session = await openTunHelperSession(config, peer.path, { heartbeatMs: 10 })
  onTestFinished(() => session.disconnect())
  await heartbeatReceived
  expect(await session.stop()).toEqual(off)
  expect(session.error()).toBeUndefined()
  expect(frames[0]).toEqual({ version: 2, operation: 'open', config })
  expect(frames.slice(1)).toEqual([
    { version: 2, operation: 'heartbeat', session: sessionId, sequence: 1 },
    { version: 2, operation: 'stop', session: sessionId, sequence: 2 },
  ])
})

test.skipIf(process.platform === 'win32').each([
  { ...opened, version: 1 }, { ...opened, sequence: 1 }, { ...opened, leaseMilliseconds: 999999 },
  { ...opened, session: '/bin/sh' }, { ...opened, status: off }, { ...opened, command: 'start' },
  { version: 2, ok: false, error: 'root authorization gate denied' },
])('rejects invalid or denied V2 open %j without a V1 fallback', async response => {
  const frames: unknown[] = []
  const peer = await fixture((frame, socket) => { frames.push(frame); reply(socket, response) })
  onTestFinished(peer.dispose)
  await expect(openTunHelperSession(config, peer.path)).rejects.toThrow()
  expect(frames).toHaveLength(1)
  expect(frames[0]).toEqual({ version: 2, operation: 'open', config })
})

test.skipIf(process.platform === 'win32').each([
  '{"version":2,"ok":true,"sequence":0,"session":"' + sessionId + '","leaseMilliseconds":15000,"status":{"availability":"ready","state":"on","st\\u0061te":"off"}}\n',
  JSON.stringify(opened) + '\n{}\n',
  'x'.repeat(65537),
])('rejects duplicate keys, pipelined frames and oversized replies', async response => {
  const peer = await fixture((_frame, socket) => socket.write(response))
  onTestFinished(peer.dispose)
  await expect(openTunHelperSession(config, peer.path)).rejects.toThrow()
})

test.skipIf(process.platform === 'win32')('invalid UTF-8 cannot be decoded into a successful session', async ({ onTestFinished }) => {
  const peer = await fixture((_frame, socket) => socket.write(Buffer.concat([Buffer.from([0xff]), Buffer.from(JSON.stringify(opened) + '\n')])))
  onTestFinished(peer.dispose)
  await expect(openTunHelperSession(config, peer.path)).rejects.toThrow()
})

test.skipIf(process.platform === 'win32')('wrong heartbeat sequence disconnects the session and prevents further commands', async ({ onTestFinished }) => {
  let replied!: () => void
  const badReplySent = new Promise<void>(resolve => { replied = resolve })
  const frames: unknown[] = []
  const peer = await fixture((frame, socket) => {
    frames.push(frame)
    if (frame.operation === 'open') reply(socket, opened)
    else { reply(socket, { version: 2, ok: true, sequence: 0 }); replied() }
  })
  onTestFinished(peer.dispose)
  const session = await openTunHelperSession(config, peer.path, { heartbeatMs: 5 })
  onTestFinished(() => session.disconnect())
  await badReplySent
  await vi.waitFor(() => expect(session.error()?.message).toContain('sequence'))
  await expect(session.stop()).rejects.toThrow('sequence')
  expect(frames).toHaveLength(2)
})

test.skipIf(process.platform === 'win32')('a hung heartbeat has one outstanding request and no stop is pipelined behind it', async ({ onTestFinished }) => {
  const frames: Record<string, unknown>[] = []
  let received!: () => void
  const heartbeatReceived = new Promise<void>(resolve => { received = resolve })
  const peer = await fixture((frame, socket) => {
    frames.push(frame)
    if (frame.operation === 'open') reply(socket, opened)
    else received()
  })
  onTestFinished(peer.dispose)
  const session = await openTunHelperSession(config, peer.path, { timeoutMs: 40, heartbeatMs: 5 })
  onTestFinished(() => session.disconnect())
  await heartbeatReceived
  await expect(session.stop()).rejects.toThrow('timed out')
  expect(session.error()?.message).toContain('unknown')
  expect(frames.map(frame => frame.operation)).toEqual(['open', 'heartbeat'])
})

test.skipIf(process.platform === 'win32')('EOF after open is unknown and an opening timeout cannot later become success', async ({ onTestFinished }) => {
  const peer = await fixture((_frame, socket) => { reply(socket, opened); socket.end() })
  onTestFinished(peer.dispose)
  const session = await openTunHelperSession(config, peer.path)
  await vi.waitFor(() => expect(session.error()?.message).toContain('disconnected'))
  await expect(session.stop()).rejects.toThrow('disconnected')
  const hung = await fixture(() => {})
  onTestFinished(hung.dispose)
  await expect(openTunHelperSession(config, hung.path, { timeoutMs: 20 })).rejects.toThrow('timed out')
})

test.skipIf(process.platform === 'win32')('opening preserves an exact native failure after the shorter command budget', async () => {
  let received!: () => void
  const frameReceived = new Promise<void>(resolve => { received = resolve })
  let connection!: Socket
  const peer = await fixture((_frame, socket) => { connection = socket; received() })
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  try {
    const outcome = openTunHelperSession(config, peer.path).then(() => 'unexpected success', error => (error as Error).message)
    await frameReceived
    await vi.advanceTimersByTimeAsync(2500)
    reply(connection, { version: 2, ok: false, error: 'fixed dual-stack utun addresses are not uniquely ready' })
    expect(await outcome).toBe('fixed dual-stack utun addresses are not uniquely ready')
  } finally { vi.useRealTimers(); await peer.dispose() }
})

test.skipIf(process.platform === 'win32')('opening has a finite independent budget and cannot accept late success', async () => {
  let received!: () => void
  const frameReceived = new Promise<void>(resolve => { received = resolve })
  let connection!: Socket
  const peer = await fixture((_frame, socket) => { connection = socket; received() })
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  try {
    let settled = false
    const outcome = openTunHelperSession(config, peer.path).then(() => 'unexpected success', error => (error as Error).message).finally(() => { settled = true })
    await frameReceived
    await vi.advanceTimersByTimeAsync(14999)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    expect(await outcome).toBe('TUN session response timed out; network state unknown')
    reply(connection, opened)
    expect(await outcome).toBe('TUN session response timed out; network state unknown')
  } finally { vi.useRealTimers(); await peer.dispose() }
})

test.skipIf(process.platform === 'win32').each(['heartbeat', 'stop'] as const)('default %s replies still have the shorter command budget', async operation => {
  let received!: () => void
  const commandReceived = new Promise<void>(resolve => { received = resolve })
  const peer = await fixture((frame, socket) => {
    if (frame.operation === 'open') reply(socket, opened)
    else { expect(frame.operation).toBe(operation); received() }
  })
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  let session: Awaited<ReturnType<typeof openTunHelperSession>> | undefined
  try {
    session = await openTunHelperSession(config, peer.path, { heartbeatMs: operation === 'heartbeat' ? 5 : 5000 })
    let outcome: Promise<string> | undefined
    if (operation === 'heartbeat') await vi.advanceTimersToNextTimerAsync()
    else outcome = session.stop().then(() => 'unexpected success', error => (error as Error).message)
    await commandReceived
    await vi.advanceTimersByTimeAsync(1999)
    expect(session.error()).toBeUndefined()
    await vi.advanceTimersByTimeAsync(1)
    expect(session.error()?.message).toBe('TUN session response timed out; network state unknown')
    if (outcome) expect(await outcome).toBe('TUN session response timed out; network state unknown')
  } finally { session?.disconnect(); vi.useRealTimers(); await peer.dispose() }
})

test.skipIf(process.platform === 'win32')('a heartbeat lease expires independently of a longer reply timeout', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  const frames: Record<string, unknown>[] = []
  const peer = await fixture((frame, socket) => {
    frames.push(frame)
    if (frame.operation === 'open') reply(socket, opened)
  })
  try {
    const session = await openTunHelperSession(config, peer.path, { timeoutMs: 30000 })
    await vi.advanceTimersByTimeAsync(15001)
    expect(session.error()?.message).toContain('lease expired')
    await expect(session.stop()).rejects.toThrow('lease expired')
    expect(frames.filter(frame => frame.operation === 'heartbeat').length).toBeLessThanOrEqual(1)
  } finally { vi.useRealTimers(); await peer.dispose() }
})

test.skipIf(process.platform === 'win32')('stop rejects a replayed acknowledgement and waits for proof of off', async () => {
  const peer = await fixture((frame, socket) => {
    if (frame.operation === 'open') reply(socket, opened)
    else reply(socket, { version: 2, ok: true, sequence: 0, status: off })
  })
  onTestFinished(peer.dispose)
  const session = await openTunHelperSession(config, peer.path)
  await expect(session.stop()).rejects.toThrow('sequence')
  expect(session.error()?.message).toContain('sequence')
})

test('concurrent mutation cannot create a second session', async () => {
  let resolve!: (value: TunStatus) => void
  const request = vi.fn(() => new Promise<TunStatus>(done => { resolve = done }))
  const open = vi.fn()
  const tun = createMacosTun({ endpointPresent: async () => true, request, open })
  const starting = tun.start(config)
  await Promise.resolve()
  await expect(tun.start(config)).rejects.toThrow('in progress')
  resolve({ availability: 'blocked', state: 'off', error: 'native gate closed' })
  await expect(starting).rejects.toThrow('native gate closed')
  expect(open).not.toHaveBeenCalled()
})

test('recovery of a disconnected session invokes native recovery and independently confirms cleanup', async () => {
  const unknown: TunStatus = { availability: 'blocked', state: 'unknown', error: 'lease lost; journal retained' }
  let failure: Error | undefined
  const owner = { stop: vi.fn(async () => { throw new Error('closed') }), error: () => failure,
    disconnect: () => { failure = new Error('closed') } }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on)
    .mockResolvedValueOnce(unknown).mockResolvedValueOnce(off).mockResolvedValueOnce(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  owner.disconnect()
  expect(await tun.recover()).toEqual(off)
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status', 'recover', 'status'])
})

test('a stale inspect result cannot disconnect a session opened after the inspection began', async () => {
  let readback!: (value: TunStatus) => void
  const owner = { stop: vi.fn(async () => off), error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockImplementationOnce(() => new Promise<TunStatus>(resolve => { readback = resolve }))
    .mockResolvedValueOnce(off).mockResolvedValueOnce(on)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  const reading = tun.inspect()
  await Promise.resolve()
  await tun.start(config)
  readback(off)
  expect(await reading).toEqual(off)
  expect(owner.disconnect).not.toHaveBeenCalled()
})

test('disappearing installation footprints cannot turn a locally owned session into not-installed/off', async () => {
  let installed = true
  const owner = { stop: vi.fn(async () => off), error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on)
  const tun = createMacosTun({ endpointPresent: async () => installed, request, open: async () => owner })
  await tun.start(config)
  installed = false
  expect(await tun.inspect()).toEqual({ availability: 'blocked', state: 'unknown', error: 'TUN helper disappeared; network state unknown' })
  expect(owner.disconnect).not.toHaveBeenCalled()
})

test('concurrent inspect cannot invalidate the captured owner while stop awaits its acknowledgement', async () => {
  let release!: (status: TunStatus) => void
  let entered!: () => void
  const stopping = new Promise<void>(resolve => { entered = resolve })
  const owner = { stop: () => { entered(); return new Promise<TunStatus>(resolve => { release = resolve }) },
    error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on).mockResolvedValue(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  const pending = tun.stop()
  await stopping
  expect(await tun.inspect()).toEqual(off)
  release(off)
  expect(await pending).toEqual(off)
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status', 'status'])
})

test('a concurrent proven-off inspection invalidates pending start without losing its captured owner', async () => {
  let release!: (status: TunStatus) => void
  let entered!: () => void
  const reading = new Promise<void>(resolve => { entered = resolve })
  const owner = { stop: vi.fn(async () => off), error: () => undefined, disconnect: vi.fn() }
  const request = vi.fn().mockResolvedValueOnce(off)
    .mockImplementationOnce(() => { entered(); return new Promise<TunStatus>(resolve => { release = resolve }) })
    .mockResolvedValue(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  const pending = tun.start(config)
  await reading
  expect(await tun.inspect()).toEqual(off)
  release(on)
  await expect(pending).rejects.toThrow('state confirmation failed')
  expect(owner.disconnect).toHaveBeenCalledTimes(2)
})

// Real V2 socket failure must flow through adapter subscription and the store queue.
// Only the helper's status reply is injected; no native service/Core is started.
test.skipIf(process.platform === 'win32').each([on, off])('live socket disconnect reconciles %j to the store without another Command or automatic recovery', async readback => {
  let peer: Socket | undefined
  let current = off
  const { path, dispose } = await fixture((frame, socket) => {
    if (frame.operation === 'open') { peer = socket; current = on; socket.write(`${JSON.stringify(opened)}\n`) }
  })
  onTestFinished(dispose)
  const request = vi.fn(async (_operation: string) => current)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: value => openTunHelperSession(value, path) })
  const platform = Object.assign(new FakePlatform(), { tun })
  const snapshot = fakeSnapshot()
  platform.files.set('settings.json', JSON.stringify({ settings: snapshot.settings, profiles: snapshot.profiles, activeProfileId: 'p1' }))
  platform.coreRunning = true
  const start = vi.spyOn(platform, 'startCore')
  const transport = new FakeTransport().on('GET', '/proxies', { status: 200, body: { proxies: {} } })
  const app = await createAppStore({ platform, client: createMihomoClient(transport), systemLocale: () => 'en',
    buildRuntimeConfig: () => 'proxies: []', buildTunConfig: () => config, refreshProfile: async value => value })
  onTestFinished(() => app.dispose())
  expect((await app.run('setTun', { enabled: true })).ok).toBe(true)
  expect(app.store.getState().tun.state).toBe('on')
  request.mockClear()
  current = readback
  peer!.destroy()
  if (readback.state === 'off') await vi.waitFor(() => { expect(app.store.getState().tun).toEqual(off); expect(app.store.getState().core.status).toBe('stopped') })
  else await vi.waitFor(() => expect(app.store.getState().tun).toMatchObject({ availability: 'blocked', state: 'unknown', error: expect.stringContaining('disconnected') }))
  expect(request.mock.calls.flat()).toEqual(['status'])
  expect(start).not.toHaveBeenCalled()
  expect((await app.run('setSystemProxy', { enabled: true })).ok).toBe(false)
})

test.skipIf(process.platform === 'win32')('session failure subscription notifies once and honors unsubscribe', async () => {
  let peer: Socket | undefined
  const { path, dispose } = await fixture((frame, socket) => { if (frame.operation === 'open') { peer = socket; socket.write(`${JSON.stringify(opened)}\n`) } })
  onTestFinished(dispose)
  const owner = await openTunHelperSession(config, path)
  const live = vi.fn(), removed = vi.fn()
  owner.subscribe!(live)
  owner.subscribe!(removed)()
  peer!.destroy()
  await vi.waitFor(() => expect(live).toHaveBeenCalledOnce())
  owner.disconnect()
  expect(live).toHaveBeenCalledOnce()
  expect(removed).not.toHaveBeenCalled()
})

// Startup must exercise the adapter recovery protocol even when fresh status proves off.
test.each(['ready', 'denied', 'checkpoint', 'unknown'] as const)('store startup reconciles fresh blocked/off through actual adapter (%s)', async outcome => {
  const initial: TunStatus = { availability: 'blocked', state: 'off', error: 'authenticated recovery is required before a new TUN session' }
  let current = initial
  const request = vi.fn(async (operation: string) => {
    if (operation === 'recover') {
      if (outcome === 'denied') throw new Error('installed manifest does not explicitly permit finite TUN sessions')
      current = outcome === 'ready' ? off : outcome === 'checkpoint'
        ? { availability: 'blocked', state: 'off', error: 'uninstall checkpoint failed' }
        : { availability: 'blocked', state: 'unknown', error: 'unknown route evidence retained' }
    }
    return current
  })
  const open = vi.fn()
  const tun = createMacosTun({ endpointPresent: async () => true, request, open })
  const platform = Object.assign(new FakePlatform(), { tun })
  const start = vi.spyOn(platform, 'startCore'), proxy = vi.spyOn(platform, 'setSystemProxy')
  const app = await createAppStore({ platform, client: createMihomoClient(new FakeTransport()), systemLocale: () => 'en',
    buildRuntimeConfig: () => 'proxies: []', refreshProfile: async value => value })
  onTestFinished(() => app.dispose())
  expect(request.mock.calls.flat()).toContain('recover')
  expect(request.mock.calls.flat().filter(value => value === 'recover')).toHaveLength(1)
  expect(app.store.getState().tun).toEqual(outcome === 'denied'
    ? { ...initial, error: 'installed manifest does not explicitly permit finite TUN sessions' } : current)
  if (outcome !== 'ready') expect(app.store.getState().tun.availability).toBe('blocked')
  expect(start).not.toHaveBeenCalled(); expect(proxy).not.toHaveBeenCalled(); expect(open).not.toHaveBeenCalled()
})

test('explicit recovery of an owned but blocked/off session preserves native checkpoint error', async () => {
  const blocked: TunStatus = { availability: 'blocked', state: 'off', error: 'uninstall checkpoint failed' }
  const request = vi.fn().mockResolvedValueOnce(off).mockResolvedValueOnce(on)
    .mockResolvedValue(blocked)
  const owner = { stop: vi.fn(async () => blocked), error: () => undefined, disconnect: vi.fn() }
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  expect(await tun.recover()).toEqual(blocked)
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status', 'recover', 'status'])
})


test('owned recovery returns independently proven ready/off while the successful stop worker is still finalizing', async () => {
  let finalizing = false
  const request = vi.fn(async (operation: string) => {
    if (operation === 'recover') throw new Error('session transaction active or shutting down; recovery refused')
    return finalizing ? off : on
  })
  const owner = { stop: vi.fn(async () => { finalizing = true; return off }), error: () => undefined, disconnect: vi.fn() }
  request.mockResolvedValueOnce(off)
  const tun = createMacosTun({ endpointPresent: async () => true, request, open: async () => owner })
  await tun.start(config)
  expect(await tun.recover()).toEqual(off)
  expect(finalizing).toBe(true)
  expect(request.mock.calls.flat()).toEqual(['status', 'status', 'status'])
})


test('rejected recovery reason survives unchanged pending status but never overrides changed native evidence', async () => {
  const initial: TunStatus = { availability: 'blocked', state: 'off', error: 'authenticated recovery is required' }
  let current = initial, denied = true
  const tun = createMacosTun({ endpointPresent: async () => true, request: async operation => {
    if (operation === 'recover' && denied) throw new Error('installed manifest does not permit finite sessions')
    return current
  } })
  await expect(tun.recover()).rejects.toThrow('installed manifest')
  expect(await tun.inspect()).toMatchObject({ ...initial, error: expect.stringContaining('installed manifest') })
  current = { availability: 'blocked', state: 'off', error: 'uninstall checkpoint failed' }
  expect(await tun.inspect()).toEqual(current)
  await expect(tun.recover()).rejects.toThrow('installed manifest')
  expect((await tun.inspect()).error).toContain('uninstall checkpoint failed')
  denied = false
  expect(await tun.recover()).toEqual(current)
  expect(await tun.inspect()).toEqual(current)
  current = off
  expect(await tun.inspect()).toEqual(off)
})
