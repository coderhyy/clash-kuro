import assert from 'node:assert/strict'
import { fork } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { performance } from 'node:perf_hooks'

const root = dirname(fileURLToPath(import.meta.url))
const negativeControl = process.argv.includes('--watchdog-negative-control')
const repeat = Number(process.argv.find(arg => arg.startsWith('--repeat='))?.split('=')[1] ?? 1)
assert(Number.isInteger(repeat) && repeat >= 1 && repeat <= 10, 'repeat must be 1..10')
const names = negativeControl ? ['watchdog-negative-control'] : ['success', 'set-before-clear', 'queued-set', 'clear-hang', 'set-hang',
  'late-set', 'late-clear', 'lock-hang', 'log-hang', 'init-hang', 'partial-budget',
  'explicit-exit', 'early-timeout', 'env-natural', 'env-terminate', 'env-late-return']
const results = []
for (let iteration = 1; iteration <= repeat; iteration++) for (const name of names) {
  const started = performance.now()
  const child = fork(join(root, 'case.cjs'), [name], { silent: true, windowsHide: true })
  let killedByWatchdog = false, report, reportAt, output = ''
  const watchdog = setTimeout(() => {
    killedByWatchdog = true
    child.kill('SIGKILL')
  }, negativeControl ? 2000 : 8000)
  child.stdout.on('data', data => { output = (output + data).slice(-16000) })
  child.stderr.on('data', data => { output = (output + data).slice(-16000) })
  child.on('message', message => { report = message; reportAt = performance.now() })
  const result = await new Promise(resolve => {
    child.once('error', error => resolve({ error: String(error) }))
    child.once('close', (code, signal) => resolve({ code, signal }))
  })
  clearTimeout(watchdog)
  const row = { name, iteration, ...result, killedByWatchdog, processMs: performance.now() - started,
    exitAfterReportMs: reportAt === undefined ? null : performance.now() - reportAt, report, output }
  row.pass = result.code === 0 && !killedByWatchdog && report?.name === name && row.exitAfterReportMs < 1000
  results.push(row)
  console.log(`${row.pass ? 'PASS' : 'FAIL'} ${name}: process=${row.processMs.toFixed(1)}ms exit-after-report=${row.exitAfterReportMs?.toFixed(1)}ms watchdog=${killedByWatchdog}`)
  if (!row.pass) console.error(output)
}
const destination = join(root, 'out', negativeControl ? 'negative-control.json' : 'results.json')
writeFileSync(destination, JSON.stringify({ at: new Date().toISOString(), node: process.version, results }, null, 2))
console.log(destination)
assert(results.every(row => row.pass), 'Failed cases (watchdog kills are failures); see results.json')
