import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const native = dirname(fileURLToPath(import.meta.url))
const out = join(native, '../out/admission-native')
const helper = join(out, 'admission-fake.exe')
const self = fileURLToPath(import.meta.url)
const hash = bytes => createHash('sha256').update(bytes).digest()
const close = Buffer.from([2, 0, 0, 0, 0, 0, 0, 0])
const receipt = hash('receipt'), evidence = hash('evidence')
const quote = value => '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
const frame = (kind, payload) => {
  const header = Buffer.alloc(8); header.writeUInt32LE(kind); header.writeUInt32LE(payload.length, 4)
  return Buffer.concat([header, payload])
}
const exec = args => frame(1, Buffer.from(args.join('\0') + '\0', 'utf16le'))

function launch(root, mode = '', exe = helper, command = 'reserve', initial = []) {
  const args = command === 'reserve' ? ['reserve', '--core', helper, '--data', root, '--expected-server', '127.0.0.1:7892'] : [command]
  args.push(...initial.flatMap(server => ['--initial-server', server]))
  const child = spawn(exe, args, { windowsHide: true, stdio: 'pipe', env: { ...process.env,
    KURO_ADMISSION_TEST_ROOT: root, KURO_ADMISSION_TEST_MODE: mode } })
  let trace = '', output = '', lines = []
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8')
  child.stderr.on('data', data => { trace += data })
  child.stdout.on('data', data => {
    output += data
    for (;;) {
      const newline = output.indexOf('\n'); if (newline < 0) break
      lines.push(JSON.parse(output.slice(0, newline))); output = output.slice(newline + 1)
    }
  })
  const closed = new Promise((resolve, reject) => { child.once('error', reject); child.once('close', code => resolve(code)) })
  let exited = false; closed.then(() => { exited = true })
  const until = async predicate => {
    for (let i = 0; i < 700; ++i) {
      const value = predicate(); if (value) return value
      assert(!exited, `early exit: ${JSON.stringify(lines)} ${trace}`)
      await new Promise(resolve => setTimeout(resolve, 5))
    }
    assert.fail(`bounded wait expired: ${JSON.stringify(lines)} ${trace}`)
  }
  return { child, closed, until, trace: () => trace, lines: () => lines,
    reservation: () => until(() => lines.find(line => line.reserved)),
    ready: () => until(() => lines.find(line => line.ready)),
    send: bytes => child.stdin.write(bytes) }
}
function admit(reserved, changes = {}) {
  return frame(3, Buffer.concat([
    changes.nonce ?? Buffer.from(reserved.nonce, 'hex'), changes.journal ?? Buffer.from(reserved.journalDigest, 'hex'),
    changes.receipt ?? receipt, changes.evidence ?? evidence,
  ]))
}
function seed(root, sid, helperDigest, endpoints = []) {
  const header = Buffer.alloc(480)
  header.writeUInt32LE(0x324a524b); header.writeUInt32LE(2, 4); header.writeUInt32LE(480, 8)
  header.write(sid, 12, 368, 'utf16le'); Buffer.from(helperDigest, 'hex').copy(header, 380)
  receipt.copy(header, 412); evidence.copy(header, 444)
  const checksum = bytes => { let value = 2166136261; for (const byte of bytes) value = Math.imul(value ^ byte, 16777619) >>> 0; return value }
  header.writeUInt32LE(checksum(header.subarray(0, 476)), 476)
  const records = endpoints.map(endpoint => {
    const record = Buffer.alloc(608); record.writeUInt32LE(0x3152504b); record.write(endpoint, 8, 600, 'utf16le')
    record.writeUInt32LE(checksum(record.subarray(8)), 4); return record
  })
  const bytes = Buffer.concat([header, ...records]); if (root) writeFileSync(join(root, 'recovery.bin'), bytes); return bytes
}
function noMutation(process) {
  assert(!/clear:|unregister|register|warm|core-create|fake-core|set\n/.test(process.trace()), process.trace())
  assert(!process.lines().some(line => line.ready), 'unexpected ready')
}
const rejectOnly = ['existing-close', 'existing-eof', 'existing-query', 'existing-malformed', 'truncated-admit', 'close-then-admit', 'existing-exec']
const readyCases = ['pending', 'header-only', 'existing-seeds-ignored', 'header-seeds-ignored']

async function initialScenario(name, root) {
  let initial = name === 'seed-bound' || name === 'seed-overflow' ?
    Array.from({ length: name === 'seed-bound' ? 8 : 9 }, (_, i) => `127.0.0.1:${7900 + i}`) :
    ['127.0.0.1:7891', '127.0.0.1:7893']
  if (name === 'seed-duplicate') initial = [initial[0], initial[0]]
  if (name === 'seed-invalid') initial = ['not an endpoint']
  const process = launch(root, name, helper, name === 'seed-autonomous-denied' ? 'recover-admitted' : 'reserve', initial)
  if (['seed-overflow', 'seed-duplicate', 'seed-invalid', 'seed-autonomous-denied'].includes(name)) {
    assert.equal(await process.closed, 1); noMutation(process)
    assert(!existsSync(join(root, 'recovery.bin'))); return
  }
  const reserved = await process.reservation()
  assert.equal(reserved.admissionReceiptDigest, null)
  assert.deepEqual(reserved.priorEndpoints, []); assert.deepEqual(reserved.initialEndpoints, initial)
  noMutation(process)
  if (['seed-close', 'seed-eof', 'seed-query', 'seed-deny'].includes(name)) {
    if (name === 'seed-eof') process.child.stdin.end()
    else if (name !== 'seed-query') process.send(name === 'seed-deny' ? admit(reserved, { nonce: Buffer.alloc(32) }) : close)
    assert.equal(await process.closed, 42)
    const shutdown = process.lines().find(line => line.command === 'shutdown')
    assert(shutdown && shutdown.ok === false && shutdown.timedOut === false && shutdown.corePid === 0)
    if (name === 'seed-query') assert.equal(shutdown.queryEvents, 1)
    noMutation(process); assert.equal(readFileSync(join(root, 'recovery.bin')).length, 0); return
  }
  process.send(admit(reserved))
  const persistenceFailure = ['seed-write-fail', 'seed-write-short', 'seed-write-hung', 'seed-header-fail', 'seed-header-crash', 'seed-header-short'].includes(name)
  if (persistenceFailure) {
    assert.equal(await process.closed, name === 'seed-header-crash' ? 77 : 42); noMutation(process)
    const retained = readFileSync(join(root, 'recovery.bin'))
    assert.equal(retained.length, 480 + initial.length * 608)
    if (name !== 'seed-header-short') assert.equal(retained.readUInt32LE(0), 0, 'failed seeding must not publish a valid partial provenance header')
    if (name.startsWith('seed-header-')) assert.deepEqual(retained.subarray(480),
      seed(null, reserved.userSid, reserved.helperDigest, initial).subarray(480), 'whole seed union must be durable before header publication')
    if (name === 'seed-write-short') assert.equal(retained.readUInt32LE(480), 0x3152504b)
    const next = launch(root, '', helper, 'reserve', initial)
    assert.equal(await next.closed, 1); noMutation(next)
    const autonomous = launch(root, '', join(root, `${reserved.helperDigest}.exe`), 'recover-admitted')
    assert.equal(await autonomous.closed, 1); noMutation(autonomous)
    assert.deepEqual(readFileSync(join(root, 'recovery.bin')), retained); return
  }
  await process.ready(); await process.until(() => process.trace().includes('fake-core\n'))
  process.send(close); assert.equal(await process.closed, 0)
  for (const endpoint of initial) assert.equal(process.trace().split(`clear:${endpoint}\n`).length - 1, 1)
  assert(!process.trace().includes('clear:127.0.0.1:7892'), 'proposal B must not be recovery authority')
  assert(!/^register$/m.test(process.trace()))
  const expected = seed(null, reserved.userSid, reserved.helperDigest)
  assert.deepEqual(readFileSync(join(root, 'recovery.bin')), expected)
}

async function scenario(name, base) {
  const root = join(base, name); mkdirSync(root)
  if (name.startsWith('seed-')) return initialScenario(name, root)
  const first = launch(root, name.startsWith('shutdown-unregister-') ? name.slice('shutdown-'.length) : '')
  const reservation = await first.reservation()
  assert.equal(reservation.protocol, 2); assert.equal(reservation.pid, first.child.pid)
  assert.equal(reservation.admissionReceiptDigest, null); assert.deepEqual(reservation.priorEndpoints, [])
  assert.deepEqual(reservation.initialEndpoints, [])
  assert.equal(reservation.helperDigest, hash(readFileSync(helper)).toString('hex'))
  assert.equal(reservation.journalDigest, hash(Buffer.alloc(0)).toString('hex'))
  const retained = join(root, `${reservation.helperDigest}.exe`)
  assert(existsSync(retained)); noMutation(first)
  if (name === 'contention') {
    const other = join(base, 'other-root'); mkdirSync(other)
    const contender = launch(other); assert.equal(await contender.closed, 1); noMutation(contender)
    assert(!existsSync(join(other, 'recovery.bin')))
  }
  if (name === 'initial' || name.startsWith('shutdown-unregister-')) {
    first.send(admit(reservation)); await first.ready()
    await first.until(() => first.trace().includes('fake-core\n'))
    first.send(exec(['set', '--host', '127.0.0.1', '--port', '7892', '--bypass', '']))
    await first.until(() => first.lines().some(line => line.command === 'set'))
    const admittedBytes = seed(null, reservation.userSid, reservation.helperDigest, ['127.0.0.1:7892'])
    assert.equal(admittedBytes.length, 1088)
    first.send(close); assert.equal(await first.closed, name === 'initial' ? 0 : 42)
    if (name === 'initial') assert.equal(readFileSync(join(root, 'recovery.bin')).length, 480)
    else assert.deepEqual(readFileSync(join(root, 'recovery.bin')), admittedBytes)
    assert(first.trace().includes('register\n') && first.trace().includes('clear:127.0.0.1:7892\n'))
  } else {
    if (name === 'malformed') first.send(frame(3, Buffer.alloc(127)))
    else if (name === 'bad-nonce') first.send(admit(reservation, { nonce: Buffer.alloc(32) }))
    else if (name === 'bad-journal') first.send(admit(reservation, { journal: Buffer.alloc(32) }))
    else if (name === 'zero-proof') first.send(admit(reservation, { receipt: Buffer.alloc(32) }))
    else if (name === 'exec-before-admit') first.send(exec(['get']))
    else if (name === 'eof') first.child.stdin.end()
    else first.send(close)
    const code = await first.closed
    assert.equal(code, ['malformed', 'bad-nonce', 'bad-journal', 'zero-proof', 'exec-before-admit'].includes(name) ? 42 : 0)
    noMutation(first); assert.equal(readFileSync(join(root, 'recovery.bin')).length, 0)
  }
  if (name.startsWith('shutdown-unregister-') || ['initial', 'no-admit', 'contention', 'malformed', 'bad-nonce', 'bad-journal', 'zero-proof', 'exec-before-admit', 'eof'].includes(name)) return

  if (name === 'junction-root' || name === 'changed-retained-helper') {
    let selectedRoot = root
    if (name === 'junction-root') {
      selectedRoot = join(base, 'private-root-link'); symlinkSync(root, selectedRoot, 'junction')
    } else writeFileSync(retained, 'not the retained executable')
    const denied = launch(selectedRoot)
    assert.equal(await denied.closed, 1); noMutation(denied)
    assert.equal(readFileSync(join(root, 'recovery.bin')).length, 0); return
  }

  if (name === 'autonomous-empty') {
    const denied = launch(root, '', retained, 'recover-admitted')
    assert.equal(await denied.closed, 1); noMutation(denied)
    assert.equal(readFileSync(join(root, 'recovery.bin')).length, 0); return
  }
  const pending = name !== 'header-only' && name !== 'header-seeds-ignored' ? ['127.0.0.1:7891'] : []
  let original = seed(root, reservation.userSid, reservation.helperDigest, pending)
  if (name === 'corrupt') { original[476] ^= 1; writeFileSync(join(root, 'recovery.bin'), original) }
  if (name === 'legacy') { original = original.subarray(480); writeFileSync(join(root, 'recovery.bin'), original) }
  if (name === 'wrong-sid' || name === 'wrong-helper') {
    original = seed(root, name === 'wrong-sid' ? 'S-1-5-18' : reservation.userSid,
      name === 'wrong-helper' ? hash('wrong helper').toString('hex') : reservation.helperDigest, pending)
  }
  const autonomous = name.startsWith('autonomous')
  const mode = /^(warm|core)-/.test(name) || name === 'existing-query' ? name : name.includes('unregister-') ? name.slice(name.indexOf('unregister-')) :
    name.includes('hung') ? 'hung' : name.includes('late') ? 'late' : name === 'close-replay' || name === 'duplicate' ? 'slow' : ''
  const second = launch(root, mode,
    autonomous && name !== 'autonomous-source' ? retained : helper, autonomous ? 'recover-admitted' : 'reserve',
    name.endsWith('seeds-ignored') ? ['127.0.0.1:7999'] : [])
  if (['corrupt', 'legacy', 'wrong-sid', 'wrong-helper', 'autonomous-source'].includes(name)) {
    assert.equal(await second.closed, 1); noMutation(second)
    assert.deepEqual(readFileSync(join(root, 'recovery.bin')), original); return
  }
  const replayBegan = performance.now()
  if (!autonomous) {
    const reserved = await second.reservation()
    assert.deepEqual(reserved.initialEndpoints, [])
    assert.equal(reserved.admissionReceiptDigest, receipt.toString('hex')); assert.deepEqual(reserved.priorEndpoints, pending)
    assert.equal(reserved.journalDigest, hash(original).toString('hex'))
    noMutation(second)
    if (rejectOnly.includes(name)) {
      if (name === 'existing-eof') second.child.stdin.end()
      else if (name === 'existing-query') { /* Native fixture posts only to its own window. */ }
      else if (name === 'existing-malformed') second.send(frame(3, Buffer.alloc(130)))
      else if (name === 'existing-exec') second.send(exec(['get']))
      else if (name === 'truncated-admit') second.child.stdin.end(admit(reserved).subarray(0, 60))
      else if (name === 'close-then-admit') second.send(Buffer.concat([close, admit(reserved)]))
      else second.send(close)
      const code = await second.closed
      assert.equal(code, 42)
      const shutdown = second.lines().find(line => line.command === 'shutdown')
      assert(shutdown && shutdown.ok === false && shutdown.timedOut === false && shutdown.corePid === 0)
      if (name === 'existing-query') assert.equal(shutdown.queryEvents, 1)
      noMutation(second); assert.deepEqual(readFileSync(join(root, 'recovery.bin')), original); return
    } else if (name === 'wrong-receipt') second.send(admit(reserved, { receipt: hash('wrong receipt') }))
    else second.send(admit(reserved, { evidence: hash('fresh evidence') }))
    if (name === 'close-replay' || name === 'duplicate' || name === 'close-hung') {
      await second.until(() => second.trace().includes('clear-enter\n'))
      if (name !== 'duplicate') await new Promise(resolve => setTimeout(resolve, name === 'close-hung' ? 800 : 200))
      second.send(name === 'duplicate' ? admit(reserved) : close)
    }
    if (readyCases.includes(name)) {
      await second.ready(); await second.until(() => second.trace().includes('fake-core\n')); second.send(close)
    }
  }
  const code = await second.closed
  const failure = /(?:late|hung|fail)$/.test(name) || ['wrong-receipt', 'duplicate'].includes(name)
  assert.equal(code, failure ? 42 : 0, `${name}: ${second.trace()}`)
  const shutdown = second.lines().find(line => line.command === 'shutdown')
  assert(shutdown && shutdown.durationMs < 2200, `shutdown exceeded original budget: ${JSON.stringify(shutdown)}`)
  if (name === 'close-replay') assert(shutdown.cleanupDurationMs >= 550 && shutdown.cleanupDurationMs < 1500)
  if (name === 'close-hung') assert(performance.now() - replayBegan < 2600, 'close must not restart replay budget')
  if (!readyCases.includes(name)) assert(!second.trace().includes('fake-core'), second.trace())
  assert(!/^register$/m.test(second.trace()))
  assert(!second.trace().includes('clear:127.0.0.1:7892'), 'proposed B must never be replayed')
  assert(!second.trace().includes('clear:127.0.0.1:7999'), 'existing provenance must ignore seed candidates')
  assert.equal(second.trace().split('clear:127.0.0.1:7891\n').length - 1, !pending.length || name === 'wrong-receipt' ? 0 : 1)
  if (name === 'wrong-receipt') noMutation(second)
  const result = readFileSync(join(root, 'recovery.bin'))
  assert.deepEqual(result.subarray(0, 480), original.subarray(0, 480), 'origin provenance must remain immutable')
  if ((/(?:late|hung|fail)$/.test(name) && !/^(warm|core)-/.test(name)) || name === 'wrong-receipt') {
    assert.deepEqual(result, original)
  } else assert.equal(result.length, 480)
  if (/(?:late|hung)$/.test(name)) assert.equal(shutdown.timedOut, true)
}

if (process.argv[2] === '--child') {
  await scenario(process.argv[3], process.argv[4])
} else {
  mkdirSync(out, { recursive: true })
  const flags = ['-D_WIN32_WINNT=0x0A00', '-municode', '-mconsole', '-O2', '-static', '-Wall', '-Wextra', '-Werror']
  execFileSync(process.env.CC ?? 'gcc', [...flags, join(native, 'admission_fake.c'), '-ladvapi32', '-lshell32', '-lole32', '-luuid', '-o', helper], { stdio: 'inherit', timeout: 60000 })
  execFileSync(process.env.CC ?? 'gcc', [...flags, join(native, 'watchdog.c'), '-o', join(out, 'admission-watchdog.exe')], { stdio: 'inherit', timeout: 60000 })
  const base = mkdtempSync(join(tmpdir(), 'kuro-admission-'))
  process.env.KURO_ADMISSION_TEST_NAMESPACE = randomUUID()
  const cases = ['initial', 'shutdown-unregister-fail', 'shutdown-unregister-hung', 'no-admit', 'eof', 'contention', 'malformed', 'bad-nonce', 'bad-journal', 'zero-proof', 'exec-before-admit',
    'seed-replay', 'seed-bound', 'seed-close', 'seed-eof', 'seed-query', 'seed-deny', 'seed-overflow', 'seed-duplicate', 'seed-invalid', 'seed-autonomous-denied',
    'seed-write-fail', 'seed-write-short', 'seed-write-hung', 'seed-header-fail', 'seed-header-crash', 'seed-header-short', 'existing-seeds-ignored', 'header-seeds-ignored',
    'header-only', 'pending', 'junction-root', 'changed-retained-helper', ...rejectOnly, 'close-replay', 'close-hung', 'duplicate', 'late', 'hung', 'wrong-receipt', 'corrupt', 'legacy', 'wrong-sid', 'wrong-helper',
    'warm-fail', 'warm-hung', 'warm-late', 'core-hung', 'core-late', 'unregister-fail', 'unregister-hung', 'unregister-late',
    'autonomous', 'autonomous-hung', 'autonomous-late', 'autonomous-empty', 'autonomous-source', 'autonomous-unregister-fail', 'autonomous-unregister-hung']
  for (const name of cases) {
    const report = join(base, `${name}.watchdog.json`)
    const command = [process.execPath, self, '--child', name, base].map(quote).join(' ')
    try {
      execFileSync(join(out, 'admission-watchdog.exe'), ['8000', report, process.execPath, command], { stdio: 'inherit', timeout: 12000 })
    } finally {
      if (existsSync(report)) writeFileSync(join(out, `${name}.watchdog.json`), readFileSync(report))
    }
    const guard = JSON.parse(readFileSync(report))
    assert(!guard.watchdogKilled && !guard.lingeringChildren && guard.remaining === 0)
    console.log(`admission native: ${name} passed`)
  }
  writeFileSync(join(out, 'last-run.json'), JSON.stringify({ base, cases, privateOnly: true }, null, 2))
  console.log(`admission native: ${cases.length} passed; private evidence ${base}`)
}
