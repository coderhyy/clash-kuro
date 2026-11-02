// Each case gets a fresh process. Never calls real proxy APIs.
const assert = require('node:assert/strict')
const { performance } = require('node:perf_hooks')
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads')
const addon = require('./out/deadline.node')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const samples = []
async function until(predicate) {
  const end = performance.now() + 2000
  while (!predicate()) {
    assert(performance.now() < end, 'state transition did not arrive within 2s')
    await sleep(5)
  }
}
function clear(forceEarlyTimeout = false) {
  const start = performance.now()
  const result = addon.clear(forceEarlyTimeout)
  const wallMs = performance.now() - start
  samples.push({ wallMs, ...result })
  // This is an observation threshold, not a real-time scheduling guarantee.
  assert(wallMs < 1750, `1500ms budget exceeded observation tolerance: ${wallMs}`)
  assert.equal(addon.startSet(), false, 'set must be rejected once closing')
  return result
}
function timedOut(result) {
  assert.equal(result.ok, false)
  assert.equal(result.uncertain, true)
  assert.equal(result.timeout_latched, 1)
}
function repeatWithoutRenewal(first) {
  for (let i = 0; i < 3; i++) {
    const result = clear()
    timedOut(result)
    assert.equal(result.deadlineTicks, first.deadlineTicks)
    assert(samples.at(-1).wallMs < 100, 'repeat event renewed the budget')
  }
}

async function run(name) {
  if (name.startsWith('env-')) {
    const worker = new Worker(__filename, { workerData: { hold: name !== 'env-natural' } })
    const exited = new Promise((resolve, reject) => { worker.once('exit', resolve); worker.once('error', reject) })
    const message = await new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject) })
    timedOut(message.report)
    samples.push(message.report)
    if (name !== 'env-natural') assert.equal(await worker.terminate(), 1)
    await exited
    assert.equal(addon.snapshot().cleanup_called, 1, 'native cleanup hook not observed')
    assert.equal(addon.snapshot().thread_exited, 0, 'fault must still be active at environment teardown')
    if (name === 'env-late-return') {
      addon.release()
      await until(() => addon.snapshot().thread_exited === 1)
      assert.equal(addon.snapshot().set_done, 1)
      assert.equal(addon.snapshot().clear_started, 0, 'abandoned environment must not start another operation')
      assert.deepEqual(addon.snapshot().trace, [1, 2, 6])
    }
    return
  }
  const configs = {
    success: [0, 80, 0, 0, 0],
    'set-before-clear': [180, 60, 0, 0, 0],
    'queued-set': [80, 40, 0, 0, 0],
    'clear-hang': [0, -1, 0, 0, 0],
    'set-hang': [-1, 0, 0, 0, 0],
    'late-set': [-1, 30, 0, 0, 0],
    'late-clear': [0, -1, 0, 0, 0],
    'lock-hang': [0, 0, 0, 1, 0],
    'log-hang': [0, 30, 1, 0, 0],
    'init-hang': [0, 0, 0, 0, 1],
    'partial-budget': [0, -1, 0, 0, 1],
    'explicit-exit': [0, -1, 0, 0, 0],
    'early-timeout': [0, -1, 0, 0, 0],
    'watchdog-negative-control': [0, 0, 0, 0, 0],
  }
  const start = performance.now()
  const ready = addon.init(...configs[name])
  const initMs = performance.now() - start
  samples.push({ initMs, ready })
  assert(initMs < 600, 'initializer exceeded observation threshold')
  assert.equal(ready, !['init-hang', 'partial-budget'].includes(name))
  assert.throws(() => addon.init(0, 0, 0, 0, 0), /one init/)
  if (['set-before-clear', 'queued-set', 'set-hang', 'late-set'].includes(name)) {
    assert.equal(addon.startSet(), true)
    assert.equal(addon.startSet(), false, 'prototype admits only one fake set')
    if (name !== 'queued-set') await until(() => addon.snapshot().set_started === 1)
  }
  let timerRan = false
  const timer = setTimeout(() => { timerRan = true }, 0)
  const first = clear(name === 'early-timeout')
  assert.equal(timerRan, false, 'test requires JS event loop to be blocked during clear')
  clearTimeout(timer)
  if (['success', 'set-before-clear', 'queued-set', 'log-hang', 'watchdog-negative-control'].includes(name)) {
    assert.equal(first.ok, true, 'native completion must not depend on JS callback')
    assert.equal(first.uncertain, false)
    if (name.includes('set')) assert.deepEqual(first.trace.slice(0, 4), [1, 2, 3, 4])
    const again = clear()
    assert.equal(again.ok, true)
    assert.equal(again.deadlineTicks, first.deadlineTicks)
    if (name === 'log-hang') {
      await until(() => addon.snapshot().trace.includes(5))
      assert.equal(addon.snapshot().thread_exited, 0)
    }
    return
  }
  if (name === 'init-hang') {
    assert.equal(first.ok, false)
    assert.equal(first.ready_flag, 0)
    assert.equal(first.clear_started, 0)
    return
  }
  if (name === 'partial-budget') {
    assert.equal(first.ok, false)
    await sleep(350)
    addon.release(16)
    await until(() => addon.snapshot().ready_flag === 1)
    const second = clear()
    timedOut(second)
    assert.equal(second.deadlineTicks, first.deadlineTicks)
    assert(samples.at(-1).wallMs < 1350, 'second event received a fresh 1500ms budget')
    repeatWithoutRenewal(second)
    return
  }
  timedOut(first)
  repeatWithoutRenewal(first)
  if (name === 'early-timeout') {
    assert(samples[1].wallMs < 100)
    addon.release()
    await until(() => addon.snapshot().clear_done === 1)
    assert(addon.snapshot().completedTicks < first.deadlineTicks)
    timedOut(clear()) // A prior timeout stays uncertain even if the operation later finishes in budget.
  }
  if (name === 'set-hang') assert.equal(first.clear_started, 0)
  if (name === 'late-set' || name === 'late-clear') {
    addon.release()
    await until(() => addon.snapshot().clear_done === 1)
    const late = clear()
    timedOut(late)
    assert(late.completedTicks > late.deadlineTicks)
    if (name === 'late-set') assert.deepEqual(late.trace.slice(0, 4), [1, 2, 3, 4])
  }
}

if (!isMainThread) {
  ;(async () => {
    assert.equal(addon.init(-1, 0, 0, 0, 0), true)
    assert.equal(addon.startSet(), true)
    await until(() => addon.snapshot().set_started === 1)
    const report = clear()
    if (workerData.hold) parentPort.on('message', () => {})
    parentPort.postMessage({ report })
    // env-natural ends here; the native thread is still stuck in fake set.
  })().catch(error => { throw error })
} else {
  const name = process.argv[2]
  run(name).then(() => {
    if (name === 'watchdog-negative-control') setInterval(() => {}, 1000)
    const result = { name, samples, final: addon.snapshot() }
    // The parent must observe exit code 0 after this, not merely this message.
    process.send(result, error => {
      if (error) throw error
      if (name === 'explicit-exit') process.exit(0)
    })
  }).catch(error => {
    console.error(error)
    process.exitCode = 1
  })
}
