// Offline preparation only. Never launches the experiment, Core, App or an installer.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync, gzipSync } from 'node:zlib'
import { sha256 } from './fetch-core.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const repository = resolve(root, '../..')
const targets = { 'darwin-arm64': { arch: 'arm64', cpu: 0x0100000c }, 'darwin-x64': { arch: 'x86_64', cpu: 0x01000007 } }
const json = value => Buffer.from(`${JSON.stringify(value, null, 2)}\n`)
const diagnostics = Object.freeze({ format: 1, directoryPrefix: '/private/tmp/kuro-core-evidence-', directoryMode: 0o700, fileMode: 0o600,
  files: ['config.redacted.json', 'launch.json', 'stdout.log', 'stderr.log', 'diagnostics.json'], retainedBytesPerStream: 64 * 1024,
  overflow: 'drain-and-discard', redaction: 'session-secret-before-persist', coreStdIO: 'bounded-redacted-capture' })

export function verifiedCoreArchive(lock, target, archive) {
  const entry = lock?.mihomo?.targets?.[target]
  if (lock?.mihomo?.version !== 'v1.19.33' || !Object.hasOwn(targets, target) || entry?.format !== 'gz'
    || !/^[0-9a-f]{64}$/.test(entry?.sha256 ?? '') || !entry?.url?.startsWith('https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/')) {
    throw new Error('Exact locked macOS Core provenance required')
  }
  assert.equal(sha256(archive), entry.sha256, 'Cached locked Core archive changed')
  return gunzipSync(archive)
}
export function assertMachO(bytes, target) {
  if (bytes.length < 32 || bytes.readUInt32LE(0) !== 0xfeedfacf || bytes.readUInt32LE(4) !== targets[target]?.cpu || bytes.readUInt32LE(12) !== 2) {
    throw new Error('Expected one thin executable Mach-O for the exact target')
  }
}
async function regular(path) {
  const info = await lstat(path)
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || (info.mode & 0o6022)) throw new Error(`Unsafe build input: ${path}`)
  return readFile(path)
}
async function protectedDirectory(path, create = false) {
  if (create) { try { await mkdir(path, { mode: 0o700 }) } catch (error) { if (error.code !== 'EEXIST') throw error } }
  const info = await lstat(path)
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid() || (info.mode & 0o6022) || await realpath(path) !== path) throw new Error(`Unsafe build directory: ${path}`)
}
async function sourceInventory(entry) {
  const files = new Map()
  async function visit(path) {
    const relative = path.slice(repository.length + 1)
    if (files.has(relative)) return
    if (!path.startsWith(`${join(root, 'native/mac')}/`)) throw new Error('Native import escapes the reviewed source directory')
    const bytes = await regular(path)
    files.set(relative, sha256(bytes))
    for (const [, dependency] of bytes.toString('utf8').matchAll(/^\s*#(?:import|include)\s+"([^"\n]+)"/gm)) {
      if (!/^[a-zA-Z0-9_.-]+$/.test(dependency)) throw new Error('Unsupported native import')
      await visit(join(dirname(path), dependency))
    }
  }
  await visit(entry)
  for (const path of [fileURLToPath(import.meta.url), join(root, 'scripts/fetch-core.mjs'), join(root, 'core.lock.json')]) files.set(path.slice(repository.length + 1), sha256(await regular(path)))
  return Object.fromEntries([...files].sort(([a], [b]) => a.localeCompare(b)))
}
export async function buildCoreControlExperiment(target = `darwin-${process.arch}`) {
  if (process.platform !== 'darwin' || process.getuid() === 0 || !Object.hasOwn(targets, target) || target !== `darwin-${process.arch}`) throw new Error('Ordinary macOS user and native host target required')
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repository, encoding: 'utf8' }).trim()
  assert.match(sourceCommit, /^[0-9a-f]{40}$/)
  assert.equal(execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: repository, encoding: 'utf8' }).trim(), '', 'Commit and freeze source before building')
  const lockBytes = await regular(join(root, 'core.lock.json')), lock = JSON.parse(lockBytes)
  const archive = await regular(join(root, 'resources/.cache', lock.mihomo.targets[target].sha256))
  const core = verifiedCoreArchive(lock, target, archive)
  assertMachO(core, target)
  // The installed build may carry an ad-hoc signature. Provenance here is the exact locked archive bytes instead.
  const source = join(root, 'native/mac/core-experiment.m')
  const sourceFiles = await sourceInventory(source)
  const dist = join(root, 'dist')
  await protectedDirectory(dist, true)
  const output = join(dist, `core-control-experiment-${sourceCommit}`)
  try { await lstat(output); throw new Error('Frozen experiment output already exists; never overwrite it') } catch (error) { if (error.code !== 'ENOENT') throw error }
  const temporary = await mkdtemp(join(dist, '.core-control-build-'))
  let published = false
  try {
    await chmod(temporary, 0o700)
    const binary = join(temporary, 'core-experiment')
    const flags = ['-arch', targets[target].arch, '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-O2', '-DKURO_CORE_EXPERIMENT=1', `-DKURO_EXPERIMENT_CORE_SHA256="${sha256(core)}"`, `-DKURO_EXPERIMENT_ARCHIVE_SHA256="${sha256(archive)}"`, '-framework', 'Foundation', '-framework', 'Security', '-framework', 'SystemConfiguration', '-lbsm']
    execFileSync('/usr/bin/clang', [...flags, source, '-o', binary], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', binary], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--verify', '--strict', binary], { stdio: 'inherit' })
    const runner = await regular(binary)
    assertMachO(runner, target)
    await chmod(binary, 0o755)
    await writeFile(join(temporary, 'mihomo'), core, { mode: 0o755, flag: 'wx' })
    const experiment = { format: 1, protocol: 1, target, coreVersion: lock.mihomo.version, coreSHA256: sha256(core), coreArchiveSHA256: sha256(archive), runnerSHA256: sha256(runner), epoch: randomUUID().toUpperCase() }
    await writeFile(join(temporary, 'experiment.json'), json(experiment), { mode: 0o600, flag: 'wx' })
    await writeFile(join(temporary, 'core.lock.json'), lockBytes, { mode: 0o600, flag: 'wx' })
    const inventory = []
    for (const name of (await readdir(temporary)).sort()) {
      const bytes = await regular(join(temporary, name)), info = await lstat(join(temporary, name))
      inventory.push({ path: name, size: bytes.length, mode: info.mode & 0o777, sha256: sha256(bytes) })
    }
    const inventoryBytes = json({ format: 1, files: inventory })
    await writeFile(join(temporary, 'inventory.json'), inventoryBytes, { mode: 0o600, flag: 'wx' })
    const artifact = { format: 1, experiment: 'ordinary-uid-fixed-core-nonTUN-control', sourceCommit, sourceClean: true, target, epoch: experiment.epoch,
      sourceFiles, compiler: { executable: '/usr/bin/clang', flags, input: source.slice(repository.length + 1), output: 'core-experiment', version: execFileSync('/usr/bin/clang', ['--version'], { encoding: 'utf8' }).trim() },
      core: { version: experiment.coreVersion, url: lock.mihomo.targets[target].url, archiveSHA256: experiment.coreArchiveSHA256, executableSHA256: experiment.coreSHA256, lockSHA256: sha256(lockBytes) },
      binarySHA256: experiment.runnerSHA256, experimentManifestSHA256: sha256(json(experiment)), inventorySHA256: sha256(inventoryBytes), bundleSHA256: sha256(inventoryBytes),
      bundleHashMeaning: 'SHA256 of sorted inventory.json for fixed payload files, not an App identity', appBundle: null, productionHelper: null,
      diagnostics,
      coreExecuted: false, experimentExecuted: false, coreSyntaxExecuted: false, installed: false, networkChangesAuthorized: false,
      stages: { normal: 'requires user authorization for this experiment scope; build never executes Core', eof: 'requires successful same-epoch normal evidence and authorization', helperSigkill: 'not implemented or executable' } }
    await writeFile(join(temporary, 'artifact.json'), json(artifact), { mode: 0o600, flag: 'wx' })
    const sums = []
    for (const name of (await readdir(temporary)).sort()) sums.push(`${sha256(await regular(join(temporary, name)))}  ${name}`)
    await writeFile(join(temporary, 'SHA256SUMS'), `${sums.join('\n')}\n`, { mode: 0o600, flag: 'wx' })
    assert.deepEqual(await sourceInventory(source), sourceFiles, 'Source changed during build')
    assert.equal(execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repository, encoding: 'utf8' }).trim(), sourceCommit, 'Commit changed during build')
    assert.equal(execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: repository, encoding: 'utf8' }).trim(), '', 'Source became dirty during build')
    await rename(temporary, output)
    published = true
    console.log(`Offline experiment frozen: ${output}; no Core or experiment was executed`)
    return output
  } finally { if (!published) await rm(temporary, { recursive: true, force: true }) }
}
export function selfCheck() {
  const core = Buffer.alloc(32); core.writeUInt32LE(0xfeedfacf); core.writeUInt32LE(0x0100000c, 4); core.writeUInt32LE(2, 12)
  const archive = gzipSync(core)
  const lock = { mihomo: { version: 'v1.19.33', targets: { 'darwin-arm64': { format: 'gz', sha256: sha256(archive), url: 'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/fixed.gz' } } } }
  assert.deepEqual(verifiedCoreArchive(lock, 'darwin-arm64', archive), core)
  assertMachO(core, 'darwin-arm64')
  assert.throws(() => assertMachO(core, 'darwin-x64'))
  assert.throws(() => assertMachO(Buffer.alloc(32), 'darwin-arm64'))
  assert.throws(() => verifiedCoreArchive(lock, 'darwin-arm64', Buffer.from('changed')))
  assert.throws(() => verifiedCoreArchive({ mihomo: { ...lock.mihomo, version: 'v0.0.0' } }, 'darwin-arm64', archive))
  console.log('Core-control build self-check passed (in-memory only; no subprocess, Core, files or network)')
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  if (args.length === 1 && args[0] === '--self-test') selfCheck()
  else if (args.length <= 1 && (!args.length || Object.hasOwn(targets, args[0]))) buildCoreControlExperiment(args[0]).catch(error => { console.error(error.message); process.exitCode = 1 })
  else { console.error('Usage: build-core-control-experiment.mjs [--self-test|darwin-arm64|darwin-x64]'); process.exitCode = 1 }
}
