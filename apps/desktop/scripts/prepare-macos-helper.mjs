// Offline build payload only. No installer, service registration or privileged execution.
// Usage: node scripts/prepare-macos-helper.mjs [darwin-arm64|darwin-x64]
import { constants } from 'node:fs'
import { lstat, mkdtemp, open, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync } from 'node:zlib'
import { checkLock, sha256, verify } from './fetch-core.mjs'

const desktopRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const label = 'dev.kuro.tun'
const cap = 128 * 1024 * 1024
const targets = { 'darwin-arm64': ['arm64', 0x0100000c], 'darwin-x64': ['x64', 0x01000007] }

export function checkArtifactPermissions(info, path, executable = false) {
  if ((info.mode & 0o6022) || (executable && (info.mode & 0o777) !== 0o755)) {
    throw new Error(`unsafe permissions: ${path}`)
  }
}

async function checkedPath(root, path) {
  const part = relative(root, path)
  if (part.startsWith('..') || resolve(root, part) !== path) throw new Error('path escapes desktop resources')
  let current = root
  for (const component of ['', ...part.split(/[\\/]/).filter(Boolean)]) {
    if (component) current = join(current, component)
    const info = await lstat(current)
    if (info.isSymbolicLink()) throw new Error(`symlink rejected: ${current}`)
    checkArtifactPermissions(info, current)
    if (current !== path && !info.isDirectory()) throw new Error(`not a directory: ${current}`)
  }
}

async function requireAbsent(path) {
  try {
    await lstat(path)
    throw new Error('helper payload already exists; inspect/remove it explicitly before rebuilding')
  } catch (error) { if (error.code !== 'ENOENT') throw error }
}

async function localBytes(root, path, executable = false) {
  await checkedPath(root, path)
  if (!(await lstat(path)).isFile()) throw new Error(`not a regular file: ${path}`)
  const fd = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
  try {
    const before = await fd.stat()
    checkArtifactPermissions(before, path, executable)
    if (!before.isFile() || before.nlink !== 1 || before.size > cap) throw new Error(`invalid local artifact: ${path}`)
    const bytes = await fd.readFile()
    const after = await fd.stat()
    if (bytes.length !== before.size || ['ino', 'dev', 'size', 'mtimeMs', 'ctimeMs', 'mode'].some((key) => before[key] !== after[key])) {
      throw new Error(`artifact changed while reading: ${path}`)
    }
    await checkedPath(root, path)
    return bytes
  } finally { await fd.close() }
}

function machExecutable(data, cpu, name) {
  // Thin 64-bit executables only; the fixed lock selects the architecture.
  if (data.length < 32 || data.readUInt32LE(0) !== 0xfeedfacf || data.readUInt32LE(12) !== 2) {
    throw new Error(`${name}: expected a thin 64-bit Mach-O executable`)
  }
  if (data.readUInt32LE(4) !== cpu) throw new Error(`${name}: Mach-O architecture does not match target`)
}

function exactKeys(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === [...keys].sort().join(',')
}

function helperSpec(lock, target) {
  if (!exactKeys(lock, ['format', 'version', 'protocol', 'targets']) || lock.format !== 1 || lock.protocol !== 1 ||
      !/^\d+\.\d+\.\d+$/.test(lock.version) || !lock.targets || Array.isArray(lock.targets) ||
      Object.keys(lock.targets).some((key) => !Object.hasOwn(targets, key))) {
    throw new Error('invalid helper lock: expected fixed version, protocol and target digests')
  }
  for (const spec of Object.values(lock.targets)) {
    if (!exactKeys(spec, ['sha256']) || !/^[a-f0-9]{64}$/.test(spec.sha256)) throw new Error('invalid helper lock target')
  }
  if (!lock.targets[target]) throw new Error(`helper lock has no ${target} build`)
  return lock.targets[target]
}

// root is a build/test seam, never an RPC argument; CLI always uses this desktop directory.
export async function prepareMacosHelper(target, root = desktopRoot) {
  if (!Object.hasOwn(targets, target)) throw new Error('unsupported target; use darwin-arm64 or darwin-x64')
  root = resolve(root)
  const [arch, cpu] = targets[target]
  const lock = JSON.parse((await localBytes(root, join(root, 'core.lock.json'))).toString('utf8'))
  checkLock(lock)
  const coreSpec = lock.mihomo.targets[target]
  if (coreSpec.format !== 'gz') throw new Error('macOS Core must be a pinned gzip archive')
  let helperLock
  try {
    helperLock = JSON.parse((await localBytes(root, join(root, 'native/mac/helper.lock.json'))).toString('utf8'))
  } catch (error) {
    if (error.code === 'ENOENT') throw new Error(`helper build unavailable: build and pin native/mac/helper.lock.json before preparing a payload (${error.message})`)
    throw error
  }
  const helperPin = helperSpec(helperLock, target)
  const archive = verify(await localBytes(root, join(root, 'resources/.cache', coreSpec.sha256)), coreSpec.sha256, 'Core archive')
  const unpacked = gunzipSync(archive, { maxOutputLength: cap })
  const core = await localBytes(root, join(root, 'resources/core', target, 'mihomo'), true)
  if (!core.equals(unpacked)) throw new Error('Core resource differs from verified archive')
  const helper = verify(await localBytes(root, join(root, 'resources/mac', arch, 'kuro-tun-helper'), true), helperPin.sha256, 'helper executable')
  machExecutable(core, cpu, 'Core')
  machExecutable(helper, cpu, 'helper')

  const parent = join(root, 'resources/mac', arch)
  await checkedPath(root, parent)
  const output = join(parent, 'helper-payload')
  await requireAbsent(output)

  const release = `${lock.mihomo.version}-${helperLock.version}-${arch}-${sha256(Buffer.concat([core, helper])).slice(0, 16)}`
  const executablePath = `/Library/PrivilegedHelperTools/${label}/versions/${release}/helper`
  const manifest = {
    format: 1, label, release, target, protocol: helperLock.protocol,
    // Build ownership is not root installation or complete caller attestation.
    activationAllowed: false,
    core: { file: 'mihomo', version: lock.mihomo.version, sha256: sha256(core), archiveSha256: coreSpec.sha256 },
    helper: { file: 'helper', version: helperLock.version, sha256: sha256(helper) },
  }
  const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>${label}</string>\n<key>ProgramArguments</key><array><string>${executablePath}</string><string>--serve</string></array>\n<key>Disabled</key><true/>\n<key>RunAtLoad</key><false/>\n<key>KeepAlive</key><false/>\n</dict></plist>\n`
  const staging = await mkdtemp(join(parent, '.helper-payload-'))
  try {
    for (const [name, data, mode] of [
      ['mihomo', core, 0o755], ['helper', helper, 0o755],
      ['manifest.json', `${JSON.stringify(manifest, null, 2)}\n`, 0o600],
      [`${label}.plist`, plist, 0o644],
    ]) await writeFile(join(staging, name), data, { mode, flag: 'wx' })
    await checkedPath(root, parent)
    await requireAbsent(output)
    // Ordinary build concurrency check, not a same-UID race boundary; installer must revalidate all bytes.
    await rename(staging, output)
    return output
  } finally { await rm(staging, { recursive: true, force: true }) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  if (args.length > 1) {
    console.error('Usage: prepare-macos-helper.mjs [darwin-arm64|darwin-x64]')
    process.exitCode = 1
  } else {
    prepareMacosHelper(args[0] || `darwin-${process.arch}`)
      .then((path) => console.log(`Offline helper payload ready: ${path} (activation disabled; not installed)`))
      .catch((error) => { console.error(error.message); process.exitCode = 1 })
  }
}
