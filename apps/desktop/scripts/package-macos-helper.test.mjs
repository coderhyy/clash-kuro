import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterEach, expect, test } from 'vitest'
import { sha256 } from './fetch-core.mjs'
import { stageMacosHelperPackage } from './package-macos-helper.mjs'

const temporary = []
afterEach(async () => { await Promise.all(temporary.splice(0).map((path) => rm(path, { recursive: true, force: true }))) })
const macTest = test.skipIf(process.platform !== 'darwin')
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'kuro-pkg-test-'))
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
  const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>dev.kuro.tun</string>\n<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/dev.kuro.tun/versions/${release}/helper</string><string>--serve</string></array>\n<key>Disabled</key><true/>\n<key>RunAtLoad</key><false/>\n<key>KeepAlive</key><false/>\n</dict></plist>\n`
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
