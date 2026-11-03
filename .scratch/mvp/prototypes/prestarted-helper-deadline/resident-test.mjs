import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { realpath } from 'node:fs/promises'
import { createHash, randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const out = process.env.KURO_RESIDENT_TEST_OUT ?? join(root, 'out')
const { residentClient } = createRequire(import.meta.url)(join(out, 'client.cjs'))
const { recoverResident } = createRequire(import.meta.url)(join(out, 'recovery.cjs'))
const { startResidentSession } = createRequire(import.meta.url)(join(out, 'session.cjs'))
const helper = join(out, 'admission-fake.exe')
const headerBytes = 416, endpointBytes = 608
function shutdownReport(log) {
  const lines = readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line))
  const reports = lines.filter(line => line.command === 'shutdown')
  assert.equal(reports.length, 1, 'Exactly one final native report is required')
  assert.equal(reports[0].protocol, 3)
  return reports[0]
}
async function residentScenario(mode, dir, recoveryDirectory) {
  const recoveryEvidence = []
  const log = join(dir, 'helper.json'), journal = join(recoveryDirectory, 'recovery.bin')
  const retainedHelper = join(recoveryDirectory, `${createHash('sha256').update(readFileSync(helper)).digest('hex')}.exe`)
  const fixtureModes = { normal: '', 'late-set': 'set-slow', 'clear-hang': 'shutdown-clear-hung',
    'set-hang': 'set-hung', 'diagnostics-stall': 'diagnostics-stall', 'replay': 'shutdown-clear-hung',
    'reset-hang': 'shutdown-reset-hung', 'late-clear': 'delayed-supervisor', 'log-hang': 'shutdown-log-hung',
    'readback-fail': 'shutdown-readback-fail', 'readback-hang': 'shutdown-readback-hung',
    'core-fail': 'core-fail', 'core-hang': 'core-hung', 'core-late': 'core-late' }
  const options = (fixtureMode, server = '') => ({ detached: true, windowsHide: true, stdio: 'pipe',
    env: { ...process.env, KURO_ADMISSION_TEST_MODE: fixtureMode, KURO_ADMISSION_TEST_SERVER: server } })
  const launch = (fixtureMode = fixtureModes[mode], targetLog = log, server = '') => spawn(helper,
    ['start', '--core', helper, '--data', dir, '--log', targetLog], options(fixtureMode, server))
  const recover = (fixtureMode = '', targetLog = join(dir, 'replay.json')) => residentClient(spawn(retainedHelper,
    ['recover-admitted', '--log', targetLog], options(fixtureMode, '127.0.0.1:7891')))
  const child = launch()
  const client = residentClient(child)
  let marker = ''
  let entered
  let coreStarted
  const coreStart = new Promise(resolve => { coreStarted = resolve })
  const setEntered = new Promise(resolve => { entered = resolve })
  child.stderr.on('data', data => {
    marker += data
    if (/^set\n/m.test(marker)) entered()
    if (marker.includes('fake-core\n') || (mode === 'diagnostics-stall' && marker.includes('x'.repeat(1024)))) coreStarted()
  })
  if (mode.startsWith('core-')) {
    await assert.rejects(client.ready)
    const outcome = await client.closed, report = shutdownReport(log)
    assert.equal(outcome.code, 42)
    assert.equal(outcome.signal, null)
    assert(outcome.report)
    for (const [key, value] of Object.entries(outcome.report)) assert.deepEqual(report[key], value)
    assert.equal(report.ok, false)
    assert.equal(report.timedOut, mode !== 'core-fail')
    assert.equal(report.coreGone, mode !== 'core-hang')
    assert.equal(report.pid, child.pid)
    assert(Number.isInteger(report.corePid) && report.corePid >= 0)
    if (mode !== 'core-late') assert.equal(report.corePid, 0)
    assert(report.durationMs < 2350)
    assert(client.diagnostics().includes('core-create\n'))
    assert(!client.diagnostics().includes('fake-core\n'), 'Failed or late startup must not resume Core')
    assert.equal(statSync(journal).size, headerBytes)
    return { mode, pid: child.pid, exit: { code: outcome.code, signal: outcome.signal }, report, recoveryDirectory }
  }
  await client.ready
  if (mode === 'normal') {
    const contender = recover('', join(dir, 'contender.json'))
    await assert.rejects(contender.ready)
    const denied = await contender.closed
    assert.equal(denied.code, 1)
    recoveryEvidence.push({ scenario: 'live-owner-denied', ...denied })
  }
  await coreStart
  if (mode !== 'diagnostics-stall') assert(client.diagnostics().includes('fake-core\n'))
  if (mode === 'diagnostics-stall') {
    child.stderr.pause()
    await new Promise(resolve => setTimeout(resolve, 50)) // Fill only the fixture's diagnostic pipes before close.
  }
  assert.equal(JSON.parse((await client.request(['get'])).stdout).connections.find(connection => connection.name === null).flags, 1)
  const setting = client.request(['set', '--host', '127.0.0.1', '--port', '7891']).then(result => {
    assert.equal(JSON.parse(result.stdout).ok, true)
    return 'done'
  }, () => 'rejected')
  if (mode === 'late-set' || mode === 'set-hang') {
    await setEntered
    client.close(); client.close()
    assert.equal(await setting, 'rejected')
  } else {
    assert.equal(await setting, 'done')
    assert.equal(JSON.parse((await client.request(['get'])).stdout).connections.find(connection => connection.name === null).flags, 3)
    client.close()
  }
  await assert.rejects(client.request(['set']), /closing|exited/)
  const exit = await client.exited
  child.stderr.resume()
  const acceptedReport = (await client.closed).report
  assert.equal(exit.signal, null)
  if (mode === 'log-hang') {
    assert.equal(exit.code, 42, 'A stalled native log must terminate as failure')
    assert.equal(acceptedReport, null, 'Missing final evidence cannot prove cleanup')
    assert(!readFileSync(log, 'utf8').includes('"command":"shutdown"'))
    return { mode, pid: child.pid, exit, report: null, recoveryDirectory, diagnostics: client.diagnostics(),
      cleanupVerified: false }
  }
  const report = shutdownReport(log)
  assert(acceptedReport)
  for (const [key, value] of Object.entries(acceptedReport)) assert.deepEqual(report[key], value)
  if (mode === 'diagnostics-stall') assert.equal(Buffer.byteLength(client.diagnostics()), 16 * 1024)
  const timeout = mode.endsWith('hang') || mode === 'replay' || mode === 'late-clear'
  const failed = timeout || mode === 'readback-fail'
  if (mode === 'late-clear') {
    const trace = client.diagnostics()
    const evidence = { exit, report, journalBytes: statSync(journal).size, trace }
    writeFileSync(join(dir, 'late-clear-evidence.json'), JSON.stringify(evidence, null, 2))
    console.log(JSON.stringify({ scenario: mode, ...evidence }))
    assert(trace.includes('supervisor-delayed\n') && trace.includes('supervisor-resumed\n'))
    assert(trace.includes('clear-return\n'))
    assert(report.cleanupDurationMs >= 1500, 'Completion must be measured against the original cleanup budget')
  }
  assert.equal(statSync(journal).size, headerBytes + (failed ? endpointBytes : 0))
  assert.equal(exit.code, failed ? 42 : 0)
  assert.equal(report.command, 'shutdown')
  assert.equal(report.pid, child.pid)
  assert(Number.isFinite(Date.parse(report.timestamp)))
  assert(report.triggerMask & 2, 'IPC close trigger must be preserved')
  assert.equal(report.queryEvents, 0, 'No real or synthetic session events in this fixture')
  assert.equal(report.endEvents, 0)
  assert.equal(report.sessionFlags, 0)
  assert.equal(report.ok, !failed)
  assert.equal(report.timedOut, timeout)
  assert.equal(report.cleanupReadbackVerified, !failed || mode === 'reset-hang')
  if (!failed) {
    assert(report.cleanupReadback?.connections.length > 0, 'Success requires native readback evidence')
    assert.equal(report.cleanupReadback.ok, true)
    assert.equal(report.cleanupReadback.connections.find(connection => connection.name === null).flags, 1)
    assert(report.readbackCompletedMs <= report.coreStopRequestedMs, 'Readback must precede the Core stop request')
  }
  if (!timeout) assert(Number.isFinite(report.cleanupDurationMs) && report.cleanupDurationMs >= 0 && report.cleanupDurationMs < 1500)
  else if (mode !== 'late-clear') assert.equal(report.cleanupDurationMs, null)
  assert.equal(report.coreGone, true)
  assert(Number.isInteger(report.corePid) && report.corePid > 0)
  assert.notEqual(report.corePid, child.pid)
  assert(report.durationMs < 2350)
  if (timeout) assert(report.durationMs >= 1490)
  if (mode === 'late-set') assert(report.durationMs >= 300)
  if (mode === 'diagnostics-stall') assert(report.durationMs >= 2000)
  if (failed) {
    const retained = readFileSync(journal)
    // A new owner must replay pending endpoints before Core creation; failed replay still denies writes.
    const retry = residentClient(launch('clear-fail', join(dir, 'retry.json'), '127.0.0.1:7891'))
    await assert.rejects(retry.ready)
    assert.equal((await retry.closed).code, 42)
    assert.deepEqual(readFileSync(journal), retained)
    assert(!retry.diagnostics().includes('fake-core\n'))
    if (mode === 'replay') {
      for (const scenario of ['recovery-clear-fail', 'recovery-no-registration']) {
        writeFileSync(journal, retained)
        const failed = scenario === 'recovery-clear-fail'
        const replay = recover(failed ? 'clear-fail' : '', join(dir, `${scenario}.json`))
        await assert.rejects(replay.ready)
        const outcome = await replay.closed
        const trace = replay.diagnostics()
        // Registry calls terminate the private fixture with 90; current recovery must never register.
        assert(!/^register\n/m.test(trace), `${scenario}: replay must not self-register; trace=${trace}`)
        assert.equal(outcome.code, failed ? 42 : 0)
        assert.equal(outcome.report?.ok, !failed)
        assert.equal(outcome.report?.timedOut, false)
        assert.equal(outcome.report?.coreGone, true)
        assert.equal(outcome.report?.corePid, 0)
        if (failed) {
          assert.deepEqual(readFileSync(journal), retained)
          assert(trace.includes('clear-enter\n') && !trace.includes('clear-return\n'))
          process.env.KURO_ADMISSION_TEST_MODE = 'clear-fail'
          process.env.KURO_ADMISSION_TEST_SERVER = '127.0.0.1:7891'
          try {
            await assert.rejects(recoverResident(retainedHelper, join(dir, 'failed-replay.json')),
              /Recovery not verified; new writes forbidden/)
          } finally { process.env.KURO_ADMISSION_TEST_MODE = ''; process.env.KURO_ADMISSION_TEST_SERVER = '' }
          assert.deepEqual(readFileSync(journal), retained)
          const refused = residentClient(launch('clear-fail', join(dir, 'refused.json'), '127.0.0.1:7891'))
          await assert.rejects(refused.ready)
          assert.equal((await refused.closed).code, 42)
          assert(!refused.diagnostics().includes('fake-core\n'))
          assert.deepEqual(readFileSync(journal), retained)
        } else {
          assert.equal(statSync(journal).size, headerBytes)
          assert(trace.includes('clear-return\n') && trace.includes('readback\n'))
          assert.deepEqual(readFileSync(journal), retained.subarray(0, headerBytes))
        }
        assert(!trace.includes('fake-core\n'))
        assert(outcome.report.durationMs < 1800, `${scenario}: replay waited on registration`)
        recoveryEvidence.push({ scenario, trace, ...outcome })
      }
    }
    if (mode === 'clear-hang') {
      writeFileSync(journal, retained)
      const hung = recover('clear-hung', join(dir, 'recovery-hang.json'))
      await assert.rejects(hung.ready)
      const outcome = await hung.closed
      assert.equal(outcome.code, 42)
      assert.equal(outcome.report?.timedOut, true)
      assert.equal(outcome.report?.ok, false)
      assert.equal(outcome.report?.coreGone, true)
      assert.equal(outcome.report?.corePid, 0)
      assert(!/^register\n/m.test(hung.diagnostics()))
      assert(!hung.diagnostics().includes('fake-core\n'))
      assert.deepEqual(readFileSync(journal), retained)
      recoveryEvidence.push({ scenario: 'recovery-timeout-retains-journal', ...outcome })
    }
    writeFileSync(journal, retained)
    const recovery = recover()
    await assert.rejects(recovery.ready) // Recovery never grants mutation readiness.
    const recovered = await recovery.closed
    assert.equal(recovered.code, 0)
    assert.equal(recovered.report?.ok, true)
    assert.equal(recovered.report?.corePid, 0)
    assert(recovery.diagnostics().includes('clear-enter\n') && recovery.diagnostics().includes('clear-return\n'))
    assert(recovery.diagnostics().includes('readback\n'))
    assert(!/^register\n/m.test(recovery.diagnostics()))
    assert.deepEqual(readFileSync(journal), retained.subarray(0, headerBytes))
    assert(!recovery.diagnostics().includes('fake-core\n'))
    recoveryEvidence.push({ scenario: 'recovery-clear-resets-journal', ...recovered })
    writeFileSync(journal, retained)
    process.env.KURO_ADMISSION_TEST_SERVER = '127.0.0.1:7891'
    try { await recoverResident(retainedHelper, join(dir, 'wrapper-recovery.json')) }
    finally { process.env.KURO_ADMISSION_TEST_SERVER = '' }
    assert.deepEqual(readFileSync(journal), retained.subarray(0, headerBytes))
    const replayReport = shutdownReport(join(dir, 'wrapper-recovery.json'))
    assert(replayReport.triggerMask & 64, 'Recovery trigger must be distinguishable from session cleanup')
    recoveryEvidence.push({ scenario: 'production-wrapper-recovery', report: replayReport })
  }
  return { mode, pid: child.pid, exit, report, recoveryDirectory, recoveryEvidence }
}
async function wrapperScenario(mode, dir, recoveryDirectory) {
  const failed = mode === 'wrapper-cleanup-fail' || mode === 'wrapper-cleanup-hang'
  const timedOut = mode === 'wrapper-cleanup-hang'
  process.env.KURO_ADMISSION_TEST_MODE = timedOut ? 'shutdown-clear-hung' : failed ? 'shutdown-clear-fail' : ''
  const abort = new AbortController()
  const log = join(dir, 'session.json')
  const options = { helper, recoveryDirectory, dataDir: dir, core: helper,
    server: '127.0.0.1:7891', log, signal: abort.signal }
  const session = await startResidentSession(options)
  assert.notEqual(session.helper, helper)
  assert.equal(createHash('sha256').update(readFileSync(session.helper)).digest('hex'),
    createHash('sha256').update(readFileSync(helper)).digest('hex'))
  assert.equal(session.journal, join(recoveryDirectory, 'recovery.bin'))
  assert.equal(JSON.parse((await session.request(['set', '--host', '127.0.0.1', '--port', '7891'])).stdout).ok, true)
  if (mode === 'wrapper-abort') abort.abort()
  const closing = session.close()
  assert.equal(session.close(), closing)
  await assert.rejects(session.request(['set']))
  if (failed) await assert.rejects(closing, /Resident cleanup unverified/)
  else await closing
  const exit = await session.exited, report = shutdownReport(log)
  assert.equal(exit.code, failed ? 42 : 0, 'Wrapper rescue or deadline rejection must not count as native completion')
  assert.equal(exit.signal, null)
  assert.equal(report.ok, !failed)
  assert.equal(report.timedOut, timedOut)
  assert.equal(report.cleanupReadbackVerified, !failed)
  assert.equal(report.coreGone, true)
  assert(report.corePid > 0 && report.corePid !== report.pid)
  assert(report.durationMs < 2350)
  assert.equal(statSync(session.journal).size, headerBytes + (failed ? endpointBytes : 0))
  const retained = readFileSync(session.journal)
  if (mode === 'wrapper-abort') {
    await assert.rejects(startResidentSession(options), { name: 'AbortError' })
    assert.deepEqual(readFileSync(session.journal), retained)
  }
  return { mode, pid: report.pid, exit, report, recoveryDirectory, helper: session.helper }
}
if (process.argv[2] === '--child') {
  const [mode, dir] = process.argv.slice(3)
  const recoveryDirectory = await realpath(mkdtempSync(join(tmpdir(), 'kuro-admission-resident-')))
  process.env.KURO_ADMISSION_TEST_ROOT = recoveryDirectory
  process.env.KURO_ADMISSION_TEST_NAMESPACE = randomUUID()
  process.env.KURO_ADMISSION_TEST_MODE = ''
  process.env.KURO_ADMISSION_TEST_SERVER = ''
  const result = await (mode.startsWith('wrapper-') ? wrapperScenario : residentScenario)(mode, dir, recoveryDirectory)
  writeFileSync(join(dir, 'result.json'), JSON.stringify(result))
} else {
  const run = join(out, `resident-${Date.now()}`)
  mkdirSync(run, { recursive: true })
  const quote = s => '"' + s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
  const results = []
  // Retired: register-hang and recovery-register-hang; current residents forbid registry calls.
  const modes = ['normal', 'late-set', 'clear-hang', 'set-hang', 'diagnostics-stall', 'replay', 'reset-hang', 'late-clear',
    'readback-fail', 'readback-hang', 'log-hang', 'core-fail', 'core-hang', 'core-late',
    'wrapper-normal', 'wrapper-cleanup-fail', 'wrapper-cleanup-hang', 'wrapper-abort']
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
      .finally(() => clearTimeout(guard))
    assert.equal(rescued, false, 'Outer rescue is a failure')
    assert.equal(code, 0, output)
    const supervisor = JSON.parse(readFileSync(join(dir, 'supervisor.json')))
    assert.equal(supervisor.watchdogKilled, false)
    assert.equal(supervisor.lingeringChildren, false)
    assert.equal(supervisor.remaining, 0)
    const result = JSON.parse(readFileSync(join(dir, 'result.json')))
    assert(supervisor.observedPids.includes(result.pid))
    if (result.report?.corePid) assert(supervisor.observedPids.includes(result.report.corePid))
    else if (!result.report) {
      assert.equal(mode, 'log-hang')
      assert(supervisor.observedPids.length >= 3, 'The supervisor must observe the carrier, helper and fake Core')
    } else assert(mode.startsWith('core-'), 'A running session requires a positive observed Core PID')
    results.push({ ...result, supervisor })
    console.log(`PASS ${mode}: helper exit=${result.exit.code}, cleanup=${result.report?.ok ?? 'unverified (expected failure)'}, no rescue/remaining processes`)
  }
  writeFileSync(join(run, 'results.json'), JSON.stringify(results, null, 2))
  console.log(run)
}
