// Parser failures use only `verify`; no test invokes a mutating command.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cleanExit } from './exit-evidence.mjs'
const exited = { rootExitCode: 0, remaining: 0, watchdogKilled: false, lingeringChildren: false }
assert(cleanExit({ data: exited }))
for (const patch of [{ rootExitCode: 2 }, { remaining: 1 }, { watchdogKilled: true },
  { lingeringChildren: true }, { watchdogKilled: undefined }])
  assert.equal(cleanExit({ data: { ...exited, ...patch } }), false)
assert.equal(cleanExit({ data: exited, failure: new Error('outer supervisor failed') }), false)
const root = dirname(fileURLToPath(import.meta.url))
for (const args of [['--resident=aware'], ['--exercise', '--resident='], ['--exercise', '--resident=invalid'],
  ['--exercise', '--resident=aware', '--restore=unused']]) {
  let rejected
  try { execFileSync(process.execPath, [join(root, 'run.mjs'), ...args], { timeout: 3000, windowsHide: true, stdio: 'pipe' }) }
  catch (error) { rejected = error }
  assert.equal(rejected?.status, 1)
  assert.match(String(rejected.stderr), /requires --exercise, never --restore/)
}
const dir = join(root, 'out', 'invalid-backups')
mkdirSync(dir, { recursive: true })
const exe = join(root, 'out', 'probe.exe')
execFileSync(exe, ['self-test'], { timeout: 2000, windowsHide: true })
const magic = Buffer.from('KSPB0001')
const word = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b }
const wrap = content => Buffer.concat([magic, content, magic])
const cases = [Buffer.alloc(0), Buffer.from('bad header'), wrap(word(0)), wrap(word(257)),
  wrap(Buffer.concat([word(1), word(3), word(0xffffffff), word(32768)])),
  wrap(Buffer.concat([word(1), word(3), word(0xffffffff), word(1), Buffer.from([0, 0])]))]
for (const [index, bytes] of cases.entries()) {
  const file = join(dir, `${index}.bin`)
  writeFileSync(file, bytes)
  let failure
  try { execFileSync(exe, ['verify', file], { timeout: 2000, windowsHide: true, stdio: 'pipe' }) }
  catch (error) { failure = error }
  assert.equal(failure?.status, 1, `invalid snapshot ${index} must fail before preflight`)
  assert.match(String(failure.stdout), /Invalid or incomplete snapshot/)
}
console.log('Restoration-state guards and 6 malformed snapshots rejected; no proxy writes')
const report = join(dir, 'readonly-get.supervisor.json')
const stdout = execFileSync(join(root, 'out/watchdog.exe'), ['10000', report, exe, `"${exe}" get`],
  { timeout: 16000, windowsHide: true, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
assert(stdout.trim(), 'Supervised GUI helper must forward stdout, not silently lose JSON')
assert.equal(JSON.parse(stdout).ok, true)
const job = JSON.parse(readFileSync(report, 'utf8'))
assert.equal(job.rootExitCode, 0)
assert.equal(job.watchdogKilled, false)
assert.equal(job.remaining, 0)
console.log('Read-only supervised GUI helper get returned JSON; no proxy writes')
