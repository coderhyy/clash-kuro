import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const { residentClient } = createRequire(import.meta.url)('./out/client.cjs')
if (process.argv[2] === '--child') {
  const [mode, dir] = process.argv.slice(3)
  const exe = join(root, 'out/resident-fake.exe'), log = join(dir, 'helper.json')
  const child = spawn(exe, ['serve', '--core', exe, '--data', dir, '--log', log,
    '--expected-server', '127.0.0.1:7891'], { detached: true, windowsHide: true, stdio: 'pipe' })
  const client = residentClient(child)
  let marker = ''
  let entered
  const setEntered = new Promise(resolve => { entered = resolve })
  child.stderr.on('data', data => { marker += data; if (marker.includes('set-start\n')) entered() })
  await client.ready
  assert.equal(JSON.parse((await client.request(['get'])).stdout).flags, 1)
  const setting = client.request(['set', '--host', '127.0.0.1', '--port', '7891']).then(() => 'done', () => 'rejected')
  if (mode === 'late-set' || mode === 'set-hang') {
    await setEntered
    client.close(); client.close()
    assert.equal(await setting, 'rejected')
  } else {
    assert.equal(await setting, 'done')
    assert.equal(JSON.parse((await client.request(['get'])).stdout).flags, 3)
    client.close()
  }
  await assert.rejects(client.request(['set']), /closing|exited/)
  const exit = await client.exited
  const report = JSON.parse(readFileSync(log, 'utf8'))
  const timeout = mode.endsWith('hang')
  assert.equal(exit.code, timeout ? 42 : 0)
  assert.equal(report.command, 'shutdown')
  assert.equal(report.ok, !timeout)
  assert.equal(report.timedOut, timeout)
  assert.equal(report.coreGone, true)
  assert(Number.isInteger(report.corePid) && report.corePid > 0)
  assert.notEqual(report.corePid, child.pid)
  assert(report.durationMs < 2350)
  if (timeout) assert(report.durationMs >= 1490)
  if (mode === 'late-set') assert(report.durationMs >= 300)
  writeFileSync(join(dir, 'result.json'), JSON.stringify({ mode, pid: child.pid, exit, report }))
} else {
  const run = join(root, 'out', `resident-${Date.now()}`)
  mkdirSync(run, { recursive: true })
  const quote = s => '"' + s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
  const results = []
  for (const mode of ['normal', 'late-set', 'clear-hang', 'set-hang']) {
    const dir = join(run, mode); mkdirSync(dir)
    const command = [process.execPath, fileURLToPath(import.meta.url), '--child', mode, dir].map(quote).join(' ')
    const watchdog = spawn(join(root, 'out/watchdog.exe'), ['8000', join(dir, 'supervisor.json'), process.execPath, command],
      { windowsHide: true, stdio: 'pipe' })
    let output = '', rescued = false
    watchdog.stdout.on('data', data => { output += data })
    watchdog.stderr.on('data', data => { output += data })
    const guard = setTimeout(() => { rescued = true; watchdog.kill('SIGKILL') }, 12000)
    const code = await new Promise((resolve, reject) => { watchdog.once('error', reject); watchdog.once('exit', resolve) })
    clearTimeout(guard)
    assert.equal(rescued, false)
    assert.equal(code, 0, output)
    const supervisor = JSON.parse(readFileSync(join(dir, 'supervisor.json')))
    assert.equal(supervisor.watchdogKilled, false)
    assert.equal(supervisor.lingeringChildren, false)
    assert.equal(supervisor.remaining, 0)
    const result = JSON.parse(readFileSync(join(dir, 'result.json')))
    assert(supervisor.observedPids.includes(result.pid))
    assert(supervisor.observedPids.includes(result.report.corePid))
    results.push({ ...result, supervisor })
    console.log(`PASS ${mode}: helper exit=${result.exit.code}, clear timeout=${result.report.timedOut}, no rescue/remaining processes`)
  }
  writeFileSync(join(run, 'results.json'), JSON.stringify(results, null, 2))
  console.log(run)
}
