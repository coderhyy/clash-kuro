// Runs after signing, without launching the App or changing system state.
const { execFileSync } = require('node:child_process')
const { createRequire } = require('node:module')
const { join } = require('node:path')
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
  for (const name of ['EnableEmbeddedAsarIntegrityValidation', 'OnlyLoadAppFromAsar']) {
    assert.equal(wire[FuseV1Options[name]], 49, `${name} must be enabled`)
  }
  const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(bundle, 'Contents/Info.plist')], { encoding: 'utf8' }))
  assert.ok(info.ElectronAsarIntegrity?.['Resources/app.asar']?.hash, 'missing signed ASAR integrity metadata')
  console.log('macOS App seal, ASAR metadata and fuses verified (no launch; not privileged caller attestation)')
}

module.exports = async context => {
  if (context.electronPlatformName !== 'darwin') return
  await verifyMacosApp(join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`))
}
module.exports.verifyMacosApp = verifyMacosApp
if (require.main === module) verifyMacosApp(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1 })
