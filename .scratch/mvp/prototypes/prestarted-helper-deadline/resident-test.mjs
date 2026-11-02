import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const out = process.env.KURO_RESIDENT_TEST_OUT ?? join(root, 'out')
const { residentClient } = createRequire(import.meta.url)(join(out, 'client.cjs'))
const { recoverResident } = createRequire(import.meta.url)(join(out, 'recovery.cjs'))
const { startResidentSession } = createRequire(import.meta.url)(join(out, 'session.cjs'))
if (process.argv[2] === '--child') {
  const [mode, dir] = process.argv.slice(3)
  const recoveryEvidence = []
  const exe = join(out, 'resident-fake.exe'), log = join(dir, 'helper.json')
  const args = ['serve', '--core', exe, '--data', dir, '--log', log,
    '--recovery', join(dir, 'recovery.bin'),
    '--expected-server', '127.0.0.1:7891']
  const launch = (path = join(dir, 'recovery.bin')) => spawn(exe,
    args.map((arg, i) => args[i - 1] === '--recovery' ? path : arg),
    { detached: true, windowsHide: true, stdio: 'pipe' })
  const recover = path => residentClient(spawn(exe, ['recover', '--recovery', path],
    { detached: true, windowsHide: true, stdio: 'pipe' }))
  const child = launch()
  const client = residentClient(child)
  let marker = ''
  let entered
  let coreStarted
  const coreStart = new Promise(resolve => { coreStarted = resolve })
  const setEntered = new Promise(resolve => { entered = resolve })
  child.stderr.on('data', data => {
    marker += data
    if (marker.includes('set-start\n') || marker.includes('register-start\n')) entered()
    if (marker.includes('fake-core-start\n')) coreStarted()
  })
  await client.ready
  if (mode === 'normal') {
    const contender = recover(join(dir, 'recovery.bin'))
    await assert.rejects(contender.ready)
    const denied = await contender.closed
    assert.equal(denied.code, 1)
    recoveryEvidence.push({ scenario: 'live-owner-denied', ...denied })
  }
  await coreStart
  if (mode !== 'diagnostics-stall') assert(client.diagnostics().includes('fake-core-start'))
  if (mode === 'diagnostics-stall') {
    child.stderr.pause()
    await new Promise(resolve => setTimeout(resolve, 50)) // Fill only the fixture's diagnostic pipes before close.
  }
  assert.equal(JSON.parse((await client.request(['get'])).stdout).flags, 1)
  const setting = client.request(['set', '--host', '127.0.0.1', '--port', '7891']).then(() => 'done', () => 'rejected')
  if (mode === 'late-set' || mode === 'set-hang' || mode === 'register-hang') {
    await setEntered
    client.close(); client.close()
    assert.equal(await setting, 'rejected')
  } else {
    assert.equal(await setting, 'done')
    assert.equal(JSON.parse((await client.request(['get'])).stdout).flags, 3)
    client.close()
  }
  await assert.rejects(client.request(['set']), /closing|exited/)
  const exit = await client.exited
  child.stderr.resume()
  const report = JSON.parse(readFileSync(log, 'utf8'))
  const acceptedReport = (await client.closed).report
  assert(acceptedReport)
  for (const [key, value] of Object.entries(acceptedReport)) assert.deepEqual(report[key], value)
  if (mode === 'diagnostics-stall') assert.equal(Buffer.byteLength(client.diagnostics()), 16 * 1024)
  const timeout = mode.endsWith('hang') || mode === 'replay-registration'
  assert.equal(statSync(join(dir, 'recovery.bin')).size, timeout ? 608 : 0)
  assert.equal(exit.code, timeout ? 42 : 0)
  assert.equal(report.command, 'shutdown')
  assert.equal(report.pid, child.pid)
  assert(Number.isFinite(Date.parse(report.timestamp)))
  assert(report.triggerMask & 2, 'IPC close trigger must be preserved')
  assert.equal(report.queryEvents, 0, 'No real or synthetic session events in this fixture')
  assert.equal(report.endEvents, 0)
  assert.equal(report.sessionFlags, 0)
  assert.equal(report.ok, !timeout)
  assert.equal(report.timedOut, timeout)
  assert.equal(report.coreGone, true)
  assert(Number.isInteger(report.corePid) && report.corePid > 0)
  assert.notEqual(report.corePid, child.pid)
  assert(report.durationMs < 2350)
  if (timeout) assert(report.durationMs >= 1490)
  if (mode === 'late-set') assert(report.durationMs >= 300)
  if (mode === 'diagnostics-stall') assert(report.durationMs >= 2000)
  if (timeout) {
    const retained = readFileSync(join(dir, 'recovery.bin'))
    const retry = residentClient(launch())
    await assert.rejects(retry.ready)
    assert.equal((await retry.closed).code, 1)
    assert.deepEqual(readFileSync(join(dir, 'recovery.bin')), retained)
    assert(!retry.diagnostics().includes('fake-core-start'))
    if (mode === 'replay-registration') {
      for (const scenario of ['recovery-clear-fail', 'recovery-register-hang']) {
        const path = join(dir, `${scenario}.bin`)
        writeFileSync(path, retained)
        const replay = recover(path)
        await assert.rejects(replay.ready)
        const outcome = await replay.closed
        const trace = replay.diagnostics()
        // Registration would block forever: replay must never self-register into the invoking RunOnce key.
        assert(!trace.includes('register-start\n'), `${scenario}: replay must not self-register; trace=${trace}`)
        const failed = scenario === 'recovery-clear-fail'
        assert.equal(outcome.code, failed ? 42 : 0)
        assert.equal(outcome.report?.ok, !failed)
        assert.equal(outcome.report?.timedOut, false)
        assert.equal(outcome.report?.coreGone, true)
        assert.equal(outcome.report?.corePid, 0)
        if (failed) {
          assert.deepEqual(readFileSync(path), retained)
          assert.equal(trace, 'clear-start\n')
          await assert.rejects(recoverResident(exe, path, join(dir, 'failed-replay.json')),
            /Recovery not verified; new writes forbidden/)
          assert.deepEqual(readFileSync(path), retained)
          const refused = residentClient(launch(path))
          await assert.rejects(refused.ready)
          assert.equal((await refused.closed).code, 1)
          assert(!refused.diagnostics().includes('fake-core-start'))
          assert.deepEqual(readFileSync(path), retained)
        } else {
          assert.equal(statSync(path).size, 0)
          assert.equal(trace, 'clear-start\nunregister\n')
        }
        assert(!trace.includes('fake-core-start'))
        assert(outcome.report.durationMs < 1800, `${scenario}: replay waited on registration`)
        recoveryEvidence.push({ scenario, trace, ...outcome })
      }
    }
    if (mode === 'clear-hang') {
      const hangPath = join(dir, 'recovery-hang.bin')
      writeFileSync(hangPath, retained)
      const hung = recover(hangPath)
      await assert.rejects(hung.ready)
      const outcome = await hung.closed
      assert.equal(outcome.code, 42)
      assert.equal(outcome.report?.timedOut, true)
      assert.equal(outcome.report?.ok, false)
      assert.deepEqual(readFileSync(hangPath), retained)
      recoveryEvidence.push({ scenario: 'recovery-timeout-retains-journal', ...outcome })
    }
    const recovery = recover(join(dir, 'recovery.bin'))
    await assert.rejects(recovery.ready) // Recovery never grants mutation readiness.
    const recovered = await recovery.closed
    assert.equal(recovered.code, 0)
    assert.equal(recovered.report?.ok, true)
    assert.equal(recovered.report?.corePid, 0)
    assert.equal(recovery.diagnostics(), 'clear-start\nunregister\n')
    assert.equal(statSync(join(dir, 'recovery.bin')).size, 0)
    assert(!recovery.diagnostics().includes('fake-core-start'))
    recoveryEvidence.push({ scenario: 'recovery-clear-resets-journal', ...recovered })
    writeFileSync(join(dir, 'recovery.bin'), retained)
    await recoverResident(exe, join(dir, 'recovery.bin'), join(dir, 'wrapper-recovery.json'))
    assert.equal(statSync(join(dir, 'recovery.bin')).size, 0)
    const replayReport = JSON.parse(readFileSync(join(dir, 'wrapper-recovery.json')))
    assert(replayReport.triggerMask & 64, 'Recovery trigger must be distinguishable from session cleanup')
    recoveryEvidence.push({ scenario: 'production-wrapper-recovery', report: replayReport })
  }
  writeFileSync(join(dir, 'result.json'), JSON.stringify({ mode, pid: child.pid, exit, report, recoveryEvidence }))
  if (mode === 'normal') {
    const session = await startResidentSession({ helper: exe, recoveryDirectory: join(dir, 'retained'),
      dataDir: dir, core: exe, server: '127.0.0.1:7891', log: join(dir, 'session.json') })
    assert.equal(JSON.parse((await session.request(['set', '--host', '127.0.0.1', '--port', '7891'])).stdout).ok, true)
    const first = session.close()
    assert.equal(session.close(), first)
    await assert.rejects(session.request(['set']))
    await first
    assert.equal(statSync(session.journal).size, 0)
    assert.notEqual(session.helper, exe)
    writeFileSync(join(dir, 'session-result.json'), JSON.stringify({ helper: session.helper, journalEmpty: true, verifiedExit: true }))
    const abort = new AbortController()
    const options = { helper: exe, recoveryDirectory: join(dir, 'retained'), dataDir: dir,
      core: exe, server: '127.0.0.1:7891', log: join(dir, 'abort.json'), signal: abort.signal }
    const aborted = await startResidentSession(options)
    abort.abort()
    await aborted.close()
    await assert.rejects(aborted.request(['set']))
    assert.equal((await aborted.exited).code, 0)
    await assert.rejects(startResidentSession(options), { name: 'AbortError' })
    writeFileSync(join(dir, 'abort-result.json'), JSON.stringify({ exitedNormally: true, lateWritesDenied: true, restartWithAbortedSignalDenied: true }))
  }
} else {
  const run = join(out, `resident-${Date.now()}`)
  mkdirSync(run, { recursive: true })
  const quote = s => '"' + s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
  const results = []
  const modes = ['normal', 'late-set', 'clear-hang', 'set-hang', 'diagnostics-stall', 'replay-registration', 'register-hang']
  const selected = process.argv.find(arg => arg.startsWith('--case='))?.slice(7)
  if (selected) assert(modes.includes(selected), `Unknown resident case: ${selected}`)
  for (const mode of modes.filter(mode => !selected || mode === selected)) {
    const dir = join(run, mode); mkdirSync(dir)
    const command = [process.execPath, fileURLToPath(import.meta.url), '--child', mode, dir].map(quote).join(' ')
    const watchdog = spawn(join(out, 'watchdog.exe'), ['8000', join(dir, 'supervisor.json'), process.execPath, command],
      { windowsHide: true, stdio: 'pipe' })
    let output = '', rescued = false
    watchdog.stdout.on('data', data => { output += data })
    watchdog.stderr.on('data', data => { output += data })
    const guard = setTimeout(() => { rescued = true; watchdog.kill('SIGKILL') }, 12000)
    const code = await new Promise((resolve, reject) => { watchdog.once('error', reject); watchdog.once('exit', resolve) })
    clearTimeout(guard)
    assert.equal(rescued, false)
    assert.equal(code, 0, output)
    const supervisor = JSON.parse(readFileSync(join(dir, 'supervisor.json')))
    assert.equal(supervisor.watchdogKilled, false)
    assert.equal(supervisor.lingeringChildren, false)
    assert.equal(supervisor.remaining, 0)
    const result = JSON.parse(readFileSync(join(dir, 'result.json')))
    assert(supervisor.observedPids.includes(result.pid))
    assert(supervisor.observedPids.includes(result.report.corePid))
    results.push({ ...result, supervisor })
    console.log(`PASS ${mode}: helper exit=${result.exit.code}, clear timeout=${result.report.timedOut}, no rescue/remaining processes`)
  }
  writeFileSync(join(run, 'results.json'), JSON.stringify(results, null, 2))
  console.log(run)
}
