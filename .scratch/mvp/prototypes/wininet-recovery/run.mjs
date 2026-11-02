import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const exercise = process.argv.includes('--exercise')
const prior = process.argv.find(x => x.startsWith('--restore='))?.slice(10)
const dir = prior ? resolve(prior) : join(homedir(), 'kuro-sysproxy-backups', `wininet-${Date.now()}`)
mkdirSync(dir, { recursive: true })
// A crashed controller leaves this lock in place: never infer writer death from a missing JS process.
let writerGone = true
if (exercise || prior) {
  const base = join(homedir(), 'kuro-sysproxy-backups')
  mkdirSync(base, { recursive: true })
  const lock = join(base, 'writer.lock')
  const owner = JSON.stringify({ pid: process.pid, at: Date.now(), backup: dir })
  writeFileSync(lock, owner, { flag: 'wx' })
  process.on('exit', () => {
    if (writerGone && existsSync(lock) && readFileSync(lock, 'utf8') === owner) unlinkSync(lock)
  })
}
const snapshot = join(dir, 'lan-ras.bin'), endpoint = '127.0.0.1:48967'
const q = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
function supervised(label, args) {
  const report = join(dir, `${label}-${Date.now()}.supervisor.json`)
  const exe = join(root, 'out/probe.exe')
  let failure, stdout = ''
  const mutating = label === 'cycle' || label === 'restore'
  if (mutating) writerGone = false
  try {
    stdout = execFileSync(join(root, 'out/watchdog.exe'), ['10000', report, exe, [exe, ...args].map(q).join(' ')],
      { timeout: 16000, windowsHide: true, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  } catch (error) { failure = error; stdout = String(error.stdout ?? '') }
  writeFileSync(report.replace('.supervisor.json', '.stdout.jsonl'), stdout)
  // No restore may start unless the entire old writer Job is confirmed empty.
  if (!existsSync(report)) throw new Error(`STOP: missing process-exit evidence; do not restore. Backup: ${dir}`, { cause: failure })
  const data = JSON.parse(readFileSync(report, 'utf8'))
  assert.equal(data.remaining, 0, 'STOP: an old writer might still be alive; no restore')
  if (mutating) writerGone = true
  return { data, failure }
}
function must(label, args) {
  const result = supervised(label, args)
  if (result.failure || result.data.rootExitCode !== 0 || result.data.watchdogKilled || result.data.lingeringChildren)
    throw new Error(`${label} failed; retain backup ${dir}`, { cause: result.failure })
}
function competitors() {
  const output = execFileSync('powershell.exe', ['-NoProfile', '-Command',
    'Get-Process | Where-Object { $_.ProcessName -match "clash-verge|fiddler|Clash Kuro|mihomo|sing-box|v2ray|v2rayN" } | Select-Object Id,ProcessName | ConvertTo-Json -Compress'],
  { timeout: 10000, windowsHide: true, encoding: 'utf8' }).trim()
  if (output) throw new Error(`STOP: other proxy processes must exit before writes or restoration: ${output}`)
}
if (!prior) {
  execFileSync('reg.exe', ['export', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', join(dir, 'internet-settings.reg')],
    { timeout: 10000, windowsHide: true, stdio: 'pipe' })
  const runOnce = execFileSync('powershell.exe', ['-NoProfile', '-Command',
    'Get-ItemProperty -LiteralPath "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce" -ErrorAction SilentlyContinue | Select-Object ClashKuroSysProxyCleanup | ConvertTo-Json -Compress'],
  { timeout: 10000, windowsHide: true, encoding: 'utf8' })
  writeFileSync(join(dir, 'runonce-readonly.json'), runOnce || 'null')
  must('snapshot', ['snapshot', snapshot])
  must('verify', ['verify', snapshot])
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ at: new Date().toISOString(), endpoint, snapshot,
    helper: join(root, 'out/probe.exe'), restoresOnly: 'LAN/RAS flags, server, bypass, PAC via WinINet; never RunOnce',
    broadRegImport: 'Emergency reference only: do not blindly overwrite settings from other software' }, null, 2))
}
console.log(`${prior ? 'Requested guarded restoration from' : 'Verified read-only backup'}: ${dir}`)
if (exercise || prior) {
  competitors()
  if (prior) must('restore', ['restore', snapshot, endpoint])
  else {
    // External rescue is a failed experiment, even if safe restoration subsequently succeeds.
    const cycle = supervised('cycle', ['cycle', snapshot, endpoint])
    competitors()
    must('post-cycle-snapshot', ['snapshot', join(dir, 'post-cycle.bin')])
    must('restore', ['restore', snapshot, endpoint])
    if (cycle.failure) throw new Error('Experiment failed; original settings were restored, not an accepted result', { cause: cycle.failure })
  }
  must('restored-verify', ['verify', snapshot])
  console.log('Original LAN/RAS state verified after restoration; RunOnce was not modified')
} else console.log('Read-only mode: no proxy write, no notification, no RunOnce change')
