// Ordinary-user offline negatives only. Never launches an App/Core or alters the input bundle.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { chmod, copyFile, cp, lstat, mkdir, mkdtemp, readFile, readdir, readlink, realpath, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { macosClientPin } from './macos-client-pin.mjs'

const require = createRequire(import.meta.url)
const { verifyMacosApp } = require('./verify-macos-app.cjs')
const builderRequire = createRequire(require.resolve('electron-builder'))
const packagerRequire = createRequire(builderRequire.resolve('app-builder-lib'))
const asar = packagerRequire('@electron/asar')
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

async function snapshot(bundle) {
  const entries = []
  async function walk(relative = '') {
    const path = join(bundle, relative), info = await lstat(path)
    const entry = { path: relative, mode: info.mode & 0o7777 }
    if (info.isSymbolicLink()) entry.link = await readlink(path)
    else if (info.isDirectory()) {
      entry.directory = true
      for (const child of (await readdir(path)).sort()) await walk(join(relative, child))
    } else {
      assert.ok(info.isFile() && info.nlink === 1, `Unexpected input resource: ${path}`)
      const hash = createHash('sha256')
      for await (const chunk of createReadStream(path)) hash.update(chunk)
      entry.sha256 = hash.digest('hex')
    }
    entries.push(entry)
  }
  await walk()
  return { pin: await macosClientPin(bundle), treeSHA256: sha256(JSON.stringify(entries)), entries: entries.length }
}

async function rejected(bundle) {
  const seal = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle], { encoding: 'utf8', timeout: 15000 })
  assert.equal(seal.error, undefined)
  assert.ok(Number.isInteger(seal.status) && seal.status !== 0, 'Tampered seal unexpectedly passed')
  let verifierError
  try { await verifyMacosApp(bundle) } catch (error) { verifierError = String(error) }
  assert.ok(verifierError, 'Tampered verifyMacosApp unexpectedly passed')
  return { codesignExit: seal.status, codesignStderr: seal.stderr, verifierError }
}

export async function verifyClientTampering(input) {
  if (process.platform !== 'darwin' || process.getuid() === 0) throw new Error('Ordinary macOS user required')
  const bundle = await realpath(resolve(input))
  const evidence = await mkdtemp(join(await realpath(tmpdir()), 'kuro-client-tampering-'))
  await chmod(evidence, 0o700)
  const result = { bundle, evidence, noAppLaunch: true, cases: [], before: await snapshot(bundle) }
  console.log(`Offline tampering evidence: ${evidence}`)
  try {
    async function withCopy(label, test) {
      const directory = join(evidence, label)
      await mkdir(directory, { mode: 0o700 })
      const copy = join(directory, 'Clash Kuro.app')
      // fs.cp makes independent regular files and preserves standard Framework links, never hardlinks.
      await cp(bundle, copy, { recursive: true, dereference: false, verbatimSymlinks: true, force: false, errorOnExist: true })
      assert.deepEqual(await macosClientPin(copy), result.before.pin, 'Independent copy must first match the frozen input')
      try { result.cases.push({ label, ...await test(copy) }) }
      finally { await rm(directory, { recursive: true, force: true }) }
    }
    await withCopy('asar-payload', async copy => {
      const path = join(copy, 'Contents/Resources/app.asar')
      const bytes = await readFile(path), source = asar.extractFile(path, 'out/main/index.js')
      const offset = bytes.indexOf(source)
      assert.ok(source.length > 0 && offset >= 0 && bytes.indexOf(source, offset + 1) === -1)
      const header = asar.getRawHeader(path).headerString
      bytes[offset + source.length - 1] ^= 1
      await writeFile(path, bytes)
      assert.equal(asar.getRawHeader(path).headerString, header, 'Test must alter payload without rewriting its signed integrity header')
      assert.notEqual(sha256(asar.extractFile(path, 'out/main/index.js')), sha256(source))
      return { headerUnchanged: true, originalPayloadSHA256: sha256(source), changedASARSHA256: sha256(bytes), ...await rejected(copy) }
    })
    const library = join(evidence, 'replacement.dylib')
    await writeFile(join(evidence, 'replacement.c'), 'int kuro_offline_replacement_marker(void) { return 42; }\n')
    execFileSync('/usr/bin/clang', ['-dynamiclib', '-Wall', '-Wextra', '-Werror', join(evidence, 'replacement.c'), '-o', library], { stdio: 'pipe' })
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', library], { stdio: 'pipe' })
    await withCopy('native-library', async copy => {
      const relative = 'Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libffmpeg.dylib'
      const path = join(copy, relative), info = await lstat(path)
      assert.ok(info.isFile() && !info.isSymbolicLink() && info.nlink === 1)
      await copyFile(library, path)
      return { resource: relative, replacementSHA256: sha256(await readFile(path)), ...await rejected(copy) }
    })
    const entitlements = join(evidence, 'entitlements.plist')
    await writeFile(entitlements, execFileSync('/usr/bin/codesign', ['--display', '--entitlements', '-', '--xml', join(bundle, 'Contents/MacOS/Clash Kuro')], { stdio: ['ignore', 'pipe', 'pipe'] }), { mode: 0o600 })
    await withCopy('resealed-copy', async copy => {
      // An added inert resource forces a different CodeResources seal while retaining Info/ASAR and entitlement policy.
      await writeFile(join(copy, 'Contents/Resources/offline-reseal-marker.txt'), 'Offline copy only; never executed.\n', { flag: 'wx' })
      execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--entitlements', entitlements, copy], { stdio: 'pipe' })
      execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', copy], { stdio: 'pipe' })
      await verifyMacosApp(copy)
      const pin = await macosClientPin(copy)
      assert.notEqual(pin.cdhash, result.before.pin.cdhash)
      assert.notEqual(pin.executableSHA256, result.before.pin.executableSHA256)
      assert.equal(pin.infoSHA256, result.before.pin.infoSHA256)
      assert.equal(pin.asarSHA256, result.before.pin.asarSHA256)
      assert.throws(() => assert.deepEqual(pin, result.before.pin), 'A valid reseal must fail the original exact pin comparison')
      return { codesignExit: 0, verifierPassed: true, originalPinMatches: false, pin }
    })
    result.ok = true
  } finally {
    result.after = await snapshot(bundle)
    result.originalUnchanged = JSON.stringify(result.before) === JSON.stringify(result.after)
    await writeFile(join(evidence, 'result.json'), JSON.stringify(result, null, 2), { mode: 0o600 })
    assert.equal(result.originalUnchanged, true, 'FROZEN INPUT CHANGED')
  }
  console.log(JSON.stringify(result, null, 2))
  return result
}
if (process.argv[1] === fileURLToPath(import.meta.url)) verifyClientTampering(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1 })
