import { once } from 'node:events'
import { join } from 'node:path'
import type { ChildProcess } from 'node:child_process'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { createTunDiagnosticWindow } from './tun-diagnostic-window'

const entrySHA = 'b7cf9d1700c6fd016a9ab6ba7de4cca23e9c0f732bf4777f1fcb0730c37d5f47'
const fake = vi.hoisted(() => ({ spawn: vi.fn(), readFile: vi.fn(), open: vi.fn(), lstat: vi.fn(), writeFile: vi.fn(), hash: vi.fn(), windowsPaths: false }))
// process.platform stubbing does not change node:path's host semantics.
vi.mock('node:path', async original => {
  const actual = await original<typeof import('node:path')>()
  return { ...actual, join: (...parts: string[]) => fake.windowsPaths ? actual.win32.join(...parts) : actual.join(...parts) }
})
vi.mock('node:child_process', async original => ({ ...await original<typeof import('node:child_process')>(), spawn: (...args: unknown[]) => fake.spawn(...args) }))
vi.mock('node:crypto', async original => ({ ...await original<typeof import('node:crypto')>(), createHash: (...args: unknown[]) => fake.hash(...args) }))
vi.mock('node:fs/promises', async original => ({ ...await original<typeof import('node:fs/promises')>(),
  readFile: (...args: unknown[]) => fake.readFile(...args), open: (...args: unknown[]) => fake.open(...args),
  lstat: (...args: unknown[]) => fake.lstat(...args), writeFile: (...args: unknown[]) => fake.writeFile(...args) }))

const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
const uid = Object.getOwnPropertyDescriptor(process, 'getuid')
let child: ChildProcess | undefined
let evidence = '', ready = false, script = ''
let marker: Record<string, unknown> | undefined
let markerStat: Record<string, unknown>
let writes: Map<string, Record<string, unknown>>
const missing = () => Object.assign(new Error('fixture evidence not yet created'), { code: 'ENOENT' })

beforeEach(async () => {
  vi.clearAllMocks()
  fake.windowsPaths = false
  Object.defineProperty(process, 'platform', { configurable: true, value: 'darwin' })
  Object.defineProperty(process, 'getuid', { configurable: true, value: () => 501 })
  evidence = ''; ready = false; marker = undefined; writes = new Map()
  script = "process.stdout.write('ARMED\\n');setInterval(()=>{},1000)"
  markerStat = { isFile: () => true, nlink: 1, uid: 501, mode: 0o600, size: 100 }
  fake.readFile.mockResolvedValue(Buffer.from('fixture entry bytes'))
  fake.hash.mockReturnValue({ update: () => ({ digest: () => entrySHA }) })
  fake.lstat.mockImplementation(async () => {
    if (!ready) throw missing()
    return { isDirectory: () => true, isSymbolicLink: () => false, uid: 501, mode: 0o700 }
  })
  fake.writeFile.mockImplementation(async (path: string, bytes: string, options: { flag: string }) => {
    expect(options.flag).toBe('wx')
    if (['cancel-requested.json', 'app-collector-exit.json'].some(name => path === join(evidence, name)) && !ready) throw missing()
    if (writes.has(path)) throw Object.assign(new Error('exclusive fixture output exists'), { code: 'EEXIST' })
    writes.set(path, JSON.parse(bytes))
  })
  fake.open.mockImplementation(async () => {
    if (!ready) throw missing()
    return { stat: async () => markerStat, readFile: async () => JSON.stringify(marker ?? { format: 1, prepared: true, evidence }), close: async () => {} }
  })
  // Only osascript is replaced. This is a real harmless local child; no root/network entry runs.
  const actual = await vi.importActual<typeof import('node:child_process')>('node:child_process')
  fake.spawn.mockImplementation(() => {
    child = actual.spawn(process.execPath, ['-e', script], { stdio: ['ignore', 'pipe', 'pipe'] })
    child.stdout!.on('data', bytes => { if (String(bytes).includes('ARMED')) ready = true })
    return child
  })
})
afterEach(async () => {
  if (child && child.exitCode === null && child.signalCode === null) {
    const closed = once(child, 'close'); child.kill('SIGTERM'); await closed
  }
  child = undefined
  Object.defineProperty(process, 'platform', platform)
  if (uid) Object.defineProperty(process, 'getuid', uid)
  else Reflect.deleteProperty(process, 'getuid')
  vi.restoreAllMocks()
})
function window() { const value = createTunDiagnosticWindow(); evidence = value.evidence; return value }
async function closedEvidence() { await vi.waitFor(() => expect(writes.has(join(evidence, 'app-collector-exit.json'))).toBe(true)); return writes.get(join(evidence, 'app-collector-exit.json'))! }

test.each(['host', 'win32'] as const)('fixed launcher is pinned and latest exact prepared marker allows one attempt (%s paths)', async paths => {
  fake.windowsPaths = paths === 'win32'
  const value = window()
  await value.prepare()
  expect(value.signal.aborted).toBe(false)
  const [file, args, options] = fake.spawn.mock.calls[0]!
  expect(file).toBe('/usr/bin/osascript')
  expect(args.at(-1)).toContain('/private/tmp/kuro-ipv4-local-native-result-acnhcyrv/paired.py')
  expect(args.at(-1)).toContain(entrySHA)
  expect(args.at(-1)).toContain(value.evidence)
  expect(options).toEqual({ stdio: ['ignore', 'pipe', 'pipe'] })
  expect(fake.readFile.mock.calls).toEqual([['/private/tmp/kuro-ipv4-local-native-result-acnhcyrv/paired.py']])
  await expect(value.prepare()).rejects.toThrow('already used')
  expect(fake.spawn).toHaveBeenCalledOnce()
  await value.cancel(new Error('fixture done'))
  expect(writes.get(join(evidence, 'cancel-requested.json'))).toMatchObject({ reason: 'fixture done', actualStop: false })
})

test('real child exit aborts synchronously before close retains evidence', async () => {
  const actual = await vi.importActual<typeof import('node:child_process')>('node:child_process')
  fake.spawn.mockImplementation(() => {
    child = actual.spawn(process.execPath, ['-e', "process.stdout.write('ARMED\\n');process.stdin.resume();process.stdin.once('end',()=>process.exit(7))"], { stdio: ['pipe', 'pipe', 'pipe'] })
    child.stdout!.on('data', bytes => { if (String(bytes).includes('ARMED')) ready = true })
    return child
  })
  const value = window()
  await value.prepare()
  let atExit: { aborted: boolean; reason: string | undefined; persisted: boolean } | undefined
  // Observe inside exit: awaiting exit may resume after close on some hosts.
  const exited = new Promise<void>(resolve => child!.once('exit', () => {
    atExit = { aborted: value.signal.aborted, reason: value.signal.reason?.message, persisted: writes.has(join(evidence, 'app-collector-exit.json')) }
    resolve()
  }))
  child!.stdin!.end()
  await exited
  expect(atExit).toEqual({ aborted: true, reason: expect.stringContaining('code=7'), persisted: false })
  const result = await closedEvidence()
  expect(result).toMatchObject({ code: 7, signal: null, actualStop: false })
})

test('real child output remains drained beyond retained prefix on both streams', async () => {
  script = "process.stdout.write('ARMED\\n');setTimeout(()=>{let n=2;const done=()=>{if(!--n)process.exit(0)};process.stdout.write('x'.repeat(1024*1024),done);process.stderr.write('y'.repeat(1024*1024),done)},100)"
  const value = window()
  await value.prepare()
  const result = await closedEvidence()
  expect(value.signal.aborted).toBe(true)
  expect(result.code).toBe(0)
  expect(result.stdout).toHaveLength(16384)
  expect(result.stderr).toHaveLength(16384)
})

test.each([
  { format: 1, prepared: false },
  { format: 1, prepared: true, extra: true },
  { format: 1, phase: 'prepared' },
])('rejects malformed marker %j and cancels without retry', async fields => {
  const value = window(); marker = { ...fields, evidence }
  await expect(value.prepare()).rejects.toThrow('identity mismatch')
  expect(value.signal.aborted).toBe(true)
  expect(writes.has(join(evidence, 'cancel-requested.json'))).toBe(true)
  await expect(value.prepare()).rejects.toThrow('already used')
  expect(fake.spawn).toHaveBeenCalledOnce()
})

test('unsafe marker metadata rejects before admission', async () => {
  const value = window(); markerStat.nlink = 2
  await expect(value.prepare()).rejects.toThrow('Unsafe')
  expect(value.signal.aborted).toBe(true)
})

test('changed fixed entry fails before child launch and aborts', async () => {
  fake.hash.mockReturnValue({ update: () => ({ digest: () => '0'.repeat(64) }) })
  const value = window()
  await expect(value.prepare()).rejects.toThrow('entry changed')
  expect(value.signal.aborted).toBe(true)
  expect(fake.spawn).not.toHaveBeenCalled()
})

test('preparation timeout before E terminates only the owned harmless wrapper', async () => {
  script = 'setInterval(()=>{},1000)'
  const now = Date.now()
  vi.spyOn(Date, 'now').mockReturnValueOnce(now).mockReturnValue(now + 180001)
  const value = window()
  await expect(value.prepare()).rejects.toThrow('timed out')
  expect(value.signal.aborted).toBe(true)
  expect(child).toBeDefined()
  await vi.waitFor(() => expect(child!.signalCode).toBe('SIGTERM'))
  await vi.waitFor(() => expect(writes.has(`${evidence}.launcher.json`)).toBe(true))
  expect([...writes.keys()]).toEqual([`${evidence}.launcher.json`])
  expect(value.signal.reason.message).toContain('timed out')
})

test('cancel after E is present preserves first cause and never signals wrapper', async () => {
  const value = window()
  await value.prepare()
  const kill = vi.spyOn(child!, 'kill')
  fake.lstat.mockRejectedValueOnce(missing()) // Successful preparation already observed E; its disappearance must not signal the root wrapper.
  await value.cancel(new Error('first collector failure'))
  fake.writeFile.mockRejectedValueOnce(missing()) // E was observed: a failed marker write must not kill a running root entry.
  await value.cancel(new Error('first collector failure'))
  await value.cancel(new Error('later cancellation'))
  expect(kill).not.toHaveBeenCalled()
  expect(value.signal.reason.message).toBe('first collector failure')
  expect(writes.get(join(evidence, 'cancel-requested.json'))?.reason).toBe('first collector failure')
})


test('preparation failure before E retains launcher exit and stderr without creating E', async () => {
  script = "process.stderr.write('fixture preparation rejected');process.exit(2)"
  const value = window()
  await expect(value.prepare()).rejects.toThrow('code=2')
  await vi.waitFor(() => expect(writes.has(`${evidence}.launcher.json`)).toBe(true))
  expect(value.signal.aborted).toBe(true)
  expect(writes.get(`${evidence}.launcher.json`)).toMatchObject({ code: 2, signal: null, stderr: 'fixture preparation rejected', actualStop: false })
  expect(ready).toBe(false)
  expect([...writes.keys()]).toEqual([`${evidence}.launcher.json`])
})


test('actual local spawn error aborts preparation before any marker can admit start', async () => {
  const actual = await vi.importActual<typeof import('node:child_process')>('node:child_process')
  fake.spawn.mockImplementation(() => { child = actual.spawn(process.execPath + '.missing-test-child', [], { stdio: ['ignore', 'pipe', 'pipe'] }); return child })
  const value = window()
  await expect(value.prepare()).rejects.toMatchObject({ code: 'ENOENT' })
  expect(value.signal.aborted).toBe(true)
  expect(value.signal.reason.code).toBe('ENOENT')
  await vi.waitFor(() => expect(writes.has(`${evidence}.launcher.json`)).toBe(true))
})
