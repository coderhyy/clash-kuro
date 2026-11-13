import { createServer } from 'node:net'
import { createSocket } from 'node:dgram'
import { promisify } from 'node:util'
import { afterEach, beforeAll, expect, test, vi } from 'vitest'
import { reserveTestPort } from './test-ports'

afterEach(() => {
  vi.doUnmock('node:child_process')
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  vi.resetModules()
})

async function mockInventory(read: (...args: unknown[]) => Promise<{ stdout: string; stderr: string }>) {
  vi.resetModules()
  vi.stubGlobal('process', Object.create(process, { platform: { value: 'win32' } }))
  vi.doMock('node:child_process', () => ({ execFile: Object.assign(vi.fn(), { [promisify.custom]: read }) }))
  return (await import('./test-ports')).reserveTestPort
}

beforeAll(async () => {
  const reservation = await reserveTestPort()
  await reservation.release()
})

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

test('Windows inventory serializes and caches all four reads and excludes every OS range', async () => {
  const diagnostic = vi.spyOn(process.stderr, 'write').mockReturnValue(true)
  let active = 0, maximumActive = 0
  const read = vi.fn(async (...[, args]: unknown[]) => {
    maximumActive = Math.max(maximumActive, ++active)
    await Promise.resolve()
    active--
    const command = (args as string[]).join(' ')
    const stdout = command.includes('excludedportrange')
      ? command.includes('protocol=tcp') ? ' 1024 29999 *\n' : ' 30000 39999\n'
      : command.includes('protocol=tcp') ? ' Start Port : 40000\n Number of Ports : 5000\n' : ' Start Port : 45000\n Number of Ports : 4152\n'
    return { stdout, stderr: '非ASCII diagnostic' }
  })
  const reserve = await mockInventory(read)
  await expect(reserve()).rejects.toThrow('No isolated TCP/UDP test port available: []')
  await expect(reserve()).rejects.toThrow('No isolated TCP/UDP test port available: []')
  expect(maximumActive).toBe(1)
  const events = diagnostic.mock.calls.map(([line]) => JSON.parse(String(line).replace('[test-port-inventory] ', '')))
  expect(events).toHaveLength(8)
  expect(events.map(event => [event.ordinal, event.event])).toEqual([1, 2, 3, 4].flatMap(ordinal => [[ordinal, 'started'], [ordinal, 'passed']]))
  for (let index = 0; index < events.length; index += 2) {
    const start = events[index], end = events[index + 1]
    expect(start).toMatchObject({ suite: 'src/main/platform/test-ports.test.ts', workerPID: process.pid, workerID: process.env.VITEST_WORKER_ID ?? null, poolID: process.env.VITEST_POOL_ID ?? null, endTime: null, elapsedMs: 0, stdoutBytes: null, stderrBytes: null, outputBytes: null, timeoutMs: 5000 })
    expect(end).toMatchObject({ ...start, event: 'passed', endTime: expect.any(String), elapsedMs: expect.any(Number), stdoutBytes: expect.any(Number), stderrBytes: Buffer.byteLength('非ASCII diagnostic'), outputBytes: expect.any(Number) })
    expect(Date.parse(end.endTime)).toBeGreaterThanOrEqual(Date.parse(start.startTime))
    expect(end.elapsedMs).toBeGreaterThanOrEqual(0)
    expect(end.outputBytes).toBe(end.stdoutBytes + end.stderrBytes)
  }
  expect(events[1].stdoutBytes).toBe(Buffer.byteLength(' 1024 29999 *\n'))
  expect(JSON.stringify(events)).not.toContain('非ASCII diagnostic')
  expect(JSON.stringify(events)).not.toContain('1024 29999')
  expect(read.mock.calls).toEqual(['tcp', 'udp'].flatMap(protocol => ['excludedportrange', 'dynamicport'].map(kind => [
    'netsh.exe', ['int', 'ipv4', 'show', kind, `protocol=${protocol}`],
    { windowsHide: true, timeout: 5000, maxBuffer: 128 * 1024 },
  ])))
})

test.each([
  { code: null, signal: 'SIGTERM', killed: true },
  { code: 1, signal: null, killed: false },
  { code: 'ENOENT', signal: undefined, killed: undefined },
])('Windows inventory failure reports child diagnostics: %j', async ({ code, signal, killed }) => {
  const diagnostic = vi.spyOn(process.stderr, 'write').mockReturnValue(true)
  const failure = Object.assign(new Error('Command failed: netsh.exe\nnetsh diagnostic'), { code, signal, killed, stdout: '表\n', stderr: 'private-command-output' })
  const read = vi.fn(async () => { throw failure })
  const reserve = await mockInventory(read)
  const clock = vi.spyOn(performance, 'now').mockReturnValueOnce(100).mockReturnValueOnce(5107)
  const error = await reserve().catch(error => error)
  clock.mockRestore()
  expect(error).toBeInstanceOf(Error)
  expect(error.message).toContain('netsh.exe int ipv4 show excludedportrange protocol=tcp')
  expect(error.message).toContain(`code=${code ?? 'null'}, signal=${signal ?? 'null'}, killed=${killed ?? 'unknown'}, elapsedMs=5007, timeoutMs=5000`)
  expect(error.message).toContain(failure.message)
  expect(error.cause).toBe(failure)
  await expect(reserve()).rejects.toBe(error)
  expect(read).toHaveBeenCalledOnce()
  const events = diagnostic.mock.calls.map(([line]) => JSON.parse(String(line).replace('[test-port-inventory] ', '')))
  expect(events).toHaveLength(2)
  expect(events[0]).toMatchObject({ event: 'started', ordinal: 1, protocol: 'tcp', kind: 'excludedportrange', outputBytes: null })
  expect(events[1]).toMatchObject({ event: 'failed', ordinal: 1, elapsedMs: 5007, stdoutBytes: Buffer.byteLength('表\n'), stderrBytes: Buffer.byteLength('private-command-output'), outputBytes: Buffer.byteLength('表\nprivate-command-output'), code: code ?? null, signal: signal ?? null, killed: killed ?? null })
  expect(JSON.stringify(events)).not.toContain('private-command-output')
  expect(JSON.stringify(events)).not.toContain('表')
})
