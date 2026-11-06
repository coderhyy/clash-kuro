// Runs after signing, without launching the App or changing system state.
const { execFileSync, spawnSync } = require('node:child_process')
const { createRequire } = require('node:module')
const { join } = require('node:path')
const { createHash } = require('node:crypto')
const { readdirSync, lstatSync, openSync, readSync, closeSync } = require('node:fs')
const assert = require('node:assert/strict')
const builderRequire = createRequire(require.resolve('electron-builder'))
const packagerRequire = createRequire(builderRequire.resolve('app-builder-lib'))
const { getCurrentFuseWire, FuseV1Options } = packagerRequire('@electron/fuses')

async function verifyMacosApp(bundle) {
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', bundle], { stdio: 'pipe' })
  const wire = await getCurrentFuseWire(bundle)
  for (const name of ['RunAsNode', 'EnableNodeOptionsEnvironmentVariable', 'EnableNodeCliInspectArguments']) {
    assert.equal(wire[FuseV1Options[name]], 48, `${name} must be disabled`)
  }
  for (const name of ['EnableEmbeddedAsarIntegrityValidation', 'OnlyLoadAppFromAsar', 'GrantFileProtocolExtraPrivileges']) {
    assert.equal(wire[FuseV1Options[name]], 49, `${name} must be enabled`)
  }
  const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(bundle, 'Contents/Info.plist')], { encoding: 'utf8' }))
  const asar = packagerRequire('@electron/asar')
  const asarPath = join(bundle, 'Contents/Resources/app.asar')
  const headerHash = createHash('sha256').update(asar.getRawHeader(asarPath).headerString).digest('hex')
  assert.equal(info.ElectronAsarIntegrity?.['Resources/app.asar']?.hash, headerHash, 'signed ASAR header hash must match actual bytes')
  const main = join(bundle, 'Contents/MacOS/Clash Kuro')
  const allowedEntitlements = ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.disable-library-validation']
  let machoCount = 0
  function verifyMachos(directory) {
    for (const entry of readdirSync(directory)) {
      const path = join(directory, entry)
      const info = lstatSync(path)
      if (info.isSymbolicLink()) continue // codesign --deep --strict verifies the sealed bundle's links.
      if (info.isDirectory()) { verifyMachos(path); continue }
      if (!info.isFile()) continue
      const descriptor = openSync(path, 'r'), magic = Buffer.alloc(4)
      try { readSync(descriptor, magic, 0, 4, 0) } finally { closeSync(descriptor) }
      if (!['cffaedfe', 'feedfacf', 'cafebabe', 'bebafeca'].includes(magic.toString('hex'))) continue
      machoCount++
      const displayed = spawnSync('/usr/bin/codesign', ['--display', '--verbose=4', path], { encoding: 'utf8' })
      assert.equal(displayed.status, 0, path)
      assert.match(displayed.stderr, /flags=0x[0-9a-f]+\([^\n]*runtime/, path)
      const xml = execFileSync('/usr/bin/codesign', ['--display', '--entitlements', '-', '--xml', path], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
      const entitlements = xml.trim() ? JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], { input: xml, encoding: 'utf8' })) : {}
      for (const [key, value] of Object.entries(entitlements)) {
        assert.ok(allowedEntitlements.includes(key), `Unexpected entitlement ${key}: ${path}`)
        assert.equal(value, true, `Unexpected entitlement value: ${path}`)
      }
      if (path === main) assert.deepEqual(Object.keys(entitlements).sort(), allowedEntitlements.toSorted())
    }
  }
  verifyMachos(join(bundle, 'Contents'))
  assert.ok(machoCount > 0)
  console.log('macOS App runtime/entitlements, seal, ASAR bytes and fuses verified (no launch; not privileged caller attestation)')
}

module.exports = async context => {
  if (context.electronPlatformName !== 'darwin') return
  await verifyMacosApp(join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`))
}
module.exports.verifyMacosApp = verifyMacosApp
if (require.main === module) verifyMacosApp(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1 })
