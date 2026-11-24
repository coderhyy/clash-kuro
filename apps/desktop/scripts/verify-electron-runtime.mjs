// Ordinary-user GUI candidate test. Every launch is capability-lowered and owns
// fresh private data; no real Platform/Core/helper/network writer is constructed.
import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { createConnection, createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export function assertIsolatedReport(report, directory) {
  assert.equal(report.ok, true)
  assert.equal(report.directory, directory)
  assert.equal(report.userData, join(directory, 'userData'))
  assert.equal(report.sessionData, join(directory, 'sessionData'))
  for (const flag of ['realPlatformCreated', 'realCoreStarted', 'realNetworkUsed']) assert.equal(report[flag], false, flag)
  assert.equal(report.ui.isolated, true)
  assert.equal(report.ui.core.ok, false)
  assert.equal(report.ui.tun.ok, false)
  assert.equal(report.ui.login.ok, false)
  assert.equal(report.ui.exported.ok, true)
  assert.equal(report.ui.imported.ok, true)
  assert.ok(report.ui.rootChildren > 0 && report.ui.cssLoaded)
  assert.ok(report.denied.includes('Core start') && report.denied.includes('System Proxy') && report.denied.includes('network fetch'))
}

export async function verifyElectronRuntime(bundle) {
  if (process.platform !== 'darwin' || process.getuid() === 0) throw new Error('Ordinary macOS user required')
  const require = createRequire(import.meta.url)
  await require('./verify-macos-app.cjs').verifyMacosApp(bundle)
  const executable = join(bundle, 'Contents/MacOS/Clash Kuro')
  const evidence = await mkdtemp(join(await realpath(tmpdir()), 'kuro-runtime-evidence-'))
  await chmod(evidence, 0o700)
  const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('DYLD_') && !key.startsWith('__XPC_DYLD_') && !['NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_RENDERER_URL', 'KURO_SMOKE'].includes(key)))
  const runs = []
  async function launch(label, args = [], extraEnvironment = {}, port) {
    const directory = await mkdtemp(join(await realpath(tmpdir()), 'kuro-electron-runtime-'))
    await chmod(directory, 0o700)
    const child = spawn(executable, [`--kuro-runtime-verification=${directory}`, ...args], {
      env: { ...environment, ...extraEnvironment }, stdio: ['ignore', 'pipe', 'pipe', 'pipe', 'pipe']
    })
    let stdout = '', stderr = '', pipeResponse = '', tcpReachable = false, timedOut = false
    const sockets = new Set()
    child.stdout.on('data', bytes => { stdout = (stdout + bytes).slice(-65536) })
    child.stderr.on('data', bytes => { stderr = (stderr + bytes).slice(-65536) })
    child.stdio[4].on('data', bytes => { pipeResponse = (pipeResponse + bytes).slice(-65536) })
    child.stdio[3].on('error', () => {})
    child.stdio[4].on('error', () => {})
    const timer = setTimeout(() => { timedOut = true; child.kill('SIGTERM') }, 20000)
    const hardTimer = setTimeout(() => child.kill('SIGKILL'), 23000)
    const probe = setInterval(() => {
      if (port) {
        const socket = createConnection({ host: '127.0.0.1', port }); sockets.add(socket)
        socket.setTimeout(50, () => socket.destroy())
        socket.on('connect', () => { tcpReachable = true; socket.destroy() })
        socket.on('error', () => {})
        socket.on('close', () => sockets.delete(socket))
      }
      if (args.includes('--remote-debugging-pipe')) child.stdio[3].write('{"id":1,"method":"Browser.getVersion"}\0', () => {})
    }, 5)
    let code, signal
    try { [code, signal] = await new Promise((accept, reject) => { child.once('error', reject); child.once('close', (code, signal) => accept([code, signal])) }) }
    finally { clearTimeout(timer); clearTimeout(hardTimer); clearInterval(probe); for (const socket of sockets) socket.destroy() }
    let report
    try { report = JSON.parse(await readFile(join(directory, 'result.json'), 'utf8')) } catch { /* refused launches do not run verification */ }
    const result = { label, directory, args, code, signal, timedOut, stdout, stderr, tcpReachable, pipeResponse, report }
    runs.push(result)
    await writeFile(join(evidence, 'runs.json'), JSON.stringify(runs, null, 2), { mode: 0o600 })
    assert.equal(timedOut, false, `${label} timed out: ${stderr}`)
    return result
  }
  const normal = await launch('normal UI/IPC and in-memory Backup')
  assert.equal(normal.code, 0, normal.stderr)
  assertIsolatedReport(normal.report, normal.directory)
  const marker = join(evidence, 'external-marker.cjs')
  await writeFile(marker, 'require("node:fs").writeFileSync(process.env.KURO_ATTACK_MARKER,"external-code-ran")')
  const markerPath = join(evidence, 'attack-marker')
  for (const [label, env] of [
    ['RunAsNode ignored', { ELECTRON_RUN_AS_NODE: '1' }],
    ['NODE_OPTIONS require ignored', { NODE_OPTIONS: `--require=${marker}`, KURO_ATTACK_MARKER: markerPath }],
    ['packaged renderer URL ignored', { ELECTRON_RENDERER_URL: `file://${marker}` }]
  ]) {
    const result = await launch(label, [], env)
    assert.equal(result.code, 0, result.stderr)
    assertIsolatedReport(result.report, result.directory)
  }
  const dylib = join(evidence, 'attack.dylib')
  await writeFile(join(evidence, 'attack.c'), '#include <stdio.h>\n__attribute__((constructor)) static void injected(void){fputs("KURO_ELECTRON_DYLD_ATTACK_MARKER\\n",stderr);}\n')
  execFileSync('/usr/bin/clang', ['-dynamiclib', '-Wall', '-Wextra', '-Werror', join(evidence, 'attack.c'), '-o', dylib])
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', dylib], { stdio: 'pipe' })
  const injected = await launch('DYLD constructor rejected', [], { DYLD_INSERT_LIBRARIES: dylib })
  assert.equal(injected.code, 0, injected.stderr)
  assertIsolatedReport(injected.report, injected.directory)
  assert.doesNotMatch(injected.stderr, /KURO_ELECTRON_DYLD_ATTACK_MARKER/)
  const server = createServer(); await new Promise(accept => server.listen(0, '127.0.0.1', accept)); const port = server.address().port
  await new Promise(accept => server.close(accept))
  for (const args of [[`--remote-debugging-port=${port}`], ['--remote-debugging-pipe'], ['--inspect=0'], ['--inspect-brk=0'], ['--js-flags=--expose-gc'], ['--renderer-cmd-prefix=/usr/bin/false'], ['--gpu-launcher=/usr/bin/false'], ['--no-sandbox'], [marker]]) {
    const result = await launch(args[0].split('=')[0], args, {}, args[0].startsWith('--remote-debugging-port=') ? port : undefined)
    assert.equal(result.code, 64, result.stderr)
    assert.equal(result.report, undefined)
    assert.equal(result.tcpReachable, false, 'CDP TCP endpoint became reachable before rejection')
    assert.equal(result.pipeResponse, '', 'CDP pipe answered before rejection')
    assert.doesNotMatch(result.stderr, /DevTools listening|Debugger listening/)
  }
  await assert.rejects(readFile(markerPath), { code: 'ENOENT' })
  const hashes = {}
  for (const [key, path] of Object.entries({ executableSHA256: executable, infoSHA256: join(bundle, 'Contents/Info.plist'), asarSHA256: join(bundle, 'Contents/Resources/app.asar') })) hashes[key] = createHash('sha256').update(await readFile(path)).digest('hex')
  const result = { ok: true, bundle, evidence, ...hashes, tests: runs.length, limitation: 'Actual isolated Electron only; no real Core/helper/network capability verified. TCP polling is sampled, not kernel tracing.' }
  await writeFile(join(evidence, 'result.json'), JSON.stringify(result, null, 2), { mode: 0o600 })
  console.log(JSON.stringify(result, null, 2))
  return result
}
if (process.argv[1] === fileURLToPath(import.meta.url)) verifyElectronRuntime(resolve(process.argv[2])).catch(error => { console.error(error); process.exitCode = 1 })
