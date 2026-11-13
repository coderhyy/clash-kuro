import { chmod, cp, lstat, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterEach, expect, test, vi } from 'vitest'
import { sha256 } from './fetch-core.mjs'
import { stageMacosHelperPackage } from './package-macos-helper.mjs'
import { authEndpoint, externalNodeClient } from './prepare-electron-auth-negatives.mjs'
import { macosClientPin, macosCandidateMetadata, clientInventory } from './macos-client-pin.mjs'

// Offline layout fixtures inject only the separately tested App-seal inspection.
// Inventory generation and candidate/native build admission remain the real code.
vi.mock('./macos-client-pin.mjs', async original => ({
  ...await original(), macosClientPin: vi.fn(), macosCandidateMetadata: vi.fn(),
}))

const temporary = []
afterEach(async () => { vi.clearAllMocks(); await Promise.all(temporary.splice(0).map((path) => rm(path, { recursive: true, force: true }))) })
const macTest = test.skipIf(process.platform !== 'darwin')
async function retainLayoutFixture(operation, stage) {
  if (!process.env.KURO_UPGRADE_LAYOUT_FIXTURES) return
  const output = await realpath(process.env.KURO_UPGRADE_LAYOUT_FIXTURES)
  if (![await realpath(tmpdir()), await realpath('/tmp')].some(base => output.startsWith(`${base}/`))) throw new Error('Layout fixtures must be retained in an existing OS-temp child')
  await cp(stage, join(output, operation), { recursive: true, force: false, errorOnExist: true, preserveTimestamps: true })
}
async function fixture() {
  const directory = await realpath(await mkdtemp(join(tmpdir(), 'kuro-pkg-test-')))
  temporary.push(directory)
  const payload = join(directory, 'payload')
  const stage = join(directory, 'stage')
  await mkdir(payload, { mode: 0o700 })
  await mkdir(stage, { mode: 0o700 })
  const release = 'v1.19.33-0.1.0-arm64-test'
  const helper = Buffer.from('build-helper-fixture')
  const core = Buffer.from('build-core-fixture')
  const manifest = { format: 1, protocol: 1, label: 'dev.kuro.tun', release, target: 'darwin-arm64', activationAllowed: false,
    helper: { file: 'helper', version: '0.1.0', sha256: sha256(helper) }, core: { file: 'mihomo', sha256: sha256(core) } }
  const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>dev.kuro.tun</string>\n<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/dev.kuro.tun/versions/${release}/helper</string><string>--serve</string></array>\n<key>Disabled</key><true/>\n<key>RunAtLoad</key><false/>\n<key>KeepAlive</key><false/>\n<key>AbandonProcessGroup</key><false/>\n</dict></plist>\n`
  for (const [name, bytes] of Object.entries({ helper, mihomo: core, 'manifest.json': JSON.stringify(manifest), 'dev.kuro.tun.plist': plist })) await writeFile(join(payload, name), bytes, { mode: 0o600 })
  return { directory, payload, stage, manifest, plist }
}

macTest('stages actual fixed Installer payload/scripts without executing them', async () => {
  const f = await fixture()
  const { root, scripts } = await stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0')
  expect(await readFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun/installer'))).toEqual(await readFile(join(f.payload, 'helper')))
  expect((await lstat(join(root, 'Library/Application Support/Clash Kuro/Privileged'))).mode & 0o777).toBe(0o700)
  const post = await readFile(join(scripts, 'postinstall'), 'utf8')
  expect(post).toContain('exec "/Library/PrivilegedHelperTools/dev.kuro.tun/installer" --install')
  expect(post).not.toContain('bootstrap')
  const pre = await readFile(join(scripts, 'preinstall'), 'utf8')
  expect(pre).toContain('preflight-native')
  expect(pre).toContain('--preflight-install')
  expect(await readFile(join(scripts, 'preflight-native'))).toEqual(await readFile(join(f.payload, 'helper')))
  expect(await readFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun-uninstall'))).toEqual(await readFile(join(f.payload, 'helper')))
  for (const shared of ['Library', 'Library/PrivilegedHelperTools', 'Library/Application Support', 'Library/Application Support/Clash Kuro']) {
    expect((await lstat(join(root, shared))).mode & 0o777).toBe(0o755)
  }
})
macTest.each([
  ['digest mismatch', async (f) => writeFile(join(f.payload, 'helper'), 'changed'), /sha256 mismatch/],
  ['symlink', async (f) => { await rm(join(f.payload, 'helper')); await symlink(join(f.payload, 'mihomo'), join(f.payload, 'helper')) }, /unsafe payload/],
  ['writable payload', async (f) => chmod(f.payload, 0o777), /unsafe payload/],
  ['enabled payload', async (f) => { f.manifest.activationAllowed = true; await writeFile(join(f.payload, 'manifest.json'), JSON.stringify(f.manifest)) }, /disabled helper build/],
  ['release path', async (f) => { f.manifest.release = '../../x'; await writeFile(join(f.payload, 'manifest.json'), JSON.stringify(f.manifest)) }, /disabled helper build/],
  ['wrong target', async (f) => { f.manifest.target = 'darwin-x64'; await writeFile(join(f.payload, 'manifest.json'), JSON.stringify(f.manifest)) }, /disabled helper build/],
  ['missing serve argument', async (f) => writeFile(join(f.payload, 'dev.kuro.tun.plist'), f.plist.replace('<string>--serve</string>', '')), /fixed --serve/],
])('rejects %s before staging scripts', async (_name, change, message) => {
  const f = await fixture()
  await change(f)
  await expect(stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0')).rejects.toThrow(message)
  await expect(lstat(join(f.stage, 'scripts'))).rejects.toThrow(/ENOENT/)
})

// Native install/recovery share SocketDirectory; this guards the cross-language clients.
test('native and ordinary-user clients agree on fixed protected socket endpoints', async () => {
  const native = await readFile(new URL('../native/mac/kuro-tun-helper.m', import.meta.url), 'utf8')
  const client = await readFile(new URL('../src/main/tun-endpoints.ts', import.meta.url), 'utf8')
  const directory = native.match(/SocketDirectory = @"([^"]+)"/)?.[1]
  const control = `${directory}/control.sock`
  expect(directory).toBe('/Library/PrivilegedHelperTools/dev.kuro.tun-run')
  expect(native).toContain('[SocketDirectory stringByAppendingPathComponent:@"control.sock"]')
  expect(authEndpoint).toBe(`${directory}/auth.sock`)
  expect(client).toContain(`'${directory}'`)
  expect(client).toContain(`'${authEndpoint}'`)
  expect(client).toContain(`'${control}'`)
  expect(externalNodeClient).toContain(JSON.stringify(authEndpoint))
  for (const endpoint of [authEndpoint, control]) expect(Buffer.byteLength(endpoint) + 1).toBeLessThanOrEqual(104)
})

test('helper package modes default to disabled and keep --with-client auth-only', async () => {
  const { parsePackageArguments } = await import('./package-macos-helper.mjs')
  expect(parsePackageArguments([]).mode).toBe('disabled')
  expect(parsePackageArguments(['--with-client']).mode).toBe('auth-only')
  expect(parsePackageArguments(['darwin-arm64', '--mode=finite-session'])).toEqual({ target: 'darwin-arm64', mode: 'finite-session', operation: 'fresh' })
  expect(parsePackageArguments(['--mode=finite-session', '--operation=upgrade']).operation).toBe('upgrade')
  for (const args of [['--operation=upgrade'], ['--with-client', '--operation=upgrade'], ['--mode=finite-session', '--operation=replace'], ['--operation=fresh', '--operation=upgrade']]) expect(() => parsePackageArguments(args)).toThrow()
  expect(() => parsePackageArguments(['--mode=true'])).toThrow()
  expect(() => parsePackageArguments(['--with-client', '--mode=finite-session'])).toThrow(/exactly one/)
})

test('finite package admission binds newly built normal App and mandatory native suite to exact clean commit/hash', async () => {
  const { assertCandidateBuild } = await import('./package-macos-helper.mjs')
  const commit = 'a'.repeat(40), helper = 'b'.repeat(64)
  const client = { format: 2, cdhash: 'c'.repeat(40), executableSHA256: 'd'.repeat(64), infoSHA256: 'e'.repeat(64), asarSHA256: 'f'.repeat(64) }
  const metadata = { kuroSourceCommit: commit, kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false }
  const native = { sourceCommit: commit, sourceClean: true, sha256: helper, tests: true, coreSyntaxSkipped: false }
  const app = { format: 1, mode: 'finite-session', sourceCommit: commit, sourceClean: true, fromSource: true, client }
  const admit = (m = metadata, n = native, a = app, p = client) => assertCandidateBuild('finite-session', commit, m, n, helper, a, p)
  expect(admit()).toBe(true)
  for (const changed of [ { ...native, sourceCommit: '1'.repeat(40) }, { ...native, sourceClean: false }, { ...native, sha256: '2'.repeat(64) }, { ...native, tests: false }, { ...native, coreSyntaxSkipped: true } ]) expect(() => admit(metadata, changed)).toThrow(/Native helper/)
  for (const changed of [ undefined, { ...app, sourceCommit: '1'.repeat(40) }, { ...app, sourceClean: false }, { ...app, fromSource: false }, { ...app, client: { ...client, asarSHA256: '1'.repeat(64) } } ]) {
    // Explicit undefined must bypass the helper default and represent a missing record.
    expect(() => assertCandidateBuild('finite-session', commit, metadata, native, helper, changed, client)).toThrow(/source-build record/)
  }
  expect(() => admit({ ...metadata, kuroAuthObservationOnly: true })).toThrow(/normal App/)
  expect(assertCandidateBuild('auth-only', commit, { kuroSourceCommit: commit, kuroAuthObservationOnly: true }, { ...native, coreSyntaxSkipped: true }, helper)).toBe(false)
  expect(() => assertCandidateBuild('auth-only', commit, metadata, native, helper)).toThrow(/forbid normal/)
})

macTest('finite package mode cannot acquire activation without its actual client before staging', async () => {
  const f = await fixture()
  await expect(stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0', undefined, { mode: 'finite-session' })).rejects.toThrow(/corresponding client/)
  await expect(lstat(join(f.stage, 'scripts'))).rejects.toThrow(/ENOENT/)
  expect(JSON.parse(await readFile(join(f.payload, 'manifest.json'), 'utf8')).activationAllowed).toBe(false)
})

async function upgradeFixture() {
  const f = await fixture()
  const commit = 'a'.repeat(40)
  const client = { format: 2, cdhash: 'c'.repeat(40), executableSHA256: 'd'.repeat(64), infoSHA256: 'e'.repeat(64), asarSHA256: 'f'.repeat(64) }
  const bundle = join(f.directory, 'candidate.app')
  await mkdir(bundle, { mode: 0o755 })
  await writeFile(join(bundle, 'fixture-resource'), 'exact approved fixture bytes', { mode: 0o644 })
  vi.mocked(macosClientPin).mockResolvedValue(client)
  vi.mocked(macosCandidateMetadata).mockResolvedValue({ kuroSourceCommit: commit, kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false })
  const admission = { mode: 'finite-session', operation: 'upgrade', sourceCommit: commit,
    nativeBuild: { installerProtocol: 2, sourceCommit: commit, sourceClean: true, sha256: f.manifest.helper.sha256, tests: true, coreSyntaxSkipped: false },
    appBuild: { format: 1, mode: 'finite-session', sourceCommit: commit, sourceClean: true, fromSource: true, client } }
  f.manifest.installerProtocol = 2
  await writeFile(join(f.payload, 'manifest.json'), JSON.stringify(f.manifest))
  return { ...f, bundle, admission, client }
}

macTest('upgrade fixture stages only fixed protected Payload and invokes new script CLI without overwriting the current installation', async () => {
  const f = await upgradeFixture()
  const { root, scripts, manifest } = await stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0', f.bundle, f.admission)
  const privileged = join(root, 'Library/Application Support/Clash Kuro/Privileged')
  const payload = join(privileged, 'Upgrade/Payload')
  for (const directory of [privileged, join(privileged, 'Upgrade'), payload, join(payload, 'Inbox')]) expect((await lstat(directory)).mode & 0o777).toBe(0o700)
  for (const [name, mode] of [['helper', 0o755], ['mihomo', 0o755], ['manifest.json', 0o600], ['client-inventory.json', 0o600], ['dev.kuro.tun.plist', 0o600]]) expect((await lstat(join(payload, 'Inbox', name))).mode & 0o777).toBe(mode)
  expect(await readFile(join(payload, 'Inbox/helper'))).toEqual(await readFile(join(f.payload, 'helper')))
  expect(await clientInventory(join(payload, 'Client.app'))).toEqual(await clientInventory(f.bundle))
  expect(manifest.activationAllowed).toBe(true)
  expect(manifest.installerProtocol).toBe(2)
  expect(manifest.release).toBe(`${f.manifest.release}-c${manifest.clientInventorySHA256}`)
  const finalPlist = await readFile(join(payload, 'Inbox/dev.kuro.tun.plist'), 'utf8')
  expect(finalPlist).toContain(`/versions/${manifest.release}/helper`)
  expect(finalPlist).not.toContain(`/versions/${f.manifest.release}/helper`)
  for (const flag of ['<key>Disabled</key><true/>', '<key>RunAtLoad</key><false/>', '<key>KeepAlive</key><false/>', '<key>AbandonProcessGroup</key><false/>']) expect(finalPlist).toContain(flag)
  for (const name of ['manifest.json', 'client-inventory.json', 'dev.kuro.tun.plist']) expect(await readFile(join(scripts, name))).toEqual(await readFile(join(payload, 'Inbox', name)))
  expect(await readFile(join(scripts, 'preinstall'), 'utf8')).toBe('#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" --begin-client-upgrade\n')
  expect(await readFile(join(scripts, 'postinstall'), 'utf8')).toBe('#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" --complete-client-upgrade\n')
  expect(await readFile(join(scripts, 'preflight-native'))).toEqual(await readFile(join(f.payload, 'helper')))
  for (const path of ['Library/PrivilegedHelperTools', 'Library/Application Support/Clash Kuro/Client', `${'Library/Application Support/Clash Kuro/Privileged'}/Inbox`, `${'Library/Application Support/Clash Kuro/Privileged'}/installed.json`]) await expect(lstat(join(root, path))).rejects.toThrow(/ENOENT/)
  await retainLayoutFixture('upgrade', f.stage)
})

macTest('new protocol-2 payload still stages fresh installation through the original fixed installer path', async () => {
  const f = await upgradeFixture()
  const { root, scripts, manifest } = await stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0', f.bundle, { ...f.admission, operation: 'fresh' })
  expect(manifest.installerProtocol).toBe(2)
  const inbox = join(root, 'Library/Application Support/Clash Kuro/Privileged/Inbox')
  expect((await lstat(inbox)).mode & 0o777).toBe(0o700)
  for (const [name, mode] of [['helper', 0o755], ['mihomo', 0o755], ['manifest.json', 0o600], ['client-inventory.json', 0o600], ['dev.kuro.tun.plist', 0o600]]) expect((await lstat(join(inbox, name))).mode & 0o777).toBe(mode)
  expect(await readFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun/installer'))).toEqual(await readFile(join(f.payload, 'helper')))
  expect(await clientInventory(join(root, 'Library/Application Support/Clash Kuro/Client/Clash Kuro.app'))).toEqual(await clientInventory(f.bundle))
  expect(await readFile(join(scripts, 'preinstall'), 'utf8')).toContain('--begin-client-install')
  expect(await readFile(join(scripts, 'postinstall'), 'utf8')).toContain('/dev.kuro.tun/installer" --install')
  await expect(lstat(join(root, 'Library/Application Support/Clash Kuro/Privileged/Upgrade'))).rejects.toThrow(/ENOENT/)
  await retainLayoutFixture('fresh', f.stage)
})

macTest('App-only inventory changes produce a distinct deterministic release and matching plist while the prepared payload remains unchanged', async () => {
  const f = await upgradeFixture()
  async function stage(name) {
    const directory = join(f.directory, name)
    await mkdir(directory, { mode: 0o700 })
    return stageMacosHelperPackage(f.payload, directory, 'darwin-arm64', '0.1.0', f.bundle, f.admission)
  }
  const first = await stage('first'), same = await stage('same')
  expect(same.manifest.release).toBe(first.manifest.release)
  expect(same.manifest.clientInventorySHA256).toBe(first.manifest.clientInventorySHA256)
  await writeFile(join(f.bundle, 'fixture-resource'), 'App-only resource update', { mode: 0o644 })
  const changed = await stage('changed')
  expect(changed.manifest.core).toEqual(first.manifest.core)
  expect(changed.manifest.helper).toEqual(first.manifest.helper)
  expect(changed.manifest.clientInventorySHA256).not.toBe(first.manifest.clientInventorySHA256)
  expect(changed.manifest.release).not.toBe(first.manifest.release)
  const plist = await readFile(join(changed.scripts, 'dev.kuro.tun.plist'), 'utf8')
  expect(plist).toContain(`/versions/${changed.manifest.release}/helper`)
  expect(await readFile(join(changed.root, 'Library/Application Support/Clash Kuro/Privileged/Upgrade/Payload/Inbox/dev.kuro.tun.plist'), 'utf8')).toBe(plist)
  expect(JSON.parse(await readFile(join(f.payload, 'manifest.json'), 'utf8')).release).toBe(f.manifest.release)
  expect(await readFile(join(f.payload, 'dev.kuro.tun.plist'), 'utf8')).toBe(f.plist)
})

macTest.each([
  ['enabled', plist => plist.replace('<key>Disabled</key><true/>', '<key>Disabled</key><false/>')],
  ['wrong original program', plist => plist.replace('/versions/', '/unapproved/')],
])('App binding rejects %s prepared plist before any rewrite or staging', async (_name, change) => {
  const f = await upgradeFixture()
  await writeFile(join(f.payload, 'dev.kuro.tun.plist'), change(f.plist))
  await expect(stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0', f.bundle, f.admission)).rejects.toThrow('fixed --serve')
  expect(macosClientPin).not.toHaveBeenCalled()
  await expect(lstat(join(f.stage, 'root'))).rejects.toThrow(/ENOENT/)
})

macTest.each([
  ['legacy payload', f => { delete f.manifest.installerProtocol }, /protocol-2 payload/],
  ['unknown protocol', f => { f.manifest.installerProtocol = 3 }, /disabled helper build/],
  ['legacy native build', f => { delete f.admission.nativeBuild.installerProtocol }, /native build record/],
  ['wrong native hash', f => { f.admission.nativeBuild.sha256 = '0'.repeat(64) }, /native build record/],
  ['wrong source commit', f => { f.admission.nativeBuild.sourceCommit = '1'.repeat(40) }, /same clean commit/],
  ['auth-only mode', f => { f.admission.mode = 'auth-only' }, /explicit finite-session/],
])('upgrade refuses %s before writing any staged root', async (_name, change, message) => {
  const f = await upgradeFixture(); change(f)
  await writeFile(join(f.payload, 'manifest.json'), JSON.stringify(f.manifest))
  await expect(stageMacosHelperPackage(f.payload, f.stage, 'darwin-arm64', '0.1.0', f.bundle, f.admission)).rejects.toThrow(message)
  await expect(lstat(join(f.stage, 'root'))).rejects.toThrow(/ENOENT/)
})
