import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { gzipSync } from 'node:zlib'
import { afterEach, expect, test } from 'vitest'
import { sha256 } from './fetch-core.mjs'
import { checkArtifactPermissions, prepareMacosHelper } from './prepare-macos-helper.mjs'

const temporary = []
afterEach(async () => { await Promise.all(temporary.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))) })
const macTest = test.skipIf(process.platform === 'win32')
function macho(arch = 'arm64', payload = 'fixture') {
  const header = Buffer.alloc(32)
  header.writeUInt32LE(0xfeedfacf, 0)
  header.writeUInt32LE(arch === 'arm64' ? 0x0100000c : 0x01000007, 4)
  header.writeUInt32LE(2, 12)
  return Buffer.concat([header, Buffer.from(payload)])
}
async function put(path, data, mode = 0o644) {
  await mkdir(join(path, '..'), { recursive: true })
  await writeFile(path, data, { mode })
  await chmod(path, mode)
}
async function fixture(arch = 'arm64') {
  const root = await mkdtemp(join(tmpdir(), 'kuro-helper-prepare-'))
  temporary.push(root)
  const core = macho(arch, 'core')
  const helper = macho(arch, 'helper')
  const archive = gzipSync(core)
  const lock = JSON.parse(await readFile(new URL('../core.lock.json', import.meta.url), 'utf8'))
  lock.mihomo.targets[`darwin-${arch}`].sha256 = sha256(archive)
  const helperLock = { format: 1, version: '0.1.0', protocol: 1, targets: { [`darwin-${arch}`]: { sha256: sha256(helper) } } }
  const paths = {
    core: join(root, 'resources/core', `darwin-${arch}`, 'mihomo'),
    helper: join(root, 'resources/mac', arch, 'kuro-tun-helper'),
    helperLock: join(root, 'native/mac/helper.lock.json'),
    archive: join(root, 'resources/.cache', sha256(archive)),
    output: join(root, 'resources/mac', arch, 'helper-payload'),
  }
  await put(join(root, 'core.lock.json'), JSON.stringify(lock))
  await put(paths.archive, archive)
  await put(paths.core, core, 0o755)
  await put(paths.helper, helper, 0o755)
  await put(paths.helperLock, JSON.stringify(helperLock))
  return { root, core, helper, helperLock, paths }
}

macTest.each(['arm64', 'x64'])('prepares %s from pinned local archive/resources with executable hashes and disabled plist', async (arch) => {
  const f = await fixture(arch)
  const result = await prepareMacosHelper(`darwin-${arch}`, f.root)
  expect(result).toBe(f.paths.output)
  const manifest = JSON.parse(await readFile(join(result, 'manifest.json'), 'utf8'))
  expect(manifest.core.sha256).toBe(sha256(f.core))
  expect(manifest.core.archiveSha256).not.toBe(manifest.core.sha256)
  expect(manifest.helper.sha256).toBe(sha256(f.helper))
  expect(manifest.activationAllowed).toBe(false)
  expect(manifest.label).toBe('dev.kuro.tun')
  expect(await readFile(join(result, 'mihomo'))).toEqual(f.core)
  expect(await readFile(join(result, 'helper'))).toEqual(f.helper)
  const plist = await readFile(join(result, 'dev.kuro.tun.plist'), 'utf8')
  expect(plist).toContain('<key>Disabled</key><true/>')
  expect(plist).toContain('<string>--serve</string>')
  expect(plist).toContain(`/Library/PrivilegedHelperTools/dev.kuro.tun/versions/${manifest.release}/helper`)
  expect((await lstat(result)).mode & 0o777).toBe(0o700)
})

macTest.each([
  ['directory as executable', async (f) => { await rm(f.paths.helper); await mkdir(f.paths.helper) }, /not a regular file/],
  ['missing helper', async (f) => rm(f.paths.helper), /ENOENT/],
  ['missing helper lock', async (f) => rm(f.paths.helperLock), /ENOENT/],
  ['missing verified archive', async (f) => rm(f.paths.archive), /ENOENT/],
  ['archive digest mismatch', async (f) => writeFile(f.paths.archive, 'changed'), /sha256 mismatch/],
  ['resource differs from archive', async (f) => writeFile(f.paths.core, macho('arm64', 'modified')), /differs from verified archive/],
  ['helper digest mismatch', async (f) => writeFile(f.paths.helper, macho('arm64', 'changed')), /sha256 mismatch/],
  ['core architecture mismatch', async (f) => {
    const core = macho('x64')
    const archive = gzipSync(core)
    const lockPath = join(f.root, 'core.lock.json')
    const lock = JSON.parse(await readFile(lockPath, 'utf8'))
    lock.mihomo.targets['darwin-arm64'].sha256 = sha256(archive)
    await put(join(f.root, 'resources/.cache', sha256(archive)), archive)
    await put(lockPath, JSON.stringify(lock))
    await put(f.paths.core, core, 0o755)
  }, /Mach-O architecture/],
  ['helper architecture mismatch', async (f) => {
    const helper = macho('x64')
    f.helperLock.targets['darwin-arm64'].sha256 = sha256(helper)
    await put(f.paths.helperLock, JSON.stringify(f.helperLock))
    await put(f.paths.helper, helper, 0o755)
  }, /Mach-O architecture/],
  ['non-executable Mach-O', async (f) => {
    const helper = macho()
    helper.writeUInt32LE(6, 12)
    f.helperLock.targets['darwin-arm64'].sha256 = sha256(helper)
    await put(f.paths.helperLock, JSON.stringify(f.helperLock))
    await put(f.paths.helper, helper, 0o755)
  }, /Mach-O executable/],
  ['path field in helper lock', async (f) => {
    f.helperLock.targets['darwin-arm64'].path = '/tmp/evil'
    await put(f.paths.helperLock, JSON.stringify(f.helperLock))
  }, /helper lock/],
  ['writable executable', async (f) => chmod(f.paths.helper, 0o777), /permissions/],
  ['writable input directory', async (f) => chmod(join(f.root, 'resources/mac'), 0o777), /permissions/],
  ['leaf symlink', async (f) => { await rm(f.paths.helper); await symlink(f.paths.core, f.paths.helper) }, /symlink/],
  ['ancestor symlink', async (f) => {
    await rm(join(f.root, 'resources/mac/arm64'), { recursive: true })
    await symlink(join(f.root, 'resources/core/darwin-arm64'), join(f.root, 'resources/mac/arm64'))
  }, /symlink/],
])('rejects %s without publishing output', async (_name, change, error) => {
  const f = await fixture()
  await change(f)
  await expect(prepareMacosHelper('darwin-arm64', f.root)).rejects.toThrow(error)
  await expect(lstat(f.paths.output)).rejects.toThrow(/ENOENT/)
})

macTest('rejects arbitrary target/path and does not replace existing output', async () => {
  const f = await fixture()
  await expect(prepareMacosHelper('../../tmp', f.root)).rejects.toThrow(/target/)
  await mkdir(f.paths.output)
  await put(join(f.paths.output, 'keep'), 'existing')
  await expect(prepareMacosHelper('darwin-arm64', f.root)).rejects.toThrow(/already exists/)
  expect(await readFile(join(f.paths.output, 'keep'), 'utf8')).toBe('existing')
})

// Metadata-only: do not attempt to create a real setuid/setgid executable.
test.each([0o4755, 0o2755])('rejects special permission metadata %i', (mode) => {
  expect(() => checkArtifactPermissions({ mode }, 'fixture', true)).toThrow(/permissions/)
})
