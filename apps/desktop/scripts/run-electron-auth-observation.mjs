// Run only after explicit authorization and installation of the pinned candidate.
// Ordinary-user clients only; this driver never installs, signals or starts a service.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createConnection } from 'node:net'
import { lstat, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { macosClientPin } from './macos-client-pin.mjs'
import { authEndpoint } from './prepare-electron-auth-negatives.mjs'

const installed = '/Library/Application Support/Clash Kuro/Client/Clash Kuro.app'
const endpoint = authEndpoint
export function assertExternalIdentityRejection(stdout) {
  const { nativeReply } = JSON.parse(stdout)
  assert.deepEqual(Object.keys(nativeReply ?? {}).sort(), ['error', 'ok', 'version'])
  assert.equal(nativeReply.version, 1)
  assert.equal(nativeReply.ok, false)
  // Protocol/transport failures do not establish that the native client policy ran.
  assert.ok([
    'dynamic peer code is not valid',
    'client hardening is insufficient',
    'client resources or exact approved identity are unavailable',
    'full client code seal is invalid'
  ].includes(nativeReply.error), 'External client must receive an explicit native identity rejection')
  return nativeReply
}
function selfCheckExternalIdentityRejection() {
  const reply = error => JSON.stringify({ nativeReply: { version: 1, ok: false, error } })
  assertExternalIdentityRejection(reply('dynamic peer code is not valid'))
  assertExternalIdentityRejection(reply('client resources or exact approved identity are unavailable'))
  for (const error of ['one bounded newline auth request required', 'auth observation accepts only version-1 authenticate', 'auth response timeout']) {
    assert.throws(() => assertExternalIdentityRejection(reply(error)))
  }
  assert.throws(() => assertExternalIdentityRejection(JSON.stringify({ nativeReply: { version: 1, ok: true, authenticated: true } })))
  console.log('External identity rejection self-check passed (no socket or system operations)')
}
async function refusedOperation(operation) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(endpoint)
    let bytes = Buffer.alloc(0)
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('observation request timeout')) }, 3000)
    socket.once('connect', () => socket.end(`${JSON.stringify({ version: 1, operation })}\n`))
    socket.on('data', chunk => { bytes = Buffer.concat([bytes, chunk]); if (bytes.length > 8192) socket.destroy(new Error('oversize reply')) })
    socket.once('error', error => { clearTimeout(timer); reject(error) })
    socket.once('end', () => { clearTimeout(timer); try { const value = JSON.parse(bytes.toString()); assert.equal(value.ok, false); assert.match(value.error, /only version-1 authenticate/); resolve(value) } catch (error) { reject(error) } })
    socket.once('close', () => { clearTimeout(timer); reject(new Error('observation socket closed')) })
  })
}
export async function runAuthObservation(preparedPath) {
  assert.equal(process.platform, 'darwin'); assert.notEqual(process.getuid(), 0)
  const temporary = await realpath(tmpdir())
  preparedPath = await realpath(preparedPath)
  const prepared = JSON.parse(await readFile(preparedPath, 'utf8'))
  assert.equal(dirname(preparedPath), prepared.directory)
  assert.equal(dirname(prepared.directory), temporary)
  assert.match(prepared.directory.slice(temporary.length + 1), /^kuro-electron-auth-negatives-[A-Za-z0-9_-]+$/)
  const owner = await lstat(prepared.directory)
  assert.equal(owner.uid, process.getuid()); assert.equal(owner.mode & 0o077, 0)
  assert.deepEqual(prepared.copies, { resigned: join(prepared.directory, 'resigned.app'), 'asar-mutated': join(prepared.directory, 'asar-mutated.app') })
  assert.equal(prepared.nodeClient, join(prepared.directory, 'auth-external-node.mjs'))
  assert.deepEqual(await macosClientPin(installed), prepared.before, 'Installed candidate changed; stop experiment')
  assert.deepEqual(await macosClientPin(prepared.copies.resigned), prepared.resignedPin, 'Prepared negative changed; stop experiment')
  const evidence = await mkdtemp(join(temporary, 'kuro-auth-results-'))
  const results = []
  await writeFile(join(evidence, 'prepared.json'), JSON.stringify(prepared, null, 2), { mode: 0o600 })
  async function appCase(label, bundle, expected) {
    const directory = await mkdtemp(join(temporary, 'kuro-electron-runtime-'))
    const run = spawnSync(join(bundle, 'Contents/MacOS/Clash Kuro'), [`--kuro-auth-verification=${directory}`], {
      env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, LANG: 'en_US.UTF-8' },
      encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024
    })
    const result = { label, directory, code: run.status, signal: run.signal, stdout: run.stdout, stderr: run.stderr, error: run.error?.message }
    await writeFile(join(evidence, `${label}-launch.json`), JSON.stringify(result, null, 2), { mode: 0o600 })
    assert.ok(!run.error && !run.signal, 'Client timeout/abnormal exit; stop and preserve evidence')
    const report = JSON.parse(await readFile(join(directory, 'result.json'), 'utf8'))
    await writeFile(join(evidence, `${label}-result.json`), JSON.stringify(report, null, 2), { mode: 0o600 })
    assert.equal(report.authenticated, expected)
    assert.equal(run.status, expected ? 0 : 1)
    if (!expected) { assert.equal(report.nativeRejected, true); assert.match(report.error, /identity|resources|seal|hardening|signature|client/i) }
    results.push({ ...result, report })
  }
  console.log(`Evidence: ${evidence}`)
  await appCase('installed', installed, true)
  await appCase('resigned', prepared.copies.resigned, false)
  const external = spawnSync(process.execPath, [prepared.nodeClient], { encoding: 'utf8', timeout: 5000, maxBuffer: 8192 })
  await writeFile(join(evidence, 'external.json'), JSON.stringify({ status: external.status, signal: external.signal, stdout: external.stdout, stderr: external.stderr, error: external.error?.message }, null, 2), { mode: 0o600 })
  assert.equal(external.status, 0, 'External client must receive explicit native identity rejection')
  assertExternalIdentityRejection(external.stdout)
  const denied = []
  for (const operation of ['start', 'open', 'stop', 'recover', 'exec']) denied.push({ operation, reply: await refusedOperation(operation) })
  // The invalid-seal copy is never executed; this is an OS/seal negative, not a native RPC result.
  const seal = spawnSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', prepared.copies['asar-mutated']], { encoding: 'utf8', timeout: 10000 })
  assert.ok(!seal.error && seal.status !== 0)
  const result = { results, denied, mutatedSeal: { status: seal.status, stderr: seal.stderr, launched: false }, installedPinUnchanged: await macosClientPin(installed) }
  assert.deepEqual(result.installedPinUnchanged, prepared.before)
  await writeFile(join(evidence, 'result.json'), JSON.stringify(result, null, 2), { mode: 0o600, flag: 'wx' })
  console.log(`Observation passed; service exit and exact uninstall still required. ${evidence}`)
  return evidence
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--self-test') selfCheckExternalIdentityRejection()
  else runAuthObservation(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1 })
}
