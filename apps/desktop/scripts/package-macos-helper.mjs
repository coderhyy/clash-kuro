// Offline disabled installer package. Never invokes Installer, launchctl or helper.
// Usage: node scripts/package-macos-helper.mjs [darwin-arm64|darwin-x64]
import { execFileSync } from 'node:child_process'
import { constants } from 'node:fs'
import { copyFile, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sha256, verify } from './fetch-core.mjs'

const desktopRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const label = 'dev.kuro.tun'
const tools = 'Library/PrivilegedHelperTools/dev.kuro.tun'
const state = 'Library/Application Support/Clash Kuro/Privileged'
const names = ['helper', 'mihomo', 'manifest.json', `${label}.plist`]
const targets = ['darwin-arm64', 'darwin-x64']

async function sourceBytes(directory, name) {
  const info = await lstat(join(directory, name))
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || (info.mode & 0o6022)) throw new Error(`unsafe payload file: ${name}`)
  return readFile(join(directory, name))
}
async function absent(path) {
  try { await lstat(path); throw new Error(`output already exists: ${path}`) } catch (error) { if (error.code !== 'ENOENT') throw error }
}

// Build/test seam only. The CLI never accepts payload or destination paths.
export async function stageMacosHelperPackage(payload, destination, target, version) {
  if (!targets.includes(target) || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('invalid fixed package target/version')
  const info = await lstat(payload)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error('unsafe payload directory')
  const files = Object.fromEntries(await Promise.all(names.map(async (name) => [name, await sourceBytes(payload, name)])))
  const manifest = JSON.parse(files['manifest.json'].toString('utf8'))
  if (manifest.format !== 1 || manifest.protocol !== 1 || manifest.label !== label || manifest.target !== target || manifest.activationAllowed !== false ||
      !/^[A-Za-z0-9.-]{1,120}$/.test(manifest.release) || manifest.helper?.version !== version || manifest.helper?.file !== 'helper' || manifest.core?.file !== 'mihomo') {
    throw new Error('payload must be the fixed disabled helper build')
  }
  verify(files.helper, manifest.helper.sha256, 'package helper')
  verify(files.mihomo, manifest.core.sha256, 'package Core')
  const program = `/Library/PrivilegedHelperTools/${label}/versions/${manifest.release}/helper`
  const plist = files[`${label}.plist`].toString('utf8')
  if (!plist.includes(`<key>ProgramArguments</key><array><string>${program}</string><string>--serve</string></array>`) ||
      !plist.includes('<key>Disabled</key><true/>') || !plist.includes('<key>RunAtLoad</key><false/>') || !plist.includes('<key>KeepAlive</key><false/>')) {
    throw new Error('package plist must have fixed --serve arguments and remain disabled')
  }
  const root = join(destination, 'root')
  const scripts = join(destination, 'scripts')
  await mkdir(root, { mode: 0o755 })
  for (const shared of ['Library', 'Library/PrivilegedHelperTools', 'Library/Application Support', 'Library/Application Support/Clash Kuro']) {
    await mkdir(join(root, shared), { mode: 0o755 })
  }
  await mkdir(join(root, tools), { mode: 0o755 })
  await mkdir(join(root, state), { mode: 0o700 })
  await mkdir(join(root, state, 'Inbox'), { mode: 0o700 })
  await mkdir(scripts, { mode: 0o700 })
  await writeFile(join(root, tools, 'installer'), files.helper, { mode: 0o755, flag: 'wx' })
  await writeFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun-uninstall'), files.helper, { mode: 0o755, flag: 'wx' })
  await writeFile(join(scripts, 'preflight-native'), files.helper, { mode: 0o755, flag: 'wx' })
  for (const name of names) await writeFile(join(root, state, 'Inbox', name), files[name], { mode: ['helper', 'mihomo'].includes(name) ? 0o755 : 0o600, flag: 'wx' })
  const preinstall = '#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" --preflight-install\n'
  const postinstall = '#!/bin/sh\nset -eu\nexec "/Library/PrivilegedHelperTools/dev.kuro.tun/installer" --install\n'
  await writeFile(join(scripts, 'preinstall'), preinstall, { mode: 0o755, flag: 'wx' })
  await writeFile(join(scripts, 'postinstall'), postinstall, { mode: 0o755, flag: 'wx' })
  return { root, scripts, manifest }
}

export async function packageMacosHelper(target) {
  if (process.platform !== 'darwin' || !targets.includes(target)) throw new Error('macOS packaging requires darwin-arm64 or darwin-x64')
  const arch = target.slice('darwin-'.length)
  const { version } = JSON.parse(await readFile(join(desktopRoot, 'package.json'), 'utf8'))
  const dist = join(desktopRoot, 'dist')
  await mkdir(dist, { recursive: true })
  const info = await lstat(dist)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error('unsafe package output directory')
  const output = join(dist, `kuro-tun-helper-disabled-${version}-${arch}.pkg`)
  await absent(output)
  await absent(`${output}.json`)
  const temporary = await mkdtemp(join(tmpdir(), 'kuro-helper-package-'))
  try {
    const { root, scripts, manifest } = await stageMacosHelperPackage(join(desktopRoot, 'resources/mac', arch, 'helper-payload'), temporary, target, version)
    const built = join(temporary, 'disabled.pkg')
    execFileSync('/usr/bin/pkgbuild', ['--root', root, '--scripts', scripts, '--identifier', `${label}.disabled`, '--version', version, '--install-location', '/', '--ownership', 'recommended', built], { stdio: 'inherit' })
    const metadata = {
      format: 1, target, version, release: manifest.release,
      disabled: true, startAvailable: false, clientAttestationComplete: false, rootCoreConfigurationValidated: false,
      packageSHA256: sha256(await readFile(built)), helperSHA256: manifest.helper.sha256, coreSHA256: manifest.core.sha256,
      limitation: 'Fresh disabled install only; existing/partial installations refused. No root Core start or network cleanup implementation. No publisher identity or full root-install acceptance claimed.',
    }
    await copyFile(built, output, constants.COPYFILE_EXCL)
    await writeFile(`${output}.json`, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o644, flag: 'wx' })
    console.log(`Disabled helper package: ${output}; metadata: ${output}.json (not installed)`)
    return output
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  if (args.length > 1) { console.error('Usage: package-macos-helper.mjs [darwin-arm64|darwin-x64]'); process.exitCode = 1 }
  else packageMacosHelper(args[0] || `darwin-${process.arch}`).catch((error) => { console.error(error.message); process.exitCode = 1 })
}
