import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync, symlinkSync, unlinkSync, openSync, closeSync } from 'node:fs'
import { realpath } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const native = dirname(fileURLToPath(import.meta.url))
const out = join(native, '../out/admission-native')
const helper = join(out, 'admission-fake.exe')
const self = fileURLToPath(import.meta.url)
const hash = bytes => createHash('sha256').update(bytes).digest()
const close = Buffer.from([2, 0, 0, 0, 0, 0, 0, 0])
const quote = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
const frame = (kind, payload) => {
  const header = Buffer.alloc(8); header.writeUInt32LE(kind); header.writeUInt32LE(payload.length, 4)
  return Buffer.concat([header, payload])
}
const exec = args => frame(1, Buffer.from(args.join('\0') + '\0', 'utf16le'))
const checksum = bytes => { let value = 2166136261; for (const byte of bytes) value = Math.imul(value ^ byte, 16777619) >>> 0; return value }
function seed(root, header, endpoints = []) {
  header = Buffer.from(header)
  header.writeUInt32LE(checksum(header.subarray(0, 412)), 412)
  const records = endpoints.map(endpoint => {
    const record = Buffer.alloc(608); record.writeUInt32LE(0x3152504b); record.write(endpoint, 8, 600, 'utf16le')
    record.writeUInt32LE(checksum(record.subarray(8)), 4); return record
  })
  const bytes = Buffer.concat([header, ...records]); writeFileSync(join(root, 'recovery.bin'), bytes); return bytes
}
function launch(root, mode = '', exe = helper, recovery = false, server = '') {
  const log = join(root, `${mode || (recovery ? 'recovery' : 'start')}-${randomUUID()}.jsonl`)
  const args = recovery ? ['recover-admitted', '--log', log] : ['start', '--core', helper, '--data', root, '--log', log]
  const child = spawn(exe, args, { windowsHide: true, stdio: 'pipe', env: { ...process.env,
    KURO_ADMISSION_TEST_ROOT: root, KURO_ADMISSION_TEST_MODE: mode, KURO_ADMISSION_TEST_SERVER: server } })
  let trace = '', output = '', lines = [], ended = false
  child.stdin.on('error', () => {})
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8')
  child.stderr.on('data', data => { trace += data; if (trace.length > 65536) trace = trace.slice(-65536) })
  child.stdout.on('data', data => {
    output += data
    for (;;) {
      const newline = output.indexOf('\n'); if (newline < 0) break
      lines.push(JSON.parse(output.slice(0, newline))); output = output.slice(newline + 1)
    }
  })
  const exited = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => resolve(code)) })
  const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', code => { ended = true; resolve(code) }) })
  const until = async predicate => {
    for (let i = 0; i < 1000; ++i) {
      const value = predicate(); if (value) return value
      assert(!ended, `early exit: ${JSON.stringify(lines)} ${trace}`)
      await new Promise(resolve => setTimeout(resolve, 5))
    }
    assert.fail(`bounded wait expired: ${JSON.stringify(lines)} ${trace}`)
  }
  return { child, closed, exited, until, log, recovery, trace: () => trace, lines: () => lines,
    ready: () => until(() => lines.find(line => line.ready)), send: bytes => child.stdin.write(bytes),
    report: () => lines.find(line => line.command === 'shutdown') }
}
async function finish(p, expected, { timedOut, noop = false } = {}) {
  assert.equal(await p.closed, expected, `${JSON.stringify(p.lines())} ${p.trace()}`)
  const report = p.report()
  if (expected === 1 || expected === 77) { assert(!report && !p.lines().some(x => x.ready)); return }
  assert(report, p.trace())
  const closing = p.lines().find(x => x.command === 'closing')
  assert(closing && closing.protocol === 3 && closing.firstTriggerEpochMs > 0)
  assert(p.lines().indexOf(closing) < p.lines().indexOf(report))
  assert.equal(report.protocol, 3)
  if (expected === 0 || p.recovery || p.lines().some(x => x.ready)) assert.equal(report.coreGone, true)
  else assert.equal(typeof report.coreGone, 'boolean')
  assert.equal(report.recoveryNoop, noop)
  assert(report.durationMs < 2600)
  if (report.coreGone) assert(report.coreStopRequestedMs <= report.coreConfirmedMs)
  else assert.equal(report.coreConfirmedMs, null)
  if (timedOut !== undefined) assert.equal(report.timedOut, timedOut)
  if (expected === 0) {
    assert.equal(report.ok, true)
    assert.equal(report.cleanupReadbackVerified, !noop)
    if (!noop) {
      assert(report.clearStartedMs <= report.clearCompletedMs)
      assert(report.clearCompletedMs <= report.readbackCompletedMs)
      assert(report.readbackCompletedMs <= report.cleanupDurationMs)
      assert(report.cleanupDurationMs <= report.coreStopRequestedMs && report.cleanupDurationMs < 1500)
      assert(report.cleanupReadback && report.cleanupReadback.ok)
    }
  } else assert.equal(report.ok, false)
  const persisted = readFileSync(p.log, 'utf8').trim().split('\n').map(x => JSON.parse(x))
  assert.deepEqual(persisted.at(-1), report)
  assert.equal(persisted.at(-2).command, 'closing')
  return report
}
async function baseline(root) {
  const p = launch(root); assert.deepEqual(await p.ready(), { ready: true, protocol: 3, recoveryVerified: true })
  p.send(close); await finish(p, 0)
  const header = readFileSync(join(root, 'recovery.bin')); assert.equal(header.length, 416)
  assert.equal(header.readUInt32LE(0), 0x334a524b); assert.equal(header.readUInt32LE(4), 3)
  const retained = join(root, `${header.subarray(380, 412).toString('hex')}.exe`)
  assert.deepEqual(hash(readFileSync(retained)), hash(readFileSync(helper)))
  return { header, retained }
}
function evidenceOrder(p) {
  const events = p.trace().split('\n').filter(x => x.startsWith('evidence-'))
  assert.deepEqual(events, ['evidence-report-release', 'evidence-wait-enter', 'evidence-wait-return', 'evidence-session-finished'])
}
const replayFaults = ['clear-fail', 'clear-hung', 'clear-late', 'readback-fail', 'readback-hung', 'readback-late',
  'readback-reenabled', 'readback-ras-fail', 'reset-fail', 'reset-hung']
async function scenario(name, base) {
  const root = join(base, name); mkdirSync(root)
  const { header, retained } = await baseline(root)
  const path = join(root, 'recovery.bin')
  if (name === 'owner-contention' || name === 'recovery-contention') {
    const live = launch(root); await live.ready()
    const before = header
    const other = launch(root, '', name === 'owner-contention' ? helper : retained, name === 'recovery-contention')
    await finish(other, 1); assert.equal(other.trace(), '')
    assert.throws(() => readFileSync(path), { code: 'EBUSY' }); live.send(close); await finish(live, 0); assert.deepEqual(readFileSync(path), before); return
  }
  if (name === 'journal-contention') {
    const file = openSync(path, 'r+'); const other = launch(root)
    await finish(other, 1); closeSync(file); assert.equal(other.trace(), ''); assert.deepEqual(readFileSync(path), header); return
  }
  if (['recovery-missing', 'recovery-empty', 'recovery-source'].includes(name)) {
    if (name === 'recovery-missing') unlinkSync(path)
    if (name === 'recovery-empty') writeFileSync(path, '')
    const p = launch(root, '', name === 'recovery-source' ? helper : retained, true)
    await finish(p, name === 'recovery-source' ? 1 : 0, { noop: name !== 'recovery-source' })
    assert.equal(p.trace(), ''); assert(!p.lines().some(x => x.ready))
    if (name === 'recovery-missing') assert(!existsSync(path))
    if (name === 'recovery-empty') assert.equal(readFileSync(path).length, 0)
    return
  }
  if (name === 'root-junction') {
    const junction = join(base, 'root-junction-link'); symlinkSync(root, junction, 'junction')
    const p = launch(junction); await finish(p, 1); assert.equal(p.trace(), ''); assert.deepEqual(readFileSync(path), header); return
  }
  if (name === 'retained-changed') {
    writeFileSync(retained, 'changed helper'); const p = launch(root); await finish(p, 1)
    assert.deepEqual(readFileSync(path), header); assert.equal(p.trace(), ''); return
  }
  if (name.startsWith('reject-') || name.startsWith('update-')) {
    const changed = Buffer.from(header)
    const pending = name.includes('pending') || name.startsWith('reject-') ? ['127.0.0.1:7891'] : []
    const updating = name.startsWith('update-')
    if (name === 'reject-sid') { changed.fill(0, 12, 380); changed.write('S-1-5-18', 12, 'utf16le') }
    if (updating || name === 'reject-helper') {
      const previous = Buffer.from('previous current-version retained helper fixture')
      const digest = hash(previous); digest.copy(changed, 380)
      if (updating && !name.includes('missing')) writeFileSync(join(root, `${digest.toString('hex')}.exe`), name.includes('changed') ? 'wrong bytes' : previous)
    }
    let original = seed(root, changed, pending)
    if (name === 'reject-corrupt') { original[412] ^= 1; writeFileSync(path, original) }
    if (name === 'reject-legacy') { original = original.subarray(416); writeFileSync(path, original) }
    if (name === 'reject-v2') { original = Buffer.alloc(480); original.writeUInt32LE(0x324a524b); original.writeUInt32LE(2, 4); writeFileSync(path, original) }
    const deny = !updating || name.includes('missing') || name.includes('changed')
    const fail = name.includes('readback-fail')
    const p = launch(root, fail ? 'readback-fail' : '', helper, false, pending.length ? pending[0] : '')
    if (!deny && !fail) { await p.ready(); p.send(close) }
    await finish(p, deny ? 1 : fail ? 42 : 0)
    if (deny || fail) { assert.deepEqual(readFileSync(path), original); assert(!p.trace().includes('core-create')) }
    else { assert.deepEqual(readFileSync(path), header); assert(p.trace().includes('readback')) }
    return
  }
  const autonomous = name.startsWith('autonomous-')
  const replay = name.startsWith('replay-') || autonomous || ['close-replay', 'close-hung', 'header-only', 'endpoint-bound'].includes(name)
  let fault = replay ? name.replace(/^(replay|autonomous)-/, '') : name.replace(/^shutdown-/, '')
  if (name === 'close-replay') fault = 'clear-slow'
  if (name === 'close-hung') fault = 'clear-hung'
  if (name === 'endpoint-bound') fault = ''
  if (name === 'header-only' || fault === 'success') fault = ''
  const pending = replay && name !== 'header-only' ? name === 'endpoint-bound' ? Array.from({ length: 8 }, (_, i) => `127.0.0.1:${7891 + i}`) : ['127.0.0.1:7891'] : []
  const original = seed(root, header, pending)
  const mode = replay ? fault : name.startsWith('shutdown-') ? name : fault
  if (/^(header-|flush-)/.test(name)) writeFileSync(path, '')
  const p = launch(root, name === 'repeated-close' ? 'shutdown-clear-hung' : mode, autonomous ? retained : helper, autonomous, pending.length ? pending[0] : '')
  if (replay) {
    if (name === 'close-replay' || name === 'close-hung') {
      await p.until(() => p.trace().includes('clear-enter'))
      await new Promise(resolve => setTimeout(resolve, name === 'close-hung' ? 800 : 200)); p.send(close)
    } else if (!autonomous && !replayFaults.includes(fault)) { await p.ready(); p.send(close) }
    const failed = replayFaults.includes(fault) || name === 'close-hung'
    const report = await finish(p, failed ? 42 : 0, { timedOut: /hung|late/.test(fault) })
    if (failed) { assert.deepEqual(readFileSync(path), original); assert(!p.trace().includes('core-create')) }
    else assert.deepEqual(readFileSync(path), header)
    assert.equal(p.trace().split('clear:127.0.0.1:7891\n').length - 1, pending.length ? 1 : 0)
    if (autonomous) assert(!p.lines().some(x => x.ready) && report.corePid === 0)
    return
  }
  if (/^(header-|flush-|core-)/.test(name)) {
    await finish(p, name === 'header-crash' ? 77 : 42, { timedOut: /hung|late/.test(name) })
    assert(!p.trace().includes('set\n')); return
  }
  await p.ready(); if (name !== 'diagnostics-stall') await p.until(() => p.trace().includes('fake-core'))
  if (name === 'malformed-admit' || name === 'unknown-frame' || name === 'truncated-exec') {
    p.child.stdin.end(name === 'malformed-admit' ? frame(3, Buffer.alloc(128)) : name === 'unknown-frame' ? frame(99, Buffer.alloc(0)) : exec(['get']).subarray(0, 10))
    await finish(p, 0); assert(!p.trace().includes('set\n')); return
  }
  if (name === 'eof') { p.child.stdin.end(); await finish(p, 0); return }
  if (name === 'query') {
    p.send(exec(['get'])); const report = await finish(p, 0)
    evidenceOrder(p)
    assert(report.triggerMask & 16); assert.equal(report.firstTrigger, 16)
    assert.equal(report.querySessionFlags, 1); assert.equal(report.queryEvents, 1)
    assert(report.queryEpochMs > 0); return
  }
  p.send(exec(['set', '--host', '127.0.0.1', '--port', '7892']))
  if (/^(append-|set-)/.test(name)) {
    if (name.startsWith('set-')) await p.until(() => p.trace().includes('set\n'))
    else if (name.endsWith('hung')) await p.until(() => p.trace().includes('append-enter'))
    else await p.until(() => p.lines().some(x => x.ok === false))
    p.send(close)
    await finish(p, name === 'append-fail' || name === 'set-slow' ? 0 : 42, { timedOut: /hung|late/.test(name) })
    if (name.startsWith('append-')) assert(!p.trace().includes('set\n'))
    return
  }
  await p.until(() => p.lines().some(x => x.command === 'set'))
  assert.throws(() => readFileSync(path), { code: 'EBUSY' })
  if (name === 'diagnostics-stall') p.child.stderr.pause()
  p.send(close)
  if (name === 'repeated-close') {
    await p.until(() => p.lines().some(x => x.command === 'closing'))
    await new Promise(resolve => setTimeout(resolve, 800)); p.send(close)
  }
  if (name === 'diagnostics-stall') { await p.exited; p.child.stderr.resume() }
  if (name === 'log-hung') { assert.equal(await p.closed, 42); assert(p.lines().some(x => x.command === 'closing')); evidenceOrder(p); return }
  const failed = name.startsWith('shutdown-') && !name.endsWith('readback-foreign') || name === 'repeated-close'
  const report = await finish(p, failed ? 42 : 0, { timedOut: /hung|late|delayed-supervisor/.test(name) || name === 'repeated-close' })
  if (failed) assert.equal(readFileSync(path).length, 1024)
  else assert.deepEqual(readFileSync(path), header)
  if (name === 'shutdown-readback-reenabled') { assert.equal(report.cleanupReadbackVerified, false); assert.equal(report.cleanupReadback.connections[0].flags, 3) }
  if (name === 'repeated-close') assert(report.durationMs < 2100)
  if (name === 'shutdown-delayed-supervisor') assert(report.cleanupDurationMs >= 1500)
}

if (process.argv[2] === '--child') {
  await scenario(process.argv[3], process.argv[4])
} else {
  mkdirSync(out, { recursive: true })
  const flags = ['-D_WIN32_WINNT=0x0A00', '-municode', '-mconsole', '-O2', '-static', '-Wall', '-Wextra', '-Werror']
  execFileSync(process.env.CC ?? 'gcc', [...flags, join(native, 'admission_fake.c'), '-ladvapi32', '-lshell32', '-lole32', '-luuid', '-o', helper], { stdio: 'inherit', timeout: 60000 })
  execFileSync(process.env.CC ?? 'gcc', [...flags, join(native, 'watchdog.c'), '-o', join(out, 'admission-watchdog.exe')], { stdio: 'inherit', timeout: 60000 })
  const base = await realpath(mkdtempSync(join(tmpdir(), 'kuro-admission-')))
  process.env.KURO_ADMISSION_TEST_NAMESPACE = randomUUID()
  const cases = ['initial', 'eof', 'malformed-admit', 'unknown-frame', 'truncated-exec', 'query', 'owner-contention', 'recovery-contention', 'journal-contention',
    'root-junction', 'retained-changed', 'header-only', 'endpoint-bound', 'recovery-missing', 'recovery-empty', 'recovery-source',
    'reject-sid', 'reject-helper', 'reject-corrupt', 'reject-legacy', 'reject-v2',
    'update-empty', 'update-pending', 'update-empty-missing', 'update-pending-missing', 'update-pending-changed', 'update-pending-readback-fail',
    ...replayFaults.map(x => `replay-${x}`), 'replay-success', 'close-replay', 'close-hung',
    'autonomous-success', ...['clear-fail', 'clear-hung', 'readback-fail', 'readback-hung', 'readback-reenabled', 'reset-fail'].map(x => `autonomous-${x}`),
    'header-fail', 'header-short', 'header-hung', 'header-crash', 'flush-fail', 'flush-hung', 'core-fail', 'core-hung', 'core-late',
    'append-fail', 'append-short', 'append-hung', 'set-hung', 'set-late', 'set-slow',
    ...replayFaults.map(x => `shutdown-${x}`), 'shutdown-readback-foreign', 'shutdown-delayed-supervisor', 'repeated-close', 'diagnostics-stall', 'log-hung']
  const selected = process.argv.find(x => x.startsWith('--case='))?.slice(7)
  if (selected) assert(cases.includes(selected), `unknown case ${selected}`)
  for (const name of cases.filter(x => !selected || x === selected)) {
    const report = join(base, `${name}.watchdog.json`)
    const command = [process.execPath, self, '--child', name, base].map(quote).join(' ')
    try {
      execFileSync(join(out, 'admission-watchdog.exe'), ['8000', report, process.execPath, command], { stdio: 'inherit', timeout: 12000 })
    } finally {
      if (existsSync(report)) writeFileSync(join(out, `${name}.watchdog.json`), readFileSync(report))
    }
    const guard = JSON.parse(readFileSync(report))
    assert(!guard.watchdogKilled && !guard.lingeringChildren && guard.remaining === 0)
    console.log(`current-owner native: ${name} passed`)
  }
  writeFileSync(join(out, 'last-run.json'), JSON.stringify({ base, cases: selected ? [selected] : cases, privateOnly: true,
    historical: 'Protocol2 receipt/nonce/admission/seeding and automatic RunOnce registration cases are retired; see native/current-owner-tests.md.' }, null, 2))
  console.log(`current-owner native: ${selected ? 1 : cases.length} passed; private evidence ${base}`)
}
