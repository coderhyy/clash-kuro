import { authEndpoint } from './prepare-electron-auth-negatives.mjs'
// Offline installer package. Never invokes Installer, launchctl, App or helper.
// Usage: node scripts/package-macos-helper.mjs [darwin-arm64|darwin-x64]
import { execFileSync } from 'node:child_process'
import { constants } from 'node:fs'
import { copyFile, cp, lstat, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sha256, verify } from './fetch-core.mjs'
import { assertMacosCandidateMode, macosCandidateMetadata, macosClientPin, protectedClientBundle, clientInventory } from './macos-client-pin.mjs'

const desktopRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const label = 'dev.kuro.tun'
const tools = 'Library/PrivilegedHelperTools/dev.kuro.tun'
const state = 'Library/Application Support/Clash Kuro/Privileged'
const upgradePayload = `${state}/Upgrade/Payload`
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

const modes = ['disabled', 'auth-only', 'finite-session']
export function parsePackageArguments(args) {
  let target, mode = 'disabled', selected = false, operation = 'fresh', operationSelected = false
  for (const arg of args) {
    if (arg === '--with-client' || arg.startsWith('--mode=')) {
      if (selected) throw new Error('Select exactly one helper package mode')
      mode = arg === '--with-client' ? 'auth-only' : arg.slice('--mode='.length)
      selected = true
    } else if (arg.startsWith('--operation=')) {
      if (operationSelected) throw new Error('Select exactly one helper package operation')
      operation = arg.slice('--operation='.length)
      operationSelected = true
    } else if (!arg.startsWith('-') && target === undefined) target = arg
    else throw new Error('Unsupported helper package argument')
  }
  if (!modes.includes(mode)) throw new Error('Unknown helper package mode')
  if (!['fresh', 'upgrade'].includes(operation) || (operation === 'upgrade' && mode !== 'finite-session')) throw new Error('Upgrade packages require explicit finite-session mode')
  return { target: target || `darwin-${process.arch}`, mode, operation }
}

// Values are checked again against the actual sealed App and helper bytes at staging.
export function assertCandidateBuild(mode, sourceCommit, metadata, nativeBuild, helperSHA256, appBuild, client) {
  assertMacosCandidateMode(metadata, mode, sourceCommit)
  if (nativeBuild?.sourceCommit !== sourceCommit || nativeBuild.sourceClean !== true || nativeBuild.sha256 !== helperSHA256 || nativeBuild.tests !== true ||
      nativeBuild.coreSyntaxSkipped !== (mode === 'auth-only')) throw new Error('Native helper requires the same clean commit, exact hash, passing mandatory tests and matching Core syntax policy')
  if (mode === 'finite-session' && (appBuild?.format !== 1 || appBuild.mode !== mode || appBuild.sourceCommit !== sourceCommit ||
      appBuild.sourceClean !== true || appBuild.fromSource !== true || !client || JSON.stringify(appBuild.client) !== JSON.stringify(client))) {
    throw new Error('Finite-session App requires a matching fresh source-build record and exact client pin')
  }
  return mode === 'finite-session'
}

// Build/test seam only. The CLI never accepts payload or destination paths.
export async function stageMacosHelperPackage(payload, destination, target, version, clientBundle, admission = {}) {
  const mode = admission.mode || (clientBundle ? 'auth-only' : 'disabled')
  const operation = admission.operation || 'fresh'
  if (!modes.includes(mode) || Boolean(clientBundle) !== (mode !== 'disabled')) throw new Error('Helper package mode requires the corresponding client')
  if (!['fresh', 'upgrade'].includes(operation) || (operation === 'upgrade' && mode !== 'finite-session')) throw new Error('Upgrade packages require explicit finite-session mode')
  if (!targets.includes(target) || !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('invalid fixed package target/version')
  const info = await lstat(payload)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error('unsafe payload directory')
  const files = Object.fromEntries(await Promise.all(names.map(async (name) => [name, await sourceBytes(payload, name)])))
  const manifest = JSON.parse(files['manifest.json'].toString('utf8'))
  if (manifest.format !== 1 || manifest.protocol !== 1 || manifest.label !== label || manifest.target !== target || manifest.activationAllowed !== false ||
      (manifest.installerProtocol !== undefined && manifest.installerProtocol !== 2) ||
      !/^[A-Za-z0-9.-]{1,120}$/.test(manifest.release) || manifest.helper?.version !== version || manifest.helper?.file !== 'helper' || manifest.core?.file !== 'mihomo') {
    throw new Error('payload must be the fixed disabled helper build')
  }
  if (operation === 'upgrade' && manifest.installerProtocol !== 2) throw new Error('Upgrade requires a protocol-2 payload; legacy installs require a separate migration')
  if (manifest.installerProtocol === 2 && (admission.nativeBuild?.installerProtocol !== 2 || admission.nativeBuild.sha256 !== manifest.helper.sha256 ||
      admission.nativeBuild.sourceClean !== true || admission.nativeBuild.tests !== true || !/^[a-f0-9]{40}$/.test(admission.nativeBuild.sourceCommit))) {
    throw new Error('Protocol-2 payload requires the exact clean tested native build record')
  }
  verify(files.helper, manifest.helper.sha256, 'package helper')
  verify(files.mihomo, manifest.core.sha256, 'package Core')
  const preparedProgram = `/Library/PrivilegedHelperTools/${label}/versions/${manifest.release}/helper`
  const preparedArguments = `<key>ProgramArguments</key><array><string>${preparedProgram}</string><string>--serve</string></array>`
  const plist = files[`${label}.plist`].toString('utf8')
  // Check the original payload before deriving any App-bound release/path. Never
  // repair an enabled or otherwise mismatched source plist while packaging it.
  if (plist.split(preparedArguments).length !== 2 || !plist.includes(`<key>Label</key><string>${label}</string>`) ||
      !plist.includes('<key>Disabled</key><true/>') || !plist.includes('<key>RunAtLoad</key><false/>') ||
      !plist.includes('<key>KeepAlive</key><false/>') || !plist.includes('<key>AbandonProcessGroup</key><false/>')) {
    throw new Error('package plist must have fixed --serve arguments and remain disabled')
  }
  if (clientBundle) {
    manifest.client = await macosClientPin(clientBundle)
    const activationAllowed = assertCandidateBuild(mode, admission.sourceCommit, await macosCandidateMetadata(clientBundle), admission.nativeBuild, manifest.helper.sha256, admission.appBuild, manifest.client)
    // Only this final, newly bound package gains the finite capability. Prepared
    // payloads and authentication-only packages always remain activation=false.
    manifest.activationAllowed = activationAllowed
    files['client-inventory.json'] = await clientInventory(clientBundle)
    manifest.clientInventorySHA256 = sha256(files['client-inventory.json'])
    // App-only updates must be distinct even when the Core/helper bytes match.
    manifest.release = `${manifest.release}-c${manifest.clientInventorySHA256}`
    if (manifest.release.length > 120) throw new Error('App-bound helper release exceeds the fixed 120-character limit')
    const program = `/Library/PrivilegedHelperTools/${label}/versions/${manifest.release}/helper`
    files[`${label}.plist`] = Buffer.from(plist.replace(preparedArguments, `<key>ProgramArguments</key><array><string>${program}</string><string>--serve</string></array>`))
    files['manifest.json'] = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  }
  const root = join(destination, 'root')
  const scripts = join(destination, 'scripts')
  await mkdir(root, { mode: 0o755 })
  for (const shared of ['Library', ...(operation === 'fresh' ? ['Library/PrivilegedHelperTools'] : []), 'Library/Application Support', 'Library/Application Support/Clash Kuro']) {
    await mkdir(join(root, shared), { mode: 0o755 })
  }
  await mkdir(join(root, state), { mode: 0o700 })
  if (operation === 'upgrade') {
    await mkdir(join(root, state, 'Upgrade'), { mode: 0o700 })
    await mkdir(join(root, upgradePayload), { mode: 0o700 })
  } else await mkdir(join(root, tools), { mode: 0o755 })
  const inbox = operation === 'upgrade' ? `${upgradePayload}/Inbox` : `${state}/Inbox`
  await mkdir(join(root, inbox), { mode: 0o700 })
  await mkdir(scripts, { mode: 0o700 })
  if (clientBundle) {
    if (operation === 'fresh') await mkdir(join(root, 'Library/Application Support/Clash Kuro/Client'), { mode: 0o755 })
    const stagedClient = join(root, operation === 'upgrade' ? `${upgradePayload}/Client.app` : protectedClientBundle)
    await cp(clientBundle, stagedClient, { recursive: true, dereference: false, verbatimSymlinks: true, force: false, errorOnExist: true })
    if (JSON.stringify(await macosClientPin(stagedClient)) !== JSON.stringify(manifest.client)) throw new Error('staged client differs from approved build')
    if (sha256(await clientInventory(stagedClient)) !== manifest.clientInventorySHA256) throw new Error('staged client inventory changed')
  }
  if (operation === 'fresh') {
    await writeFile(join(root, tools, 'installer'), files.helper, { mode: 0o755, flag: 'wx' })
    await writeFile(join(root, 'Library/PrivilegedHelperTools/dev.kuro.tun-uninstall'), files.helper, { mode: 0o755, flag: 'wx' })
  }
  await writeFile(join(scripts, 'preflight-native'), files.helper, { mode: 0o755, flag: 'wx' })
  for (const name of Object.keys(files)) await writeFile(join(root, inbox, name), files[name], { mode: ['helper', 'mihomo'].includes(name) ? 0o755 : 0o600, flag: 'wx' })
  if (clientBundle) for (const name of ['manifest.json', 'client-inventory.json', `${label}.plist`]) await writeFile(join(scripts, name), files[name], { mode: 0o600, flag: 'wx' })
  const preinstall = '#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" ' + (operation === 'upgrade' ? '--begin-client-upgrade\n' : clientBundle ? '--begin-client-install\n' : '--preflight-install\n')
  const postinstall = operation === 'upgrade' ? '#!/bin/sh\nset -eu\nexec "${0%/*}/preflight-native" --complete-client-upgrade\n' : '#!/bin/sh\nset -eu\nexec "/Library/PrivilegedHelperTools/dev.kuro.tun/installer" --install\n'
  await writeFile(join(scripts, 'preinstall'), preinstall, { mode: 0o755, flag: 'wx' })
  await writeFile(join(scripts, 'postinstall'), postinstall, { mode: 0o755, flag: 'wx' })
  return { root, scripts, manifest }
}

export async function packageMacosHelper(target, mode = 'disabled', operation = 'fresh') {
  if (!modes.includes(mode)) throw new Error('Unknown helper package mode')
  if (!['fresh', 'upgrade'].includes(operation) || (operation === 'upgrade' && mode !== 'finite-session')) throw new Error('Upgrade packages require explicit finite-session mode')
  const withClient = mode !== 'disabled'
  if (process.platform !== 'darwin' || !targets.includes(target)) throw new Error('macOS packaging requires darwin-arm64 or darwin-x64')
  const arch = target.slice('darwin-'.length)
  const { version } = JSON.parse(await readFile(join(desktopRoot, 'package.json'), 'utf8'))
  const dist = join(desktopRoot, 'dist')
  await mkdir(dist, { recursive: true })
  const info = await lstat(dist)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error('unsafe package output directory')
  const sourceCommit = withClient ? execFileSync('git', ['rev-parse', 'HEAD'], { cwd: desktopRoot, encoding: 'utf8' }).trim() : undefined
  if (withClient && execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: resolve(desktopRoot, '../..'), encoding: 'utf8' }).trim()) throw new Error('Commit candidate implementation before packaging')
  const output = join(dist, withClient ? `kuro-tun-${mode === 'auth-only' ? 'auth-observation' : 'finite-session'}${operation === 'upgrade' ? '-upgrade' : ''}-${version}-${arch}-${sourceCommit.slice(0, 12)}.pkg` : `kuro-tun-helper-disabled-${version}-${arch}.pkg`)
  await absent(output)
  await absent(`${output}.json`)
  const temporary = await realpath(await mkdtemp(join(tmpdir(), 'kuro-helper-package-')))
  try {
    const candidateDirectory = join(dist, mode === 'finite-session' ? `electron-finite-session-candidate-${sourceCommit.slice(0, 12)}` : 'electron-runtime-candidate')
    const candidate = withClient ? join(candidateDirectory, arch === 'arm64' ? 'mac-arm64' : 'mac', 'Clash Kuro.app') : undefined
    const nativeBuild = JSON.parse(await readFile(join(desktopRoot, 'resources/mac', arch, 'kuro-tun-helper.build.json'), 'utf8'))
    const appBuild = mode === 'finite-session' ? JSON.parse(await sourceBytes(candidateDirectory, 'build.json')) : undefined
    const { root, scripts, manifest } = await stageMacosHelperPackage(join(desktopRoot, 'resources/mac', arch, 'helper-payload'), temporary, target, version, candidate,
      { mode, operation, sourceCommit, nativeBuild, appBuild })
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
    execFileSync('/usr/bin/pkgbuild', ['--root', root, '--component-plist', components, '--scripts', scripts, '--identifier', `${label}.${operation === 'upgrade' ? 'upgrade' : 'disabled'}`, '--version', version, '--install-location', '/', '--ownership', 'recommended', built], { stdio: 'inherit' })
    const metadata = {
      format: 1, target, version, release: manifest.release, operation, installerProtocol: manifest.installerProtocol ?? 1,
      ...(sourceCommit ? { sourceCommit, candidateMode: mode, productionActivation: manifest.activationAllowed,
        ...(mode === 'auth-only' ? { authEndpoint, experiment: 'authenticate-only', observationSeconds: 300, emergencyExitSeconds: 310 } : { appBuild }),
        buildParameters: { electronBuilder: `mac --dir --${arch}`, identity: '-', hardenedRuntime: true, sourceCommitInSealedASAR: true, nativeBuild } } : {}),
      disabled: true, serviceAutoStart: false, startAvailable: manifest.activationAllowed, realTunAccepted: false, clientAttestationComplete: false, rootCoreConfigurationValidated: false,
      ...(mode === 'finite-session' ? { userDataPolicy: 'Sealed finite-session builds use only appData/Clash Kuro TUN Candidate with private userData/sessionData/crash subdirectories and a fixed ownership marker. Candidate versions retain these test data; normal product profiles are not imported. No external user-data-dir argument is accepted. Uninstall does not delete ordinary-user candidate data.' } : {}),
      packageSHA256: sha256(await readFile(built)), helperSHA256: manifest.helper.sha256, coreSHA256: manifest.core.sha256,
      ...(manifest.client ? { client: manifest.client, clientInventorySHA256: manifest.clientInventorySHA256, clientInstallPath: `/${protectedClientBundle}`, clientRemoval: 'Protected install/upgrade receipts permit exact removal of the approved installed App and helper only; modified or unknown content is preserved.' } : {}),
      ...(operation === 'upgrade' ? { payloadInstallPath: `/${upgradePayload}`, recoveryCommand: '/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall --recover-client-upgrade', upgradeRecovery: 'Failure preserves the transaction. Explicit recovery rolls back before finalizing, then completes forward; no automatic rollback, uninstall, service start or network operation.' } : {}),
      limitation: operation === 'upgrade' ? 'Upgrade only: requires an existing distinct protocol-2 release with exact protected off proof; legacy/partial/unknown installs are refused. Package scripts stage only the fixed Upgrade/Payload, and native transaction admission governs replacement. Real upgrade/rollback and TUN acceptance remain unverified.' : mode === 'finite-session'
        ? 'Fresh install only; finite sessions require dynamic authentication and protected installation admission. Service remains disabled until explicitly operated. Runtime uninstall, network recovery and upgrades need their own real acceptance; this package is not a TUN test pass.'
        : 'Fresh disabled install only; existing/partial installations refused. Production activation is denied. No publisher identity or full root-install acceptance claimed.',
    }
    if (withClient && (execFileSync('git', ['rev-parse', 'HEAD'], { cwd: desktopRoot, encoding: 'utf8' }).trim() !== sourceCommit ||
      execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: resolve(desktopRoot, '../..'), encoding: 'utf8' }).trim())) throw new Error('Candidate source changed during packaging')
    await copyFile(built, output, constants.COPYFILE_EXCL)
    await writeFile(`${output}.json`, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o644, flag: 'wx' })
    console.log(`${mode} helper package: ${output}; metadata: ${output}.json (not installed)`)
    return output
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const { target, mode, operation } = parsePackageArguments(process.argv.slice(2))
    packageMacosHelper(target, mode, operation).catch((error) => { console.error(error.message); process.exitCode = 1 })
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}
