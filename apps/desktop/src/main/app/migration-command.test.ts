import { createHash } from 'node:crypto'
import { lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, relative, sep } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import type { BootEvidence } from '../platform/migration-boot'
import type { PreparedMigrationReceipt } from '../platform/migration-preparation'
import { parseMigrationCommand, runMigrationCommand, type MigrationCommandOptions } from './migration-command'

const roots: string[] = []
const endpoint = '--expected-server=127.0.0.1:7890'
const backupArg = `--backup-directory=${join(tmpdir(), 'outside-backup')}`
const checkArgs = ['--proxy-migration=check', '--confirm-controlled-restart']
const hash = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')
beforeEach(() => { vi.spyOn(Date, 'now').mockReturnValue(Date.parse('2026-11-03T00:00:00Z')) })
afterEach(async () => {
  vi.restoreAllMocks()
  for (const root of roots.splice(0)) {
    if (!isAbsolute(root) || !root.startsWith(join(await realpath(tmpdir()), 'kuro-migration-command-')))
      throw new Error('Unsafe test cleanup path')
    await rm(root, { recursive: true, force: true })
  }
})

test('parser accepts explicit commands, repeated distinct endpoints, and full argv', () => {
  expect(parseMigrationCommand(['electron', 'app', '--proxy-migration=prepare', backupArg, endpoint,
    '--expected-server=127.0.0.1:7891'])).toEqual({ command: 'prepare',
    backupDirectory: join(tmpdir(), 'outside-backup'), endpoints: ['127.0.0.1:7890', '127.0.0.1:7891'] })
  expect(parseMigrationCommand(checkArgs)).toEqual({ command: 'check' })
  expect(parseMigrationCommand(['electron', 'app', '--unrelated'])).toBeNull()
})

test.each([
  ['--proxy-migration'], ['--proxy-migration', 'prepare'], ['--proxy-migration='], ['--proxy-migration=resident'],
  ['--proxy-migration-check'], ['--proxy-migration=check'], ['--confirm-controlled-restart'], [backupArg], [endpoint],
  ['--proxy-migration=prepare', endpoint], ['--proxy-migration=prepare', backupArg],
  ['--proxy-migration=prepare', '--backup-directory=relative', endpoint],
  ['--proxy-migration=prepare', '--backup-directory=\\\\server\\share\\backup', endpoint],
  ['--proxy-migration=prepare', '--backup-directory=//server/share/backup', endpoint],
  ['--proxy-migration=prepare', backupArg, '--expected-server=localhost:7890'],
  ['--proxy-migration=prepare', backupArg, '--expected-server=127.0.0.1:0'],
  ['--proxy-migration=prepare', backupArg, '--expected-server=127.0.0.1:65536'],
  ['--proxy-migration=prepare', backupArg, '--expected-server=127.0.0.1:07890'],
  ['--proxy-migration=prepare', backupArg, '--expected-server=127.0.0.1:7890\n'],
  ['--proxy-migration=prepare', backupArg, endpoint, endpoint],
  ['--proxy-migration=prepare', backupArg, backupArg, endpoint],
  ['--proxy-migration=prepare', backupArg, endpoint, '--confirm-controlled-restart'],
  [...checkArgs, '--proxy-migration=check'], [...checkArgs, '--proxy-migration=prepare'],
  [...checkArgs, '--confirm-controlled-restart'], [...checkArgs, '--confirm-controlled-restart=true'],
  [...checkArgs, backupArg], [...checkArgs, endpoint], [...checkArgs, '--unknown'],
  [...checkArgs, '--proxy-migration-allow-pid=123'], [...checkArgs, 'extra'],
  [...checkArgs, '--experimental-resident'], ['--experimental-resident=true'],
  ['--proxy-migration=prepare', backupArg, ...Array.from({ length: 9 }, (_, i) => `--expected-server=127.0.0.1:${7890 + i}`)],
].map(args => ({ args })))('parser rejects malformed, duplicate, unknown, or conflicting migration arguments: $args', ({ args }) => {
  expect(() => parseMigrationCommand(args)).toThrow()
})

function evidence(index: number, checkpoint?: number): BootEvidence {
  return { version: 2, userSid: 'S-1-5-21-1-2-3-1001', machineGuidSha256: 'e'.repeat(64),
    uptimeMs: String([30000, 80000, 100000][index - 1]), collectedAt: `2026-11-02T00:00:0${index}Z`,
    lastBootUpTime: '2026-11-01T00:00:00Z',
    newest: { record: index === 3 ? 105 : 100, digest: (index === 3 ? 'f' : 'a').repeat(64), fields: {} },
    kernel: { record: 80, digest: 'b'.repeat(64), fields: { StartTime: '2026-11-01T00:00:02Z' } },
    boot: { record: 79, digest: 'c'.repeat(64), fields: { BootType: '0' } },
    checkpoint: checkpoint === undefined ? null : { record: checkpoint, digest: 'a'.repeat(64), fields: {} },
    legacyRunOnce: null, nativeRunOnce: null, knownWriters: [{ pid: process.pid, name: 'Clash Kuro' }] }
}

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-migration-command-')))
  roots.push(root)
  const dataDir = join(root, 'data'), installationRoot = join(root, 'installed'), repoRoot = join(root, 'repo')
  for (const path of [dataDir, installationRoot, repoRoot]) await mkdir(path)
  const helperPath = join(installationRoot, 'kuro-sysproxy.exe'), backupDirectory = join(root, 'backup')
  const marker = join(dataDir, 'proxy-migration.json'), collectorPath = join(installationRoot, 'collector.ps1')
  await writeFile(helperPath, 'non-executable fixture bytes')
  const state = { cleared: false, restarted: false }
  const faults: { collect?: (value: BootEvidence) => void; exec?: string } = {}
  const collect = vi.fn(async (checkpoint?: number) => {
    const value = evidence(state.restarted ? 3 : collect.mock.calls.length, checkpoint)
    if (state.restarted) {
      value.uptimeMs = '60000'
      value.collectedAt = '2026-11-02T01:00:00Z'; value.lastBootUpTime = '2026-11-02T00:59:00Z'
      value.newest = { record: 130, digest: '9'.repeat(64), fields: {} }
      value.kernel = { record: 120, digest: 'd'.repeat(64), fields: { StartTime: '2026-11-02T00:59:02Z' } }
      value.boot = { record: 119, digest: '8'.repeat(64), fields: {} }
      value.checkpoint = { record: checkpoint!, digest: 'f'.repeat(64), fields: {} }
    }
    faults.collect?.(value)
    return value
  })
  const inside = (path: string) => {
    const child = relative(root, path)
    if (!child || child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child))
      throw new Error('Fake command escaped private temp root')
  }
  const exec = vi.fn<NonNullable<MigrationCommandOptions['exec']>>(async (file, args) => {
    if (faults.exec === file) throw new Error('fake execution failure')
    if (file === 'powershell.exe' && args.includes('-File')) {
      expect(args).toEqual(['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', collectorPath,
        ...(state.restarted ? ['-CheckpointRecord', '105'] : [])])
      return { stdout: JSON.stringify(await collect(state.restarted ? 105 : undefined)), stderr: '' }
    }
    if (file === 'powershell.exe') {
      expect(args.slice(0, 3)).toEqual(['-NoProfile', '-NonInteractive', '-EncodedCommand'])
      const script = Buffer.from(args[3]!, 'base64').toString('utf16le')
      expect(script).toContain('MoveFileEx')
      const encoded = /FromBase64String\('([A-Za-z0-9+/=]+)'\)/.exec(script)![1]!
      const move = JSON.parse(Buffer.from(encoded, 'base64').toString()) as { source: string; destination: string; flags: number }
      inside(move.source); inside(move.destination)
      expect([8, 9]).toContain(move.flags)
      if (move.flags === 8) await expect(lstat(move.destination)).rejects.toMatchObject({ code: 'ENOENT' })
      else expect(move.destination).toBe(marker)
      await rename(move.source, move.destination)
      return { stdout: '', stderr: '' }
    }
    expect(JSON.parse(await readFile(marker, 'utf8')).state).toBe('preparing')
    if (file === 'reg.exe') {
      expect(args.slice(0, 2)).toEqual(['export', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'])
      inside(args[2]!)
      const key = 'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
      await writeFile(args[2]!, Buffer.from(`\ufeffWindows Registry Editor Version 5.00\r\n\r\n[${key}]\r\n\r\n[${key}\\Connections]\r\n`, 'utf16le'))
      return { stdout: '', stderr: '' }
    }
    expect(file).toBe(helperPath)
    if (args[0] === 'get') {
      expect(args).toEqual(['get'])
      return { stdout: JSON.stringify({ ok: true, command: 'get', connections: [{ name: null,
        flags: state.cleared ? 1 : 3, proxyServer: '127.0.0.1:7890', bypass: null, autoConfigUrl: null }] }), stderr: '' }
    }
    expect(args).toEqual(['clear', '--expected-server', '127.0.0.1:7890'])
    state.cleared = true
    return { stdout: JSON.stringify({ ok: true, command: 'clear', runOnce: 'deleted',
      connections: [{ name: null, status: 'cleared' }] }), stderr: '' }
  })
  const options: MigrationCommandOptions = { args: ['--proxy-migration=prepare', `--backup-directory=${backupDirectory}`, endpoint],
    dataDir, helperPath, collectorPath, installationRoot, repoRoot, exec, collect }
  const prepare = () => runMigrationCommand(options)
  const check = () => {
    state.restarted = true
    return runMigrationCommand({ ...options, args: checkArgs })
  }
  const receipt = async () => JSON.parse(await readFile(marker, 'utf8')) as PreparedMigrationReceipt
  return { root, options, marker, backupDirectory, state, faults, exec, collect, prepare, check, receipt }
}

test('no command is not handled without touching disk or running anything', async () => {
  const exec = vi.fn(), collect = vi.fn()
  expect(await runMigrationCommand({ args: ['electron', 'app'], dataDir: 'missing', helperPath: 'missing',
    collectorPath: 'missing', installationRoot: 'missing', exec, collect })).toEqual({ handled: false })
  expect(exec).not.toHaveBeenCalled(); expect(collect).not.toHaveBeenCalled()
})

test.each(['installationRoot', 'repoRoot', 'dataDir'] as const)(
  'backup parent equal to or inside %s is rejected before a marker or command', async key => {
    const f = await fixture(), root = f.options[key]!
    await mkdir(join(root, 'nested'))
    for (const parent of [root, join(root, 'nested')]) {
      await expect(runMigrationCommand({ ...f.options,
        args: ['--proxy-migration=prepare', `--backup-directory=${join(parent, 'backup')}`, endpoint] })).rejects.toThrow(/outside/)
    }
    expect(f.exec).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
    await expect(lstat(f.marker)).rejects.toMatchObject({ code: 'ENOENT' })
  })

test.each(['installationRoot', 'repoRoot', 'dataDir', 'outside'] as const)(
  'backup parent aliases through %s are rejected, including junction ancestors', async key => {
    const f = await fixture(), target = key === 'outside' ? join(f.root, 'outside') : f.options[key]!
    if (key === 'outside') await mkdir(target)
    await mkdir(join(target, 'nested'))
    const alias = join(f.root, 'alias')
    await symlink(target, alias, process.platform === 'win32' ? 'junction' : 'dir')
    for (const parent of [alias, join(alias, 'nested')]) {
      await expect(runMigrationCommand({ ...f.options,
        args: ['--proxy-migration=prepare', `--backup-directory=${join(parent, 'backup')}`, endpoint] })).rejects.toThrow(/links or aliases/)
    }
    expect(f.exec).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
    await expect(lstat(f.marker)).rejects.toMatchObject({ code: 'ENOENT' })
  })

test('canonical installation sibling is allowed; preparation excludes only current PID and retains marker', async () => {
  const f = await fixture()
  const parent = `${f.options.installationRoot}-sibling`
  await mkdir(parent)
  const result = await runMigrationCommand({ ...f.options,
    args: ['--proxy-migration=prepare', `--backup-directory=${join(parent, 'backup')}`, endpoint] })
  expect(result).toMatchObject({ handled: true, command: 'prepare', residentEnabled: false })
  if (result.handled) expect(result.message).toContain('Resident NOT enabled')
  const receipt = await f.receipt()
  expect(receipt.after.knownWriters).toEqual([])
  expect(receipt.before.knownWriters).toEqual([])
  expect(f.collect.mock.results.length).toBe(3)
  expect((await f.collect.mock.results[0]!.value).knownWriters).toEqual([{ pid: process.pid, name: 'Clash Kuro' }])
  expect(f.exec.mock.calls.some(([file, args]) => file === f.options.helperPath && args[0] === 'clear')).toBe(true)
})

test.each(['Clash Kuro', 'kuro-sysproxy', 'mihomo', 'a'.repeat(64)])(
  'another writer named %s blocks preparation and preserves the preparing marker', async name => {
    const f = await fixture()
    f.faults.collect = value => { value.knownWriters.push({ pid: process.pid + 1, name }) }
    await expect(f.prepare()).rejects.toThrow('Known proxy writer')
    expect(JSON.parse(await readFile(f.marker, 'utf8')).state).toBe('preparing')
    expect(f.exec.mock.calls).toHaveLength(1)
    expect(f.exec.mock.calls[0]![0]).toBe('powershell.exe')
    expect(f.state.cleared).toBe(false)
  })

test('existing marker is preserved without collection or execution', async () => {
  const f = await fixture(), original = '{"state":"preparing","retain":"evidence"}'
  await writeFile(f.marker, original)
  await expect(f.prepare()).rejects.toThrow('already exists')
  expect(await readFile(f.marker, 'utf8')).toBe(original)
  expect(f.exec).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
})

test('preparation failure leaves its marker and backup without automatic restoration', async () => {
  const f = await fixture()
  f.faults.exec = 'reg.exe'
  await expect(f.prepare()).rejects.toThrow('fake execution failure')
  expect(JSON.parse(await readFile(f.marker, 'utf8')).state).toBe('preparing')
  expect(await readFile(join(f.backupDirectory, 'current-helper.exe'), 'utf8')).toBe('non-executable fixture bytes')
  expect(f.exec.mock.calls.filter(([file]) => file === f.options.helperPath).map(([, args]) => args)).toEqual([['get']])
  expect(f.exec.mock.calls.some(([file, args]) => file === 'reg.exe' && args[0] === 'import')).toBe(false)
  expect(f.state.cleared).toBe(false)
})

test('failure after clear retains evidence and does not replay or restore proxy settings', async () => {
  const f = await fixture()
  f.faults.collect = value => {
    if (f.state.cleared) value.nativeRunOnce = 'unexpected registration'
  }
  await expect(f.prepare()).rejects.toThrow('Native recovery registration')
  expect(f.state.cleared).toBe(true)
  expect(JSON.parse(await readFile(f.marker, 'utf8')).state).toBe('preparing')
  expect(JSON.parse(await readFile(join(f.backupDirectory, 'after-get.json'), 'utf8')).connections[0].flags).toBe(1)
  expect(f.exec.mock.calls.filter(([file]) => file === f.options.helperPath).map(([, args]) => args))
    .toEqual([['get'], ['get'], ['clear', '--expected-server', '127.0.0.1:7890'], ['get']])
  expect(f.exec.mock.calls.filter(([file]) => file === 'reg.exe').map(([, args]) => args[0])).toEqual(['export'])
})

test('check rehashes receipt and uses after checkpoint; success remains read-only and prerequisites-only', async () => {
  const f = await fixture()
  await f.prepare()
  const marker = await readFile(f.marker), receipt = await f.receipt()
  const manifest = await readFile(join(receipt.backupDirectory, 'manifest.json'))
  f.exec.mockClear(); f.collect.mockClear()
  expect(receipt.before.uptimeMs).toBe('30000')
  expect(receipt.after.uptimeMs).toBe('100000')
  const result = await f.check()
  expect(result).toMatchObject({ handled: true, command: 'check', residentEnabled: false })
  if (result.handled) {
    expect(result.message).toContain('prerequisites-only')
    expect(result.message).toContain('Resident NOT enabled')
    expect(result.message).toContain('exclusive native ownership/replay still required')
    expect(result.message).toContain('not full positive admission')
  }
  expect(f.collect).toHaveBeenCalledExactlyOnceWith(105)
  expect(f.exec).not.toHaveBeenCalled()
  expect(await readFile(f.marker)).toEqual(marker)
  expect(await readFile(join(receipt.backupDirectory, 'manifest.json'))).toEqual(manifest)
  f.collect.mockClear()
  await expect(f.check()).resolves.toMatchObject({ handled: true, residentEnabled: false })
  expect(f.exec).not.toHaveBeenCalled()
})

test('default collection uses injected exec for read-only collector and excludes current PID', async () => {
  const f = await fixture()
  await f.prepare()
  f.state.restarted = true
  f.exec.mockClear(); f.collect.mockClear()
  expect(await runMigrationCommand({ ...f.options, args: checkArgs, collect: undefined }))
    .toMatchObject({ handled: true, command: 'check', residentEnabled: false })
  expect(f.exec).toHaveBeenCalledExactlyOnceWith('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', f.options.collectorPath, '-CheckpointRecord', '105'])
})

test.each(['helper', 'manifest', 'backup', 'marker'])(
  'tampered %s fails check before collection and preserves marker without execution', async target => {
    const f = await fixture()
    await f.prepare()
    const path = target === 'helper' ? f.options.helperPath : target === 'manifest' ? join(f.backupDirectory, 'manifest.json')
      : target === 'backup' ? join(f.backupDirectory, 'after-get.json') : f.marker
    await writeFile(path, 'corrupt evidence')
    const marker = await readFile(f.marker)
    f.exec.mockClear(); f.collect.mockClear()
    await expect(f.check()).rejects.toThrow()
    expect(f.exec).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
    expect(await readFile(f.marker)).toEqual(marker)
  })

test.each(['legacy', 'native', 'other-app', 'other-helper', 'other-hash', 'uptime', 'checkpoint', 'identity'])(
  'check rejects %s evidence without writes, execution, or marker removal', async fault => {
    const f = await fixture()
    await f.prepare()
    f.faults.collect = value => {
      if (fault === 'legacy') value.legacyRunOnce = 'registered'
      else if (fault === 'native') value.nativeRunOnce = 'registered'
      else if (fault.startsWith('other-')) value.knownWriters.push({ pid: process.pid + 1,
        name: fault === 'other-app' ? 'Clash Kuro' : fault === 'other-helper' ? 'kuro-sysproxy' : 'a'.repeat(64) })
      else if (fault === 'uptime') value.uptimeMs = '100000'
      else if (fault === 'checkpoint') value.checkpoint!.digest = '0'.repeat(64)
      else value.machineGuidSha256 = '0'.repeat(64)
    }
    const marker = await readFile(f.marker)
    f.exec.mockClear(); f.collect.mockClear()
    await expect(f.check()).rejects.toThrow()
    expect(f.exec).not.toHaveBeenCalled()
    expect(await readFile(f.marker)).toEqual(marker)
  })

test('injected collection is validated before current PID filtering', async () => {
  const f = await fixture()
  await f.prepare()
  f.faults.collect = value => { value.knownWriters[0]!.name = '' }
  f.exec.mockClear()
  await expect(f.check()).rejects.toThrow('Invalid writer inventory')
  expect(f.exec).not.toHaveBeenCalled()
})

test('collector failure during check preserves marker and backups without recovery execution', async () => {
  const f = await fixture()
  await f.prepare()
  const marker = await readFile(f.marker), manifest = await readFile(join(f.backupDirectory, 'manifest.json'))
  f.faults.collect = () => { throw new Error('collector unavailable') }
  f.exec.mockClear()
  await expect(f.check()).rejects.toThrow('collector unavailable')
  expect(f.exec).not.toHaveBeenCalled()
  expect(await readFile(f.marker)).toEqual(marker)
  expect(await readFile(join(f.backupDirectory, 'manifest.json'))).toEqual(manifest)
})

test.each(['helper', 'marker', 'backup'])('check rehashes %s after the slow collector returns', async target => {
  const f = await fixture()
  await f.prepare()
  f.state.restarted = true
  f.exec.mockClear()
  const collect = async (checkpoint?: number) => {
    const value = await f.collect(checkpoint)
    await writeFile(target === 'helper' ? f.options.helperPath : target === 'marker' ? f.marker
      : join(f.backupDirectory, 'before-get.json'), 'changed during collection')
    return value
  }
  await expect(runMigrationCommand({ ...f.options, args: checkArgs, collect })).rejects.toThrow()
  expect(f.exec).not.toHaveBeenCalled()
})

test('malformed arguments never trigger collection or helper execution', async () => {
  const f = await fixture()
  await expect(runMigrationCommand({ ...f.options, args: ['--proxy-migration=check'] })).rejects.toThrow('confirm-controlled-restart')
  expect(f.exec).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
  await expect(lstat(f.marker)).rejects.toMatchObject({ code: 'ENOENT' })
})

test('check also rejects a prepared after sample with a registration even when its manifest binding is consistent', async () => {
  const f = await fixture()
  await f.prepare()
  const receipt = await f.receipt(), manifestPath = join(f.backupDirectory, 'manifest.json')
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
  receipt.after.nativeRunOnce = 'registered'; manifest.after = receipt.after
  const bytes = JSON.stringify(manifest)
  await writeFile(manifestPath, bytes)
  receipt.backupDigest = hash(bytes)
  await writeFile(f.marker, JSON.stringify(receipt))
  const marker = await readFile(f.marker)
  f.exec.mockClear()
  await expect(f.check()).rejects.toThrow('Native recovery registration')
  expect(f.exec).not.toHaveBeenCalled()
  expect(await readFile(f.marker)).toEqual(marker)
})
