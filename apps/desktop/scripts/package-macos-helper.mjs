import { authEndpoint } from './prepare-electron-auth-negatives.mjs'
// Offline disabled installer package. Never invokes Installer, launchctl or helper.
// Usage: node scripts/package-macos-helper.mjs [darwin-arm64|darwin-x64]
import { execFileSync } from 'node:child_process'
import { constants } from 'node:fs'
import { copyFile, cp, lstat, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { sha256, verify } from './fetch-core.mjs'
import { macosClientPin, protectedClientBundle, clientInventory } from './macos-client-pin.mjs'

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
export async function stageMacosHelperPackage(payload, destination, target, version, clientBundle) {
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
  if (clientBundle) {
    manifest.client = await macosClientPin(clientBundle)
    files['client-inventory.json'] = await clientInventory(clientBundle)
    manifest.clientInventorySHA256 = sha256(files['client-inventory.json'])
    files['manifest.json'] = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  }
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
  if (clientBundle) {
    await mkdir(join(root, 'Library/Application Support/Clash Kuro/Client'), { mode: 0o755 })
    const stagedClient = join(root, protectedClientBundle)
    await cp(clientBundle, stagedClient, { recursive: true, dereference: false, verbatimSymlinks: true, force: false, errorOnExist: true })
    if (JSON.stringify(await macosClientPin(stagedClient)) !== JSON.stringify(manifest.client)) throw new Error('staged client differs from approved build')
    if (sha256(await clientInventory(stagedClient)) !== manifest.clientInventorySHA256) throw new Error('staged client inventory changed')
  }
  await writeFile(join(root, tools, 'installer'), files.helper, { mode: 0o755, flag: 'wx' })
  await writeFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun-uninstall'), files.helper, { mode: 0o755, flag: 'wx' })
  await writeFile(join(scripts, 'preflight-native'), files.helper, { mode: 0o755, flag: 'wx' })
  for (const name of Object.keys(files)) await writeFile(join(root, state, 'Inbox', name), files[name], { mode: ['helper', 'mihomo'].includes(name) ? 0o755 : 0o600, flag: 'wx' })
  if (clientBundle) for (const name of ['manifest.json', 'client-inventory.json', `${label}.plist`]) await writeFile(join(scripts, name), files[name], { mode: 0o600, flag: 'wx' })
  const preinstall = '#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" ' + (clientBundle ? '--begin-client-install\n' : '--preflight-install\n')
  const postinstall = '#!/bin/sh\nset -eu\nexec "/Library/PrivilegedHelperTools/dev.kuro.tun/installer" --install\n'
  await writeFile(join(scripts, 'preinstall'), preinstall, { mode: 0o755, flag: 'wx' })
  await writeFile(join(scripts, 'postinstall'), postinstall, { mode: 0o755, flag: 'wx' })
  return { root, scripts, manifest }
}

export async function packageMacosHelper(target, withClient = false) {
  if (process.platform !== 'darwin' || !targets.includes(target)) throw new Error('macOS packaging requires darwin-arm64 or darwin-x64')
  const arch = target.slice('darwin-'.length)
  const { version } = JSON.parse(await readFile(join(desktopRoot, 'package.json'), 'utf8'))
  const dist = join(desktopRoot, 'dist')
  await mkdir(dist, { recursive: true })
  const info = await lstat(dist)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error('unsafe package output directory')
  const sourceCommit = withClient ? execFileSync('git', ['rev-parse', 'HEAD'], { cwd: desktopRoot, encoding: 'utf8' }).trim() : undefined
  if (withClient && execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: resolve(desktopRoot, '../..'), encoding: 'utf8' }).trim()) throw new Error('Commit candidate implementation before packaging')
  const output = join(dist, withClient ? `kuro-tun-auth-observation-${version}-${arch}-${sourceCommit.slice(0, 12)}.pkg` : `kuro-tun-helper-disabled-${version}-${arch}.pkg`)
  await absent(output)
  await absent(`${output}.json`)
  const temporary = await realpath(await mkdtemp(join(tmpdir(), 'kuro-helper-package-')))
  try {
    const candidate = withClient ? join(dist, 'electron-runtime-candidate', arch === 'arm64' ? 'mac-arm64' : 'mac', 'Clash Kuro.app') : undefined
    if (withClient) {
      const require = createRequire(import.meta.url)
      const builder = createRequire(require.resolve('electron-builder'))
      const packager = createRequire(builder.resolve('app-builder-lib'))
      const asar = packager('@electron/asar')
      const sealed = JSON.parse(asar.extractFile(join(candidate, 'Contents/Resources/app.asar'), 'package.json'))
      if (sealed.kuroSourceCommit !== sourceCommit || sealed.kuroAuthObservationOnly !== true) throw new Error('Sealed App must match candidate commit and forbid normal product launch')
    }
    const { root, scripts, manifest } = await stageMacosHelperPackage(join(desktopRoot, 'resources/mac', arch, 'helper-payload'), temporary, target, version, candidate)
    let nativeBuild
    if (withClient) {
      nativeBuild = JSON.parse(await readFile(join(desktopRoot, 'resources/mac', arch, 'kuro-tun-helper.build.json'), 'utf8'))
      if (nativeBuild.sourceCommit !== sourceCommit || !nativeBuild.sourceClean || nativeBuild.sha256 !== manifest.helper.sha256 || !nativeBuild.tests || !nativeBuild.coreSyntaxSkipped) throw new Error('Native helper requires the same clean commit, passing tests and explicit Core syntax skip')
    }
    const built = join(temporary, 'disabled.pkg')
    const components = join(temporary, 'components.plist')
    execFileSync('/usr/bin/pkgbuild', ['--analyze', '--root', root, components], { stdio: 'pipe' })
    const bundles = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', components], { encoding: 'utf8' }))
    function fixedLocations(items) { for (const bundle of items) {
      // Older macOS Installer versions otherwise relocate an approved App to an
      // existing copy outside our fixed protected installation directory.
      bundle.BundleIsRelocatable = false
      bundle.BundleIsVersionChecked = false
      bundle.BundleHasStrictIdentifier = true
      if (bundle.ChildBundles) fixedLocations(bundle.ChildBundles)
    } }
    fixedLocations(bundles)
    await writeFile(components, JSON.stringify(bundles), { mode: 0o600 })
    execFileSync('/usr/bin/plutil', ['-convert', 'xml1', components], { stdio: 'pipe' })
    execFileSync('/usr/bin/pkgbuild', ['--root', root, '--component-plist', components, '--scripts', scripts, '--identifier', `${label}.disabled`, '--version', version, '--install-location', '/', '--ownership', 'recommended', built], { stdio: 'inherit' })
    const metadata = {
      format: 1, target, version, release: manifest.release,
      ...(sourceCommit ? { sourceCommit, authEndpoint, experiment: 'authenticate-only', observationSeconds: 300, emergencyExitSeconds: 310, productionActivation: false,
        buildParameters: { electronBuilder: 'mac --dir --arm64', identity: '-', hardenedRuntime: true, sourceCommitInSealedASAR: true, nativeBuild } } : {}),
      disabled: true, startAvailable: false, clientAttestationComplete: false, rootCoreConfigurationValidated: false,
      packageSHA256: sha256(await readFile(built)), helperSHA256: manifest.helper.sha256, coreSHA256: manifest.core.sha256,
      ...(manifest.client ? { client: manifest.client, clientInventorySHA256: manifest.clientInventorySHA256, clientInstallPath: `/${protectedClientBundle}`, clientRemoval: 'Fresh-install receipt permits exact removal of this installed App and helper only; modified or unknown content is preserved.' } : {}),
      limitation: 'Fresh disabled install only; existing/partial installations refused. Production start and network hooks remain gated pending integrated admission and real-system acceptance. No publisher identity or full root-install acceptance claimed.',
    }
    await copyFile(built, output, constants.COPYFILE_EXCL)
    await writeFile(`${output}.json`, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o644, flag: 'wx' })
    console.log(`Disabled helper package: ${output}; metadata: ${output}.json (not installed)`)
    return output
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2).filter(value => value !== '--with-client')
  if (args.length > 1) { console.error('Usage: package-macos-helper.mjs [darwin-arm64|darwin-x64]'); process.exitCode = 1 }
  else packageMacosHelper(args[0] || `darwin-${process.arch}`, process.argv.includes('--with-client')).catch((error) => { console.error(error.message); process.exitCode = 1 })
}
