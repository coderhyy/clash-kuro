// Build-time identity only. The native installer repeats seal, protection and hash checks.
import { execFileSync, spawnSync } from 'node:child_process'
import { lstat, readFile, readdir, readlink, realpath } from 'node:fs/promises'
import { join, resolve, sep } from 'node:path'
import { createRequire } from 'node:module'
import { sha256 } from './fetch-core.mjs'

const require = createRequire(import.meta.url)
const { verifyMacosApp } = require('./verify-macos-app.cjs')
export const protectedClientBundle = 'Library/Application Support/Clash Kuro/Client/Clash Kuro.app'

export async function inspectClientTree(bundle) {
  const root = resolve(bundle)
  if (await realpath(root) !== root) throw new Error('client bundle must have a canonical build path')
  let remaining = 100000
  async function visit(path) {
    if (--remaining < 0) throw new Error('client resource limit exceeded')
    const info = await lstat(path)
    if (info.isSymbolicLink()) {
      const frameworks = join(root, 'Contents/Frameworks') + sep
      const link = await readlink(path)
      if (!path.startsWith(frameworks) || link.startsWith('/') || !(await realpath(path)).startsWith(frameworks)) throw new Error('client Framework link escapes the bundle')
    } else {
      if (info.mode & 0o6022) throw new Error(`writable client resource: ${path}`)
      if (info.isDirectory()) for (const name of await readdir(path)) await visit(join(path, name))
      else if (!info.isFile() || info.nlink !== 1) throw new Error(`unsupported client resource: ${path}`)
    }
  }
  await visit(root)
}

export async function macosClientPin(bundle) {
  await inspectClientTree(bundle)
  await verifyMacosApp(bundle)
  const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(bundle, 'Contents/Info.plist')], { encoding: 'utf8' }))
  if (info.CFBundleIdentifier !== 'dev.kuro.desktop' || info.CFBundleExecutable !== 'Clash Kuro') throw new Error('unexpected client identity')
  const signature = spawnSync('/usr/bin/codesign', ['--display', '--verbose=4', bundle], { encoding: 'utf8' })
  if (signature.status !== 0 || !/flags=.*\bruntime\b/.test(signature.stderr)) throw new Error('client must have hardened runtime')
  const cdhash = signature.stderr.match(/^CDHash=([a-f0-9]{40})$/m)?.[1]
  if (!cdhash) throw new Error('missing exact client CDHash')
  const pin = { format: 2, cdhash,
    executableSHA256: sha256(await readFile(join(bundle, 'Contents/MacOS/Clash Kuro'))),
    infoSHA256: sha256(await readFile(join(bundle, 'Contents/Info.plist'))),
    asarSHA256: sha256(await readFile(join(bundle, 'Contents/Resources/app.asar'))) }
  await inspectClientTree(bundle)
  return pin
}

export async function clientInventory(bundle) {
  await inspectClientTree(bundle)
  const inventory = { format: 1, directories: [], files: [], links: [] }
  async function visit(relative) {
    const path = join(bundle, relative)
    const info = await lstat(path)
    if (info.isSymbolicLink()) inventory.links.push({ path: relative, target: await readlink(path) })
    else if (info.isDirectory()) {
      inventory.directories.push({ path: relative, mode: info.mode & 0o777 })
      for (const name of (await readdir(path)).sort()) await visit(relative ? `${relative}/${name}` : name)
    } else inventory.files.push({ path: relative, mode: info.mode & 0o777, sha256: sha256(await readFile(path)) })
  }
  await visit('')
  await inspectClientTree(bundle)
  return Buffer.from(`${JSON.stringify(inventory)}\n`)
}

// Build admission only: metadata is sealed in the actual ASAR, not a sidecar flag.
export function assertMacosCandidateMode(metadata, mode, sourceCommit) {
  if (!['auth-only', 'finite-session'].includes(mode) || !/^[a-f0-9]{40}$/.test(sourceCommit) ||
      metadata?.kuroSourceCommit !== sourceCommit) throw new Error('Sealed App must match the exact candidate mode and source commit')
  if (mode === 'auth-only') {
    if (metadata.kuroAuthObservationOnly !== true || (metadata.kuroCandidateMode !== undefined && metadata.kuroCandidateMode !== mode)) throw new Error('Authentication candidate must forbid normal product launch')
  } else if (metadata.kuroCandidateMode !== mode || metadata.kuroAuthObservationOnly !== false) {
    throw new Error('Finite-session candidate must be a newly built normal App, not an authentication-only App')
  }
}

export async function macosCandidateMetadata(bundle) {
  const builder = createRequire(require.resolve('electron-builder'))
  const packager = createRequire(builder.resolve('app-builder-lib'))
  return JSON.parse(packager('@electron/asar').extractFile(join(bundle, 'Contents/Resources/app.asar'), 'package.json'))
}
