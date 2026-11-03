// Only fake proxy operations; real isolated Core. The watchdog is rescue, not success.
import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url)), pkg = join(root, 'out/session-package')
const scenario = process.argv.find(x => x.startsWith('--case='))?.slice(7) ?? 'normal'
assert(['normal', 'clear-hang', 'readback-hang'].includes(scenario))
const timedOut = scenario !== 'normal'
const dir = join(root, 'out', `session-fake-${Date.now()}-${scenario}`)
mkdirSync(join(dir, 'core'), { recursive: true })
writeFileSync(join(dir, 'core/runtime.yaml'), 'mixed-port: 48967\nbind-address: 127.0.0.1\nallow-lan: false\nmode: direct\nlog-level: warning\nipv6: false\nprofile:\n  store-selected: false\nrules:\n  - MATCH,DIRECT\n')
const quote = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
const exe = join(pkg, 'runtime/electron.exe')
const watchdog = join(root, '../prestarted-helper-deadline/out/watchdog.exe')
const args = [exe, join(pkg, 'session-main.cjs'), `--session-dir=${dir}`, '--fixture-close']
const env = { ...process.env }
delete env.ELECTRON_RUN_AS_NODE; delete env.NODE_OPTIONS
const child = spawn(watchdog, ['12000', join(dir, 'watchdog.json'), exe, args.map(quote).join(' ')],
  { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
let output = '', rescue = false
child.stdout.on('data', data => { output += data })
child.stderr.on('data', data => { output += data })
const timer = setTimeout(() => { rescue = true; child.kill() }, 18000)
const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve) })
clearTimeout(timer)
writeFileSync(join(dir, 'output.txt'), output)
assert.equal(rescue, false, 'Outer rescue is failure')
assert.equal(code, timedOut ? 1 : 0, `Unexpected carrier result: ${dir}`)
const read = file => JSON.parse(readFileSync(join(dir, file), 'utf8'))
const watch = read('watchdog.json'), carrier = read('carrier.json'), report = read('helper-report.json')
assert.equal(watch.watchdogKilled, false)
assert.equal(watch.lingeringChildren, false)
assert.equal(watch.remaining, 0)
assert.equal(carrier.fixture, true)
assert.equal(carrier.ready, true)
assert.equal(watch.rootExitCode, timedOut ? 2 : 0)
assert.equal(carrier.helperExit.code, timedOut ? 42 : 0)
assert.equal(report.pid, carrier.helperPid)
assert.equal(report.decision, timedOut ? 'timeout' : 'cleared')
assert.equal(report.selfForced, timedOut)
assert.equal(report.cleanupWithinBudget, !timedOut)
assert.equal(report.fakeProxy, true)
assert.equal(report.runOnceManaged, false)
assert.equal(report.querySession, 0)
assert.equal(report.endSession, 0)
assert.equal(report.firstTriggerSource, 'ipc-close')
assert.equal(report.operations, 1)
assert.equal(report.stops, 1)
assert.equal(report.deadlineMs, 1500)
assert.equal(report.coreGone, true)
assert(report.stopMs >= report.decisionMs)
if (!timedOut) assert(report.coreStopRequestEpochMs >= report.readbackEndEpochMs)
assert(watch.observedPids.includes(report.pid))
// Real Core may be shorter lived than the watchdog's sampling interval.
assert(report.corePid > 0 && report.corePid !== report.pid)
assert.equal(carrier.events.some(x => x.event === 'query-session-end' || x.event === 'session-end'), false)
execFileSync(join(pkg, 'bin/probe.exe'), ['self-test'], { timeout: 10000, windowsHide: true })
console.log(`PASS ${scenario} policy: ${report.decision}, no external rescue; fake proxy + real Core, NOT OS session validation: ${dir}`)
