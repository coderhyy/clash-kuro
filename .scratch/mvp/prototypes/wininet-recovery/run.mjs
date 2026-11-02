import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cleanExit } from './exit-evidence.mjs'
const root = dirname(fileURLToPath(import.meta.url))
const exercise = process.argv.includes('--exercise')
const prior = process.argv.find(x => x.startsWith('--restore='))?.slice(10)
const resident = process.argv.find(x => x.startsWith('--resident='))?.slice(11)
if (resident !== undefined && (!exercise || prior || !['plain', 'aware'].includes(resident)))
  throw new Error('--resident=plain|aware requires --exercise, never --restore')
const dir = prior ? resolve(prior) : join(homedir(), 'kuro-sysproxy-backups', `wininet-${Date.now()}`)
mkdirSync(dir, { recursive: true })
// A crashed controller leaves this lock in place: never infer writer death from a missing JS process.
let writerGone = true
let restorationRequired = false
if (exercise || prior) {
  const base = join(homedir(), 'kuro-sysproxy-backups')
  mkdirSync(base, { recursive: true })
  const lock = join(base, 'writer.lock')
  const owner = JSON.stringify({ pid: process.pid, at: Date.now(), backup: dir })
  writeFileSync(lock, owner, { flag: 'wx' })
  process.on('exit', () => {
    if (writerGone && !restorationRequired && existsSync(lock) && readFileSync(lock, 'utf8') === owner) unlinkSync(lock)
  })
}
const snapshot = join(dir, 'lan-ras.bin'), endpoint = '127.0.0.1:48967'
const residentReport = join(dir, 'resident.json')
const q = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
function supervised(label, args) {
  const report = join(dir, `${label}-${Date.now()}.supervisor.json`)
  const exe = join(root, label === 'cycle' && resident ? 'out/resident.exe' : 'out/probe.exe')
  let failure, stdout = ''
  const mutating = label === 'cycle' || label === 'restore'
  if (mutating) { writerGone = false; restorationRequired = true }
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
  const result = { data, failure, stdout }
  if (label === 'restore' && cleanExit(result)) restorationRequired = false
  return result
}
function must(label, args) {
  const result = supervised(label, args)
  if (!cleanExit(result))
    throw new Error(`${label} failed; retain backup ${dir}`, { cause: result.failure })
}
function competitors() {
  const output = execFileSync('powershell.exe', ['-NoProfile', '-Command',
    'Get-Process | Where-Object { $_.ProcessName -match "clash-verge|fiddler|Clash Kuro|mihomo|sing-box|v2ray|v2rayN" } | Select-Object Id,ProcessName | ConvertTo-Json -Compress'],
  { timeout: 10000, windowsHide: true, encoding: 'utf8' }).trim()
  if (output) throw new Error(`STOP: other proxy processes must exit before writes or restoration: ${output}`)
}
function readRunOnce() {
  return execFileSync('powershell.exe', ['-NoProfile', '-Command',
    '$ErrorActionPreference="Stop"; $key="HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"; if (Test-Path -LiteralPath $key) { Get-ItemProperty -LiteralPath $key | Select-Object ClashKuroSysProxyCleanup | ConvertTo-Json -Compress } else { "null" }'],
  { timeout: 10000, windowsHide: true, encoding: 'utf8' }).trim() || 'null'
}
if (!prior) {
  execFileSync('reg.exe', ['export', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', join(dir, 'internet-settings.reg')],
    { timeout: 10000, windowsHide: true, stdio: 'pipe' })
  writeFileSync(join(dir, 'runonce-readonly.json'), readRunOnce())
  must('snapshot', ['snapshot', snapshot])
  must('verify', ['verify', snapshot])
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify({ at: new Date().toISOString(), endpoint, snapshot,
    helper: join(root, 'out/probe.exe'), restoresOnly: 'LAN/RAS flags, server, bypass, PAC via WinINet; never RunOnce',
    broadRegImport: 'Emergency reference only: do not blindly overwrite settings from other software' }, null, 2))
}
console.log(`${prior ? 'Requested guarded restoration from' : 'Verified read-only backup'}: ${dir}`)
if (exercise || prior) {
  competitors()
  let cycleEvidence = null
  let residentEvidence = null
  if (prior) must('restore', ['restore', snapshot, endpoint])
  else {
    // External rescue is a failed experiment, even if safe restoration subsequently succeeds.
    const cycle = supervised('cycle', resident
      ? ['resident-cycle', snapshot, endpoint, residentReport, resident]
      : ['cycle', snapshot, endpoint])
    competitors()
    must('post-cycle-snapshot', ['snapshot', join(dir, 'post-cycle.bin')])
    must('restore', ['restore', snapshot, endpoint])
    if (!cleanExit(cycle))
      throw new Error('Experiment failed; original settings were restored, not an accepted result', { cause: cycle.failure })
    cycleEvidence = cycle.stdout.trim().split(/\r?\n/).filter(line => line.trim())
      .map(line => JSON.parse(line))
      .find(item => item.command === 'cycle-verified')
    assert(cycleEvidence?.connections >= 1, 'Missing per-connection set/clear verification')
    assert.equal(cycleEvidence.setFlags, 3)
    assert.equal(cycleEvidence.clearFlags, 1)
    if (resident) {
      residentEvidence = JSON.parse(readFileSync(residentReport, 'utf8'))
      assert.equal(residentEvidence.pid, cycle.data.rootPid)
      assert.equal(residentEvidence.decision, 'cleared')
      assert.equal(residentEvidence.operationError, 0)
      assert.equal(residentEvidence.operations, 1)
      assert.equal(residentEvidence.stops, 1)
      assert.equal(residentEvidence.windowTriggers, 1)
      assert.equal(residentEvidence.deadlineMs, 1500)
      assert(residentEvidence.stopMs >= residentEvidence.decisionMs)
      assert(residentEvidence.decisionMs < 1750, 'Observed clear wait exceeded threshold; not a hard-real-time claim')
      assert(residentEvidence.endMs < 2350, 'Observed complete shutdown work exceeded threshold')
      assert.equal(residentEvidence.coreGone, true)
      assert.equal(residentEvidence.coreExit, 0)
      assert.equal(residentEvidence.coreForced, false)
      assert.equal(residentEvidence.selfForced, false)
    }
  }
  must('restored-verify', ['verify', snapshot])
  assert.deepEqual(JSON.parse(readRunOnce())?.ClashKuroSysProxyCleanup ?? null,
    JSON.parse(readFileSync(join(dir, 'runonce-readonly.json'), 'utf8'))?.ClashKuroSysProxyCleanup ?? null,
    'RunOnce differs from backup; do not overwrite externally changed recovery settings')
  writeFileSync(join(root, resident ? `out/verified-${resident}.json` : 'out/verified.json'), JSON.stringify({ at: new Date().toISOString(),
    backup: dir, platform: process.platform, restoredAndVerified: true, runOnceUnchanged: true,
    cycleEvidence,
    residentEvidence,
    scope: resident ? `real WinINet clear with ${resident} native query wait and fake Core; private trigger, not OS session validation`
      : 'shared one-shot WinINet operations, not resident notification/session validation' }, null, 2))
  console.log('Original LAN/RAS state verified after restoration; RunOnce was not modified')
} else console.log('Read-only mode: no proxy write, no notification, no RunOnce change')
