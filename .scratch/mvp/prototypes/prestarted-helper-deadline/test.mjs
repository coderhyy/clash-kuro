import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url)), repo = resolve(root, '../../../..')
const electron = join(repo, 'apps/desktop/node_modules/electron/dist/electron.exe')
if (!existsSync(electron)) throw new Error('Missing pinned Electron runtime; run node apps/desktop/node_modules/electron/install.js before this fixture')
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const read = file => existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null
if (process.argv[2] === '--child') {
  const name = process.argv[3], dir = process.argv[4]
  const child = spawn(electron, [join(root, 'main.cjs'), `--probe-case=${name}`, `--probe-dir=${dir}`],
    { windowsHide: true, stdio: 'ignore' })
  const exit = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => resolve(code)) })
  // This root stays alive when Electron exits; only the EXTERNAL watchdog owns the Job.
  const code = await exit
  writeFileSync(join(dir, 'host.json'), JSON.stringify({ electronExitCode: code, electronExitedAt: Date.now() }))
  if (code !== 0) throw new Error(`Electron exit ${code}`)
  while (!existsSync(join(dir, 'helper.json'))) await delay(20)
  process.exitCode = 0
} else {
  const negative = process.argv.includes('--watchdog-negative-control')
  const only = process.argv.find(x => x.startsWith('--case='))?.slice(7)
  const names = ['normal', 'electron-stall', 'electron-exit', 'repeat', 'ipc-before', 'ipc-after',
    'operation-hang', 'late-operation', 'coordinator-hang', 'core-hang', 'window-stall',
    'query-plain', 'query-aware', 'query-handler-hang', 'operation-error']
  if (only && !names.includes(only)) throw new Error('Unknown case')
  const cases = negative ? ['watchdog-negative', 'electron-hang-negative'] : only ? [only] : names
  const run = join(root, 'out/runs', `${Date.now()}${negative ? '-negative' : ''}`)
  mkdirSync(run, { recursive: true })
  const rows = []
  const quote = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
  for (const name of cases) {
    const dir = join(run, name); mkdirSync(dir, { recursive: true })
    const env = { ...process.env, PATH: `${process.env.SystemRoot}\\System32;${process.env.SystemRoot}` }
    delete env.ELECTRON_RUN_AS_NODE; delete env.NODE_OPTIONS
    const command = [process.execPath, fileURLToPath(import.meta.url), '--child', name, dir].map(quote).join(' ')
    const watch = spawn(join(root, 'out/watchdog.exe'), [negative ? '5000' : '10000',
      join(dir, 'supervisor.json'), process.execPath, command], { windowsHide: true, env, stdio: 'pipe' })
    let output = '', outerKilled = false
    watch.stdout.on('data', data => { output = (output + data).slice(-8000) })
    watch.stderr.on('data', data => { output = (output + data).slice(-8000) })
    const guard = setTimeout(() => { outerKilled = true; watch.kill('SIGKILL') }, 16000)
    const code = await new Promise((resolve, reject) => { watch.once('error', reject); watch.once('close', resolve) })
    clearTimeout(guard)
    const supervisor = read(join(dir, 'supervisor.json'))
    const helper = read(join(dir, 'helper.json')), carrier = read(join(dir, 'electron.json'))
    let error
    try {
      assert.equal(outerKilled, false)
      assert.equal(code, 0, 'Supervised root failed; inspect output and Job report (rescue also fails acceptance)')
      assert.equal(supervisor.watchdogKilled, false)
      assert.equal(supervisor.lingeringChildren, false)
      assert.equal(supervisor.remaining, 0)
      assert.equal(carrier.electron, '45.1.0')
      assert.equal(helper.pid, carrier.helperPid)
      assert.notEqual(helper.corePid, helper.pid)
      assert(supervisor.observedPids.includes(helper.pid), 'Detached helper escaped test containment')
      assert(supervisor.observedPids.includes(helper.corePid), 'Fake Core escaped test containment')
      assert.equal(helper.stops, 1)
      assert.equal(helper.windowTriggers, name === 'query-aware' ? 2 : name === 'window-stall' || name.startsWith('query-') ? 1 : 0)
      assert.equal(helper.nestedQueries, name === 'query-aware' ? 1 : 0)
      if (name === 'query-aware' || name === 'query-handler-hang') assert.equal(helper.notificationInWait, 1)
      assert.equal(helper.deadlineMs, 1500)
      assert.equal(helper.coreGone, true)
      assert(helper.stopMs >= helper.decisionMs)
      assert(helper.endMs < 2350, 'Observed policy exit work overrun (not a hard guarantee)')
      const uncertain = ['operation-hang', 'late-operation', 'coordinator-hang', 'repeat', 'query-plain', 'query-handler-hang', 'operation-error'].includes(name)
      assert.equal(helper.decision, name === 'operation-error' ? 'failed' : uncertain ? 'timeout' : 'cleared')
      assert.equal(helper.operationError, name === 'operation-error' ? 2 : 0)
      assert.equal(helper.operations, name === 'coordinator-hang' ? 0 : 1)
      assert.equal(helper.selfForced, uncertain)
      assert.equal(helper.coreForced, name === 'core-hang')
      assert.equal(helper.coreExit, name === 'core-hang' ? 41 : 0)
      if (uncertain && name !== 'operation-error') assert(helper.decisionMs >= 1490 && helper.decisionMs < 1750)
      if (name === 'repeat') {
        assert.equal(helper.triggers, 8)
        const first = carrier.events.find(x => x.event === 'triggered').at
        assert(carrier.events.find(x => x.event === 'repeat-sent').at - first >= 1000)
        assert(helper.reportEpochMs - first < 1850, 'Repeat reset the original budget')
      }
      if (name.startsWith('ipc-')) assert.equal(helper.eof, 1)
      if (name !== 'electron-exit') assert.equal(carrier.helperExit.code, uncertain ? 42 : 0)
      if (name === 'electron-exit') {
        assert(carrier.events.some(x => x.event === 'early-exit'))
        assert(helper.reportEpochMs > read(join(dir, 'host.json')).electronExitedAt)
      }
      if (name === 'electron-stall' || name === 'window-stall') {
        const began = carrier.events.find(x => x.event === 'stall-start').at
        const ended = carrier.events.find(x => x.event === 'stall-end').at
        assert(helper.reportEpochMs > began && helper.reportEpochMs < ended)
        if (name === 'window-stall') assert(helper.startEpochMs >= began)
      }
    } catch (caught) { error = caught.stack }
    const independentBeforeRescue = name === 'electron-hang-negative' &&
      helper?.decision === 'cleared' && helper.coreGone && helper.stops === 1 &&
      supervisor?.watchdogKilled && supervisor.rescueSnapshotValid &&
      supervisor.pidsBeforeRescue.includes(carrier?.pid) &&
      !supervisor.pidsBeforeRescue.includes(helper.pid) && !supervisor.pidsBeforeRescue.includes(helper.corePid)
    const row = { name, pass: !error, independentBeforeRescue, code, outerKilled, supervisor, helper, carrier, error, output }
    rows.push(row)
    console.log(`${row.pass ? 'PASS' : 'FAIL'} ${name}: decision=${helper?.decision} at=${helper?.decisionMs}ms coreForced=${helper?.coreForced} selfForced=${helper?.selfForced} watchdog=${supervisor?.watchdogKilled} remaining=${supervisor?.remaining}`)
    if (error && !negative) console.error(error)
  }
  const negativeControlsObserved = negative && rows.every(x =>
    !x.pass && !x.outerKilled && x.supervisor?.watchdogKilled && x.supervisor.remaining === 0 &&
    (x.name !== 'electron-hang-negative' || x.independentBeforeRescue))
  const report = { at: new Date().toISOString(), rows, accepted: rows.every(x => x.pass), negativeControlsObserved }
  writeFileSync(join(run, 'results.json'), JSON.stringify(report, null, 2))
  writeFileSync(join(root, `out/${negative ? 'negative' : 'latest'}.json`), JSON.stringify(report, null, 2))
  console.log(join(run, 'results.json'))
  if (negative) console.log(`Expected rescue evidence observed: ${negativeControlsObserved}; both cases still FAIL exit acceptance`)
  if (!report.accepted) process.exitCode = 1
}
