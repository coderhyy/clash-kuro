import { spawn } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const repo = resolve(root, '../../../..')
const target = process.argv.find(x => x.startsWith('--target='))?.split('=')[1] ?? 'dev'
const repeats = Number(process.argv.find(x => x.startsWith('--repeat='))?.split('=')[1] ?? 1)
const only = process.argv.find(x => x.startsWith('--case='))?.split('=')[1]
const negative = process.argv.includes('--watchdog-negative-control')
if (!['dev', 'packaged'].includes(target) || !Number.isInteger(repeats) || repeats < 1 || repeats > 3) throw new Error('Invalid test options')
const executable = target === 'dev' ? join(repo, 'apps/desktop/node_modules/electron/dist/electron.exe') :
  join(root, 'out/packaged/win-unpacked/kuro-deadline-prototype.exe')
const cases = negative ? ['watchdog-negative-control'] : only ? [only] : [
  'success', 'set-before-clear', 'clear-hang', 'set-hang', 'late-set', 'late-clear', 'lock-hang', 'log-hang',
  'plain-sync-message', 'aware-sync-message', 'aware-flood', 'foreign-reentry', 'foreign-js-stall', 'native-handler-stall']
const runDir = join(root, 'out/runs', `${Date.now()}-${target}${negative ? '-negative' : ''}`)
mkdirSync(runDir, { recursive: true })
const rows = []
function quote(value) { return '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"' }
for (let iteration = 1; iteration <= repeats; ++iteration) for (const name of cases) for (const mode of ['quit', 'exit']) {
  const dir = join(runDir, `${iteration}-${name}-${mode}`)
  mkdirSync(dir, { recursive: true })
  const reportFile = join(dir, 'carrier.json'), supervisorFile = join(dir, 'supervisor.json')
  const args = target === 'dev' ? [join(root, 'main.cjs')] : []
  args.push(`--probe-case=${name}`, `--probe-exit=${mode}`, `--probe-report=${reportFile}`, `--probe-data=${join(dir, 'profile')}`)
  const command = [executable, ...args].map(quote).join(' ')
  const environment = { ...process.env }
  delete environment.ELECTRON_RUN_AS_NODE
  delete environment.NODE_OPTIONS
  // Do not depend on the developer compiler's PATH for successful DLL loading.
  environment.PATH = `${process.env.SystemRoot}\\System32;${process.env.SystemRoot}`
  const runner = spawn(join(root, 'out/watchdog.exe'), [negative ? '4000' : '12000', supervisorFile, executable, command],
    { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], env: environment })
  let output = ''
  runner.stdout.on('data', d => { output = (output + d).slice(-16000) })
  runner.stderr.on('data', d => { output = (output + d).slice(-16000) })
  // If the supervisor itself gets stuck, kill that exact handle: closing its Job
  // kills only this launch's members. Never enumerate/kill by process name.
  let supervisorKilled = false
  const timer = setTimeout(() => { supervisorKilled = true; runner.kill('SIGKILL') }, 20000)
  const execution = await new Promise(resolve => {
    runner.once('error', error => resolve({ error: String(error) }))
    runner.once('close', (code, signal) => resolve({ code, signal }))
  })
  clearTimeout(timer)
  const carrier = existsSync(reportFile) ? JSON.parse(readFileSync(reportFile)) : null
  const supervisor = existsSync(supervisorFile) ? JSON.parse(readFileSync(supervisorFile)) : null
  const exitAfterReportMs = supervisor && carrier?.finalReportEpochMs ? supervisor.jobEmptyEpochMs - carrier.finalReportEpochMs : null
  const lifecycleOK = mode === 'quit' ? carrier?.lifecycle.includes('before-quit') && carrier?.lifecycle.includes('will-quit') : carrier?.lifecycle.length === 0
  const pass = execution.code === 0 && !supervisorKilled && carrier?.stage === 'assertions-complete' &&
    supervisor?.remaining === 0 && !supervisor.watchdogKilled && !supervisor.lingeringChildren &&
    exitAfterReportMs !== null && exitAfterReportMs < 1000 && lifecycleOK
  const row = { name, iteration, mode, pass, candidateAccepted: pass && carrier?.candidateAccepted,
    outcome: !pass ? 'test-or-exit-failure' : carrier.candidateAccepted ? 'validated-behavior' :
      name === 'plain-sync-message' ? 'baseline-limitation' : 'candidate-safety-failure',
    execution, supervisorKilled, exitAfterReportMs, supervisor, reportFile, carrier, output }
  rows.push(row)
  console.log(`${pass ? carrier.candidateAccepted ? 'PASS' : 'DIAGNOSTIC/NOT ACCEPTED' : 'FAIL'} ${target} ${name} ${mode}: wait=${carrier?.samples[0]?.wallMs?.toFixed(2)}ms exit=${exitAfterReportMs}ms remaining=${supervisor?.remaining} forced=${supervisor?.watchdogKilled}`)
  if (!pass) console.log(carrier?.error ?? output)
}
const report = { at: new Date().toISOString(), target, rows,
  mechanismChecksPassed: rows.every(x => x.pass), candidateAcceptedFor2B: !negative && !only &&
    rows.filter(x => x.name !== 'plain-sync-message').every(x => x.candidateAccepted) }
writeFileSync(join(runDir, 'results.json'), JSON.stringify(report, null, 2))
writeFileSync(join(root, 'out', `${target}${negative ? '-negative' : ''}-latest.json`), JSON.stringify(report, null, 2))
console.log(join(runDir, 'results.json'))
if (!report.mechanismChecksPassed) process.exitCode = 1
else if (!report.candidateAcceptedFor2B && !only) process.exitCode = 2 // Diagnosis completed, architecture gate failed.
