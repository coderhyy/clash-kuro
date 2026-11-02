import { createHash } from 'node:crypto'
import { lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { basename, dirname, isAbsolute, join, relative, sep } from 'node:path'
import { afterEach, expect, test } from 'vitest'
import { guardMigrationStartup } from '../app/migration-startup'
import type { BootEvidence } from './migration-boot'
import { prepareProxyMigration, type MigrationPreparationOptions } from './migration-preparation'
import { readPreparedMigration } from './migration-receipt'
import { execCommand, type Exec } from './system-proxy'

const roots: string[] = []
afterEach(async () => {
  for (const root of roots.splice(0)) {
    if (!root.startsWith(join(await realpath(tmpdir()), 'kuro-preparation-'))) throw new Error('Unsafe test cleanup path')
    await rm(root, { recursive: true, force: true })
  }
})
const sha = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')
const key = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
const registryRoot = 'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
const registry = Buffer.from('\ufeffWindows Registry Editor Version 5.00\r\n\r\n' +
  `[${registryRoot}]\r\n"ProxyEnable"=dword:00000001\r\n\r\n` +
  `[${registryRoot}\\Connections]\r\n"DefaultConnectionSettings"=hex:01,02,03\r\n`, 'utf16le')
const initialConnections = [
  { name: null, flags: 3, proxyServer: 'http=127.0.0.1:7890;https=127.0.0.1:7890', bypass: null, autoConfigUrl: null },
  { name: 'Home VPN', flags: 15, proxyServer: '127.0.0.1:7891', bypass: '*.intranet', autoConfigUrl: 'https://example.invalid/proxy.pac' },
  { name: 'Corporate VPN', flags: 6, proxyServer: 'corp.proxy:8080', bypass: '<local>', autoConfigUrl: 'https://example.invalid/corp.pac' },
  { name: 'Idle VPN', flags: 8, proxyServer: '127.0.0.1:7890', bypass: '', autoConfigUrl: '' },
]

test.skipIf(process.platform !== 'win32')('actual native write-through publication stops before collection, registry or proxy operations', async () => {
  const f = await fixture()
  let moves = 0
  f.options.exec = async (file, args) => {
    expect(file).toBe(f.options.helperPath)
    expect(args[0]).toBe('publish-migration')
    moves++
    return execCommand(fileURLToPath(new URL('../../../resources/win/x64/kuro-sysproxy.exe', import.meta.url)), args)
  }
  f.options.collect = async () => { throw new Error('fixture stops before collection or proxy operations') }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('fixture stops before collection')
  expect(moves).toBe(1)
  expect(JSON.parse(await readFile(f.marker, 'utf8')).state).toBe('preparing')
  await expect(guardMigrationStartup(f.options.dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
}, 15_000)

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-preparation-')))
  roots.push(root)
  const dataDir = join(root, 'data'), currentDir = join(root, 'current'), oldDir = join(root, 'old')
  for (const dir of [dataDir, currentDir, oldDir]) await mkdir(dir)
  const helperPath = join(currentDir, 'kuro-sysproxy.exe'), legacyPath = join(oldDir, 'kuro-sysproxy.exe')
  const collectorPath = join(currentDir, 'collect-boot-evidence.ps1'), appPath = join(currentDir, 'app.asar')
  // Deliberately non-executable bytes: no test may launch either file.
  await writeFile(helperPath, 'current fake helper bytes')
  await writeFile(legacyPath, 'original fake helper bytes')
  await writeFile(collectorPath, 'non-executable fake collector bytes')
  await writeFile(appPath, 'non-executable fake packaged app bytes')
  const command = `"${legacyPath}" clear --expected-server 127.0.0.1:7890 --log "${join(root, 'old log.txt')}"`
  const backupDirectory = join(root, 'outside-backup'), marker = join(dataDir, 'proxy-migration.json')
  const calls: { file: string; args: string[] }[] = []
  const state = { gets: 0, collects: 0 }
  const faults: {
    registry?: 'throw' | 'corrupt' | 'missing-connections'
    publish?: string
    get?: (index: number, result: Record<string, unknown>) => string
    collect?: (index: number, evidence: BootEvidence) => void | Promise<void>
  } = {}
  const inside = (path: string) => {
    const child = relative(root, path)
    if (!child || child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child)) throw new Error('Fake Exec escaped private temp root')
  }
  const assertPreparing = async () => expect(JSON.parse(await readFile(marker, 'utf8')).state).toBe('preparing')
  const exec: Exec = async (file, args) => {
    calls.push({ file, args: [...args] })
    if (file === helperPath && args[0] === 'publish-migration') {
      expect(args.filter((_, index) => index % 2 === 1)).toEqual(['--source', '--destination', '--replace'])
      expect(['yes', 'no']).toContain(args[6])
      const move = { source: args[2]!, destination: args[4]!, flags: args[6] === 'yes' ? 9 : 8 }
      inside(move.source); inside(move.destination)
      expect([8, 9]).toContain(move.flags)
      if (faults.publish === basename(move.destination) &&
          (move.destination !== marker || move.flags === 9)) throw new Error('fake write-through failure')
      if (move.flags === 8) {
        try { await lstat(move.destination); throw new Error('fake destination already exists') }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
      } else {
        expect(move.destination).toBe(marker)
        await assertPreparing()
        expect(JSON.parse(await readFile(move.source, 'utf8')).state).toBe('prepared')
      }
      await rename(move.source, move.destination)
      return { stdout: JSON.stringify({ command: 'publish-migration', ok: true, errorCode: 0 }), stderr: '' }
    }
    await assertPreparing()
    if (file === 'reg.exe') {
      expect(args.slice(0, 2)).toEqual(['export', key])
      inside(args[2]!)
      if (faults.registry === 'throw') throw new Error('fake reg export failure')
      const bytes = faults.registry === 'corrupt' ? Buffer.from('corrupt') : faults.registry === 'missing-connections'
        ? Buffer.from(`\ufeffWindows Registry Editor Version 5.00\r\n\r\n[${registryRoot}]\r\n`, 'utf16le') : registry
      await writeFile(args[2]!, bytes, { flag: 'wx' })
      return { stdout: 'Export complete', stderr: '' }
    }
    expect(file).toBe(helperPath)
    if (args[0] === 'get') {
      expect(args).toEqual(['get'])
      state.gets++
      const rows = structuredClone(initialConnections)
      const result = { command: 'get', ok: true, connections: rows }
      return { stdout: faults.get?.(state.gets, result) ?? JSON.stringify(result), stderr: '' }
    }
    throw new Error(`Unexpected helper command: ${args[0]}`)
  }
  const collect = async (checkpoint?: number): Promise<BootEvidence> => {
    await assertPreparing()
    const index = ++state.collects
    if (index === 3) expect(state.gets).toBe(3)
    const evidence: BootEvidence = {
      version: 2, userSid: 'S-1-5-21-1-2-3-1001', machineGuidSha256: 'e'.repeat(64), uptimeMs: String(86400000 + index * 1000),
      collectedAt: `2026-11-02T00:00:0${index}Z`,
      lastBootUpTime: '2026-11-01T00:00:00Z', newest: { record: 100, digest: 'a'.repeat(64), fields: {} },
      kernel: { record: 80, digest: 'b'.repeat(64), fields: { StartTime: '2026-11-01T00:00:02Z' } },
      boot: { record: 79, digest: 'c'.repeat(64), fields: { BootType: '0' } },
      checkpoint: checkpoint === undefined ? null : { record: checkpoint, digest: 'a'.repeat(64), fields: {} },
      legacyRunOnce: null, nativeRunOnce: null, knownWriters: [],
    }
    await faults.collect?.(index, evidence)
    return evidence
  }
  const options: MigrationPreparationOptions = { dataDir, backupDirectory, helperPath, collectorPath, appPath,
    endpoints: ['127.0.0.1:7890', '127.0.0.1:7891'], exec, collect }
  const blocked = async () => {
    expect(mutations()).toEqual([])
    expect(calls.some(call => call.file === legacyPath)).toBe(false)
    expect(JSON.parse(await readFile(marker, 'utf8')).state).toBe('preparing')
    await expect(guardMigrationStartup(dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
  }
  const mutations = () => calls.filter(call => !(
    call.file === helperPath && ['get', 'publish-migration'].includes(call.args[0]!) ||
    call.file === 'reg.exe' && call.args[0] === 'export'))
  return { options, root, marker, legacyPath, command, faults, state, calls, blocked, mutations }
}

test('canonical fixture paths do not weaken rejection of aliased migration directories', async () => {
  const f = await fixture()
  const alias = join(f.root, 'alias')
  await symlink(f.options.dataDir, alias, process.platform === 'win32' ? 'junction' : 'dir')
  await expect(prepareProxyMigration({ ...f.options, dataDir: alias })).rejects.toThrow('links or aliases')
  expect(f.calls).toHaveLength(0)
  await expect(lstat(f.marker)).rejects.toMatchObject({ code: 'ENOENT' })
})

test('prepared disk evidence is rehashed without executing helper or authorizing admission', async () => {
  const f = await fixture()
  const prepared = await prepareProxyMigration(f.options)
  const commands = f.calls.length
  expect(await readPreparedMigration(f.options.dataDir, f.options.helperPath, f.options)).toEqual(prepared)
  expect(f.calls).toHaveLength(commands)
  await expect(guardMigrationStartup(f.options.dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
})

test.each(['before-get.json', 'after-get.json', 'retirement.json', 'current-helper.exe',
  'internet-settings.reg', 'manifest.json', 'deployed-helper', 'incomplete-marker', 'helper-binding',
  'deployed-collector', 'deployed-app', 'collector-binding', 'app-binding',
  'manifest-binding', 'inventory-traversal', 'missing-file', 'backup-alias'])(
  'disk receipt verification rejects %s without new commands', async fault => {
    const f = await fixture()
    await prepareProxyMigration(f.options)
    const commands = f.calls.length
    const receipt = JSON.parse(await readFile(f.marker, 'utf8'))
    const backup = f.options.backupDirectory
    if (fault === 'deployed-helper') await writeFile(f.options.helperPath, 'changed executable')
    else if (fault === 'deployed-collector') await writeFile(f.options.collectorPath, 'changed collector')
    else if (fault === 'deployed-app') await writeFile(f.options.appPath, 'changed app')
    else if (fault === 'incomplete-marker') {
      receipt.state = 'preparing'
      await writeFile(f.marker, JSON.stringify(receipt))
    } else if (fault === 'helper-binding') {
      receipt.helperPath = f.legacyPath
      await writeFile(f.marker, JSON.stringify(receipt))
    } else if (fault === 'collector-binding' || fault === 'app-binding') {
      if (fault === 'collector-binding') receipt.collectorPath = f.options.appPath
      else receipt.appPath = f.options.collectorPath
      await writeFile(f.marker, JSON.stringify(receipt))
    } else if (fault === 'manifest-binding' || fault === 'inventory-traversal') {
      const manifestPath = join(backup, 'manifest.json')
      const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
      if (fault === 'manifest-binding') manifest.id = '00000000-0000-4000-8000-000000000000'
      else manifest.files['../outside'] = 'a'.repeat(64)
      const raw = JSON.stringify(manifest)
      await writeFile(manifestPath, raw)
      receipt.backupDigest = sha(raw)
      await writeFile(f.marker, JSON.stringify(receipt))
    } else if (fault === 'missing-file') await rm(join(backup, 'after-get.json'))
    else if (fault === 'backup-alias') {
      const alias = join(f.root, 'backup-alias')
      await symlink(backup, alias, process.platform === 'win32' ? 'junction' : 'dir')
      receipt.backupDirectory = alias
      await writeFile(f.marker, JSON.stringify(receipt))
    } else await writeFile(join(backup, fault), 'corrupted evidence')
    await expect(readPreparedMigration(f.options.dataDir, f.options.helperPath, f.options)).rejects.toThrow()
    expect(f.calls).toHaveLength(commands)
    await expect(guardMigrationStartup(f.options.dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
  })

test('durable capture records absence without retirement; all proxies stay unchanged and admission stays denied', async () => {
  const f = await fixture()
  const receipt = await prepareProxyMigration(f.options)
  expect(receipt).toMatchObject({ version: 1, state: 'prepared', helperPath: f.options.helperPath,
    helperDigest: sha('current fake helper bytes'), endpoints: f.options.endpoints,
    collectorPath: f.options.collectorPath, collectorDigest: sha('non-executable fake collector bytes'),
    appPath: f.options.appPath, appDigest: sha('non-executable fake packaged app bytes') })
  expect(receipt.before.legacyRunOnce).toBeNull()
  expect(receipt.after.legacyRunOnce).toBeNull()
  expect(receipt.after.checkpoint).toMatchObject({ record: receipt.before.newest.record, digest: receipt.before.newest.digest })
  expect(JSON.parse(await readFile(f.marker, 'utf8'))).toEqual(receipt)
  const manifestBytes = await readFile(join(receipt.backupDirectory, 'manifest.json'))
  expect(sha(manifestBytes)).toBe(receipt.backupDigest)
  const manifest = JSON.parse(manifestBytes.toString())
  expect(manifest).toMatchObject({ id: receipt.id, userSid: receipt.userSid, before: receipt.before, after: receipt.after,
    helperDigest: receipt.helperDigest, endpoints: receipt.endpoints,
    collectorPath: receipt.collectorPath, collectorDigest: receipt.collectorDigest,
    appPath: receipt.appPath, appDigest: receipt.appDigest,
    legacyHelper: null })
  for (const [name, digest] of Object.entries(manifest.files)) expect(sha(await readFile(join(receipt.backupDirectory, name)))).toBe(digest)
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'legacy-runonce.json'), 'utf8'))).toBeNull()
  expect(await readFile(join(receipt.backupDirectory, 'internet-settings.reg'))).toEqual(registry)
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'before-get.json'), 'utf8')).connections).toEqual(initialConnections)
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'after-get.json'), 'utf8')).connections).toEqual(initialConnections)
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'retirement.json'), 'utf8'))).toEqual({
    kind: 'absence-observation', legacyRunOnce: null,
  })
  await expect(lstat(join(receipt.backupDirectory, 'clear.json'))).rejects.toMatchObject({ code: 'ENOENT' })
  expect(await readFile(join(receipt.backupDirectory, 'current-helper.exe'), 'utf8')).toBe('current fake helper bytes')
  await expect(lstat(join(receipt.backupDirectory, 'legacy-helper.exe'))).rejects.toMatchObject({ code: 'ENOENT' })
  expect(f.mutations()).toEqual([])
  expect(f.state).toEqual({ gets: 3, collects: 3 })
  expect(f.calls.every(call => [f.options.helperPath, 'reg.exe'].includes(call.file))).toBe(true)
  await expect(guardMigrationStartup(f.options.dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
})

test.each(['throw', 'corrupt', 'missing-connections', 'durability', 'absence-durability'] as const)(
  'failed backup %s preserves blocking marker without retirement or proxy writes', async failure => {
  const f = await fixture()
  if (failure === 'durability') f.faults.publish = 'backup.json'
  else if (failure === 'absence-durability') f.faults.publish = 'retirement.json'
  else f.faults.registry = failure
  await expect(prepareProxyMigration(f.options)).rejects.toThrow()
  expect(f.mutations()).toHaveLength(0)
  expect(f.state.collects).toBe(failure === 'absence-durability' ? 3 : 1)
  await f.blocked()
})

test.each(['json', 'ras', 'lan', 'field', 'connection-error', 'duplicate'] as const)('corrupt/incomplete helper get %s denies before mutation', async failure => {
  const f = await fixture()
  f.faults.get = (_index, result) => {
    const rows = result.connections as Record<string, unknown>[]
    if (failure === 'json') return '{'
    if (failure === 'ras') result.rasError = { code: 5, message: 'Cannot enumerate RAS' }
    if (failure === 'lan') rows.shift()
    if (failure === 'field') delete rows[1]!.autoConfigUrl
    if (failure === 'connection-error') rows[1]!.error = { code: 5 }
    if (failure === 'duplicate') rows.push({ ...rows[1]! })
    return JSON.stringify(result)
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow()
  expect(f.mutations()).toHaveLength(0)
  await f.blocked()
})

test.each([1, 2, 3])('legacy registration at collection %s blocks without deleting it or mutating proxies', async index => {
  const f = await fixture()
  let captured: BootEvidence | undefined
  f.faults.collect = (current, evidence) => {
    if (current !== index) return
    evidence.legacyRunOnce = f.command
    captured = evidence
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('Legacy RunOnce registration exists')
  expect(captured?.legacyRunOnce).toBe(f.command)
  expect(f.state.collects).toBe(index)
  expect(f.mutations()).toEqual([])
  expect(await readFile(f.legacyPath, 'utf8')).toBe('original fake helper bytes')
  await expect(lstat(join(f.options.backupDirectory, 'retirement.json'))).rejects.toMatchObject({ code: 'ENOENT' })
  if (index === 1) expect(f.calls.map(call => call.args[0])).toEqual(['publish-migration'])
  else {
    const backup = JSON.parse(await readFile(join(f.options.backupDirectory, 'backup.json'), 'utf8'))
    for (const [name, digest] of Object.entries(backup.files))
      expect(sha(await readFile(join(f.options.backupDirectory, name)))).toBe(digest)
    expect(JSON.parse(await readFile(join(f.options.backupDirectory, 'legacy-runonce.json'), 'utf8'))).toBeNull()
    expect(JSON.parse(await readFile(join(f.options.backupDirectory, 'before-get.json'), 'utf8')).connections).toEqual(initialConnections)
  }
  await f.blocked()
})

test.each([1, 2, 3].flatMap(index => ['missing', 'invalid', 'query-error'].map(fault => ({ index, fault }))))(
  'unknown legacy registration state $fault at collection $index is never treated as absence', async ({ index, fault }) => {
    const f = await fixture()
    f.faults.collect = (current, evidence) => {
      if (current !== index) return
      if (fault === 'missing') Reflect.deleteProperty(evidence, 'legacyRunOnce')
      else if (fault === 'invalid') Object.assign(evidence, { legacyRunOnce: false })
      else throw new Error('legacy registry query denied')
    }
    await expect(prepareProxyMigration(f.options)).rejects.toThrow()
    expect(f.state.collects).toBe(index)
    await expect(lstat(join(f.options.backupDirectory, 'retirement.json'))).rejects.toMatchObject({ code: 'ENOENT' })
    await f.blocked()
  })

test.each(['writers', 'empty-command', 'extra-command', 'trailing-newline', 'unknown-endpoint', 'wrong-helper', 'bad-collector'] as const)(
  'unsafe preflight %s never executes captured command or clear', async failure => {
    const f = await fixture()
    f.faults.collect = (_index, evidence) => {
      if (failure === 'writers') evidence.knownWriters = [{ pid: 123, name: 'mihomo' }]
      if (failure === 'empty-command') evidence.legacyRunOnce = ''
      if (failure === 'extra-command') evidence.legacyRunOnce = f.command + ' & anything-else'
      if (failure === 'trailing-newline') evidence.legacyRunOnce = f.command + '\n'
      if (failure === 'unknown-endpoint') evidence.legacyRunOnce = f.command.replace(':7890', ':7892')
      if (failure === 'wrong-helper') evidence.legacyRunOnce = f.command.replace('kuro-sysproxy.exe', 'something.exe')
      if (failure === 'bad-collector') evidence.userSid = 'unavailable'
    }
    await expect(prepareProxyMigration(f.options)).rejects.toThrow()
    expect(f.mutations()).toHaveLength(0)
    expect(f.calls.some(call => (call.file === f.options.helperPath && call.args[0] !== 'publish-migration') || call.file === f.legacyPath || call.file === 'reg.exe')).toBe(false)
    await f.blocked()
  })

test.each(['registered', 'empty', 'missing', 'invalid', 'lower-hash-writer', 'upper-hash-writer'] as const)(
  'unsupported native preflight %s denies before helper/registry calls and preserves evidence', async failure => {
    const f = await fixture()
    const command = `"${join(f.root, `${'a'.repeat(64)}.exe`)}" recover`
    let captured: BootEvidence | undefined
    f.faults.collect = (_index, evidence) => {
      if (failure === 'registered') evidence.nativeRunOnce = command
      if (failure === 'empty') evidence.nativeRunOnce = ''
      if (failure === 'missing') Reflect.deleteProperty(evidence, 'nativeRunOnce')
      if (failure === 'invalid') Object.assign(evidence, { nativeRunOnce: 0 })
      if (failure === 'lower-hash-writer') evidence.knownWriters = [{ pid: 123, name: 'a'.repeat(64) }]
      if (failure === 'upper-hash-writer') evidence.knownWriters = [{ pid: 123, name: 'A'.repeat(64) }]
      captured = evidence
    }
    await expect(prepareProxyMigration(f.options)).rejects.toThrow()
    expect(f.calls.map(call => call.args[0])).toEqual(['publish-migration']) // Fake marker publication only.
    expect(f.state).toEqual({ gets: 0, collects: 1 })
    if (failure === 'registered') expect(captured?.nativeRunOnce).toBe(command)
    if (failure === 'empty') expect(captured?.nativeRunOnce).toBe('')
    await expect(lstat(f.options.backupDirectory)).rejects.toMatchObject({ code: 'ENOENT' })
    await f.blocked()
  })

test.each([2, 3])('native registration appearing at collection %s blocks preparation without retirement', async index => {
  const f = await fixture()
  const command = `"${join(f.root, `${'a'.repeat(64)}.exe`)}" recover`
  let captured: BootEvidence | undefined
  f.faults.collect = (current, evidence) => {
    if (current !== index) return
    evidence.nativeRunOnce = command
    captured = evidence
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('Native recovery registration exists')
  expect(captured?.nativeRunOnce).toBe(command)
  expect(f.mutations()).toHaveLength(0)
  expect(JSON.parse(await readFile(join(f.options.backupDirectory, 'before-boot.json'), 'utf8')).nativeRunOnce).toBeNull()
  await f.blocked()
})

test.each([
  { index: 2, fault: 'machine' }, { index: 3, fault: 'machine' },
  { index: 2, fault: 'uptime' }, { index: 3, fault: 'uptime' },
])('same-boot $fault change at collection $index denies even with unchanged wall/event identity', async ({ index, fault }) => {
  const f = await fixture()
  f.faults.collect = (current, evidence) => {
    if (current !== index) return
    if (fault === 'machine') evidence.machineGuidSha256 = 'f'.repeat(64)
    else evidence.uptimeMs = '1'
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('Identity or boot continuity changed')
  expect(f.mutations()).toHaveLength(0)
  await f.blocked()
})

test('final uptime cannot regress below the recheck even while exceeding the initial baseline', async () => {
  const f = await fixture()
  f.faults.collect = (index, evidence) => {
    if (index === 2) evidence.uptimeMs = '9007199254740993'
    if (index === 3) evidence.uptimeMs = '9007199254740992'
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('Identity or boot continuity changed')
  expect(f.mutations()).toHaveLength(0)
  await f.blocked()
})

test.each(['86400000', '9007199254740993'])('same-boot quantized uptime equality %s remains valid preparation evidence', async uptimeMs => {
  const f = await fixture()
  f.faults.collect = (_index, evidence) => { evidence.uptimeMs = uptimeMs }
  const receipt = await prepareProxyMigration(f.options)
  expect(receipt.before.uptimeMs).toBe(uptimeMs)
  expect(receipt.after.uptimeMs).toBe(uptimeMs)
  expect(receipt.after.machineGuidSha256).toBe(receipt.before.machineGuidSha256)
  expect(receipt.before.nativeRunOnce).toBeNull()
  expect(receipt.after.nativeRunOnce).toBeNull()
})

test.each(['writers', 'command', 'helper', 'collector', 'app', 'backup', 'proxy'] as const)(
  'recheck catches %s changing during backup', async failure => {
  const f = await fixture()
  f.faults.collect = async (index, evidence) => {
    if (index !== 2) return
    if (failure === 'writers') evidence.knownWriters = [{ pid: 123, name: 'mihomo' }]
    if (failure === 'command') evidence.legacyRunOnce = f.command
    if (failure === 'helper') await writeFile(f.options.helperPath, 'changed helper')
    if (failure === 'collector') await writeFile(f.options.collectorPath, 'changed collector')
    if (failure === 'app') await writeFile(f.options.appPath, 'changed app')
    if (failure === 'backup') await writeFile(join(f.options.backupDirectory, 'before-get.json'), '{}')
  }
  if (failure === 'proxy') f.faults.get = (index, result) => {
    if (index === 2) (result.connections as { flags: number }[])[1]!.flags = 1
    return JSON.stringify(result)
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow()
  expect(f.mutations()).toHaveLength(0)
  await f.blocked()
})

test.each(['flags', 'pac', 'bypass', 'server', 'inventory', 'ras'] as const)('final unexpected %s changes never produce prepared receipt', async failure => {
  const f = await fixture()
  f.faults.get = (index, result) => {
    if (index === 3) {
      const rows = result.connections as Record<string, unknown>[]
      if (failure === 'flags') rows[1]!.flags = 1
      if (failure === 'pac') rows[1]!.autoConfigUrl = null
      if (failure === 'bypass') rows[1]!.bypass = ''
      if (failure === 'server') rows[2]!.proxyServer = 'someone.else:3128'
      if (failure === 'inventory') rows.pop()
      if (failure === 'ras') result.rasError = { code: 5 }
    }
    return JSON.stringify(result)
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow()
  expect(f.mutations()).toHaveLength(0)
  expect(f.state.collects).toBe(2)
  await f.blocked()
})

test.each(['writers', 'registration', 'boot', 'identity', 'checkpoint'] as const)('final boot evidence %s failure blocks prepared state', async failure => {
  const f = await fixture()
  f.faults.collect = (index, evidence) => {
    if (index !== 3) return
    if (failure === 'writers') evidence.knownWriters = [{ pid: 123, name: 'mihomo' }]
    if (failure === 'registration') evidence.legacyRunOnce = f.command
    if (failure === 'boot') evidence.lastBootUpTime = '2026-11-02T00:00:00Z'
    if (failure === 'identity') evidence.userSid = 'S-1-5-21-4-3-2-1001'
    if (failure === 'checkpoint') evidence.checkpoint = null
  }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow()
  expect(f.mutations()).toHaveLength(0)
  await f.blocked()
})

test.each(['', '{corrupt', '{"state":"preparing"}', '{"state":"prepared"}'])('never overwrites existing marker %j', async content => {
  const f = await fixture()
  await writeFile(f.marker, content)
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('already exists')
  expect(await readFile(f.marker, 'utf8')).toBe(content)
  expect(f.calls).toHaveLength(0)
})

test('non-file marker and inside-data backup are denied without commands', async () => {
  const f = await fixture()
  await mkdir(f.marker)
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('already exists')
  await expect(prepareProxyMigration({ ...f.options, backupDirectory: join(f.options.dataDir, 'backup') })).rejects.toThrow('outside')
  expect(f.calls).toHaveLength(0)
})

test('marker changed by someone else is preserved, not replaced with prepared state', async () => {
  const f = await fixture()
  f.faults.collect = async index => { if (index === 2) await writeFile(f.marker, '{corrupt other marker') }
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('marker changed')
  expect(await readFile(f.marker, 'utf8')).toBe('{corrupt other marker')
  expect(f.mutations()).toHaveLength(0)
})

test('failed final write-through leaves preparing and all preserved evidence', async () => {
  const f = await fixture()
  f.faults.publish = 'proxy-migration.json'
  await expect(prepareProxyMigration(f.options)).rejects.toThrow('write-through failure')
  expect(f.mutations()).toHaveLength(0)
  expect(JSON.parse(await readFile(join(f.options.backupDirectory, 'manifest.json'), 'utf8')).after.legacyRunOnce).toBeNull()
  await f.blocked()
})

test('absent legacy registration is explicit and needs no captured helper', async () => {
  const f = await fixture()
  f.faults.collect = (_index, evidence) => { evidence.legacyRunOnce = null }
  const receipt = await prepareProxyMigration(f.options)
  expect(receipt.before.legacyRunOnce).toBeNull()
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'manifest.json'), 'utf8')).legacyHelper).toBeNull()
  await expect(lstat(join(receipt.backupDirectory, 'legacy-helper.exe'))).rejects.toMatchObject({ code: 'ENOENT' })
  expect(f.mutations()).toHaveLength(0)
  expect(JSON.parse(await readFile(join(receipt.backupDirectory, 'retirement.json'), 'utf8')))
    .toEqual({ kind: 'absence-observation', legacyRunOnce: null })
})

test.each([1, 3])('collector/app identity changes during collection %s retain fail-closed marker', async index => {
  for (const target of ['collectorPath', 'appPath'] as const) {
    const f = await fixture()
    f.faults.collect = async current => {
      if (current === index) await writeFile(f.options[target], 'changed deployment identity during collection')
    }
    await expect(prepareProxyMigration(f.options)).rejects.toThrow('app or collector changed')
    expect(f.mutations()).toHaveLength(0)
    await f.blocked()
  }
})

test.each(['collectorPath', 'appPath'] as const)('deployment %s alias is rejected before any commands', async target => {
  const f = await fixture(), alias = join(f.root, `${target}-alias`)
  await symlink(dirname(f.options[target]), alias, process.platform === 'win32' ? 'junction' : 'dir')
  await expect(prepareProxyMigration({ ...f.options, [target]: join(alias, basename(f.options[target])) })).rejects.toThrow('links or aliases')
  expect(f.calls).toHaveLength(0)
})

test('explicit development source identity is denied without touching ordinary startup', async () => {
  const f = await fixture(), appPath = join(f.root, 'index.ts')
  await writeFile(appPath, 'mutable source tree is not a packaged app')
  await expect(prepareProxyMigration({ ...f.options, appPath })).rejects.toThrow('packaged app.asar')
  expect(f.calls).toHaveLength(0)
})

test.each(['collectorPath', 'appPath'] as const)('receipt binds exact %s even when an alternate artifact has identical bytes', async target => {
  const f = await fixture()
  await prepareProxyMigration(f.options)
  const directory = join(f.root, 'copied-deployment')
  await mkdir(directory)
  const alternate = join(directory, basename(f.options[target]))
  await writeFile(alternate, await readFile(f.options[target]))
  const count = f.calls.length
  await expect(readPreparedMigration(f.options.dataDir, f.options.helperPath, { ...f.options, [target]: alternate }))
    .rejects.toThrow('deployment binding changed')
  expect(f.calls).toHaveLength(count)
})

test.each(['old-clear', 'old-retirement', 'different-command', 'proxy-write', 'missing-app-digest', 'registered-backup',
  'before-legacy', 'after-legacy', 'legacy-helper-inventory'])(
  'consistent rehashed manifest cannot substitute %s preparation semantics', async failure => {
    const f = await fixture()
    await prepareProxyMigration(f.options)
    const receipt = JSON.parse(await readFile(f.marker, 'utf8'))
    const manifestPath = join(f.options.backupDirectory, 'manifest.json')
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
    if (failure === 'old-clear') {
      manifest.files['clear.json'] = manifest.files['retirement.json']
      delete manifest.files['retirement.json']
    } else if (failure === 'missing-app-digest') {
      delete receipt.appDigest; delete manifest.appDigest
    } else if (failure === 'before-legacy' || failure === 'after-legacy') {
      const sample = failure === 'before-legacy' ? 'before' : 'after'
      receipt[sample].legacyRunOnce = f.command
      manifest[sample] = receipt[sample]
    } else if (failure === 'legacy-helper-inventory') {
      manifest.files['legacy-helper.exe'] = sha('original fake helper bytes')
      await writeFile(join(f.options.backupDirectory, 'legacy-helper.exe'), 'original fake helper bytes')
    } else if (failure === 'registered-backup') {
      const raw = JSON.stringify(f.command)
      await writeFile(join(f.options.backupDirectory, 'legacy-runonce.json'), raw)
      manifest.files['legacy-runonce.json'] = sha(raw)
    } else {
      const path = join(f.options.backupDirectory, 'retirement.json')
      const retirement = failure === 'old-retirement' ? { expectedCommand: null, stdout: null }
        : JSON.parse(await readFile(path, 'utf8'))
      if (failure === 'different-command') retirement.legacyRunOnce = f.command
      else if (failure === 'proxy-write') retirement.stdout = JSON.stringify({ command: 'clear', ok: true, runOnce: 'deleted', errorCode: 0 })
      const raw = JSON.stringify(retirement)
      await writeFile(path, raw)
      manifest.files['retirement.json'] = sha(raw)
    }
    const raw = JSON.stringify(manifest)
    await writeFile(manifestPath, raw)
    receipt.backupDigest = sha(raw)
    await writeFile(f.marker, JSON.stringify(receipt))
    const count = f.calls.length
    await expect(readPreparedMigration(f.options.dataDir, f.options.helperPath, f.options)).rejects.toThrow()
    expect(f.calls).toHaveLength(count)
    await expect(guardMigrationStartup(f.options.dataDir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
  })

test.each([[], ['127.0.0.1:7890\n'], ['localhost:7890'], ['127.0.0.1:07890'], ['127.0.0.1:65536'],
  ['127.0.0.1:7890', '127.0.0.1:7890']].map(endpoints => ({ endpoints })))(
  'rejects noncanonical endpoint inventory $endpoints before any commands', async ({ endpoints }) => {
  const f = await fixture()
  await expect(prepareProxyMigration({ ...f.options, endpoints })).rejects.toThrow('endpoint inventory')
  expect(f.calls).toHaveLength(0)
  })
