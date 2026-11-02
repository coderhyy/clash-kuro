// Isolated Electron carrier: no renderer, network request, Core, proxy or registry API.
const { app, BaseWindow } = require('electron')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { performance } = require('node:perf_hooks')
const options = Object.fromEntries(process.argv.filter(x => x.startsWith('--probe-')).map(x => {
  const i = x.indexOf('='); return [x.slice(8, i), x.slice(i + 1)]
}))
if (!options.report || !options.data || !options.case || !options.exit) throw new Error('Use the isolated test runner')
app.setPath('userData', options.data)
app.setPath('sessionData', options.data)
app.disableHardwareAcceleration()
app.on('window-all-closed', () => {})
const result = { name: options.case, exitMode: options.exit, versions: process.versions,
  packaged: app.isPackaged, samples: [], lifecycle: [], stage: 'startup', jsReentries: 0,
  newSetRejected: [], nested: [], candidateAccepted: true }
function save() { fs.writeFileSync(options.report, JSON.stringify(result, null, 2)) }
let active = false, hidden, addon
app.on('before-quit', () => { result.lifecycle.push('before-quit') })
app.on('will-quit', () => { result.lifecycle.push('will-quit'); result.finalReportEpochMs = Date.now(); save() })
function measureClear() {
  const start = performance.now()
  const report = addon.clear()
  const sample = { ...report, wallMs: performance.now() - start }
  result.samples.push(sample)
  assert.equal(addon.startSet(), false)
  return sample
}
async function until(predicate, budget = 2000) {
  const end = performance.now() + budget
  while (!predicate()) {
    if (performance.now() > end) throw new Error('State transition timeout')
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}
async function run() {
  assert.equal(process.versions.electron, '45.1.0')
  const addonPath = app.isPackaged ? path.join(process.resourcesPath, 'native/deadline.node') : path.join(__dirname, 'out/deadline.node')
  addon = require(addonPath)
  result.addonPath = addonPath
  result.modules = addon.modules()
  hidden = new BaseWindow({ show: false, title: 'Kuro deadline isolated session stand-in' })
  const main = new BaseWindow({ show: false, title: 'Disposable main-window stand-in' })
  main.destroy()
  result.hiddenOnly = !hidden.isVisible() && BaseWindow.getAllWindows().length === 1
  assert(result.hiddenOnly)
  hidden.on('close', event => {
    if (!active) return
    event.preventDefault() // ONLY synthetic WM_CLOSE, never a session-end event.
    result.jsReentries++
    const start = performance.now()
    const nested = addon.clear()
    result.nested.push({ ...nested, wallMs: performance.now() - start })
    result.newSetRejected.push(!addon.startSet())
    if (options.case === 'foreign-js-stall') {
      const end = performance.now() + 2100
      while (performance.now() < end) { /* Deliberately uncooperative JS diagnostic. */ }
    }
  })
  // These handlers are never driven by Windows session messages in this experiment.
  hidden.on('query-session-end', () => { throw new Error('Unexpected real session event: abort experiment') })
  hidden.on('session-end', () => { throw new Error('Unexpected real session event: abort experiment') })
  const name = options.case
  const plain = name === 'plain-sync-message'
  const foreign = ['foreign-reentry', 'foreign-js-stall'].includes(name)
  const notify = plain || name.startsWith('aware-') || foreign || name === 'native-handler-stall'
  addon.configureWindow(hidden.getNativeWindowHandle(), +!plain, +notify, +foreign,
    +(name === 'aware-flood'), +(name === 'native-handler-stall'))
  const setDelay = ['set-hang', 'late-set'].includes(name) ? -1 : 120
  const clearDelay = ['clear-hang', 'late-clear', 'watchdog-negative-control'].includes(name) ? -1 : 20
  assert.equal(addon.init(setDelay, clearDelay, +(name === 'log-hang'), +(name === 'lock-hang'), 0), true)
  if (['set-before-clear', 'set-hang', 'late-set'].includes(name)) {
    assert(addon.startSet())
    await until(() => addon.snapshot().set_started === 1)
  }
  result.stage = 'running'; save()
  let timerRan = false
  const timer = setTimeout(() => { timerRan = true }, 0)
  active = true
  const first = measureClear()
  active = false
  result.timerRanDuringWait = timerRan
  clearTimeout(timer)
  assert.equal(timerRan, false, 'Native wait must not run the JS timer queue')
  const second = measureClear()
  assert.equal(second.deadlineTicks, first.deadlineTicks)
  assert(second.wallMs < 100, 'Repeat clear renewed budget')
  assert.equal(second.ok, first.ok)
  if (['foreign-reentry', 'foreign-js-stall'].includes(name)) {
    assert(result.jsReentries > 0, 'Foreign synchronous dispatch diagnostic not exercised')
    assert(result.nested.every(x => x.busy && x.wallMs < 100), 'Reentrant clear waited recursively')
    assert(result.newSetRejected.every(Boolean))
    result.candidateAccepted = false
    result.diagnostic = 'Filtered PeekMessage dispatched foreign WM_CLOSE into arbitrary Electron JS'
    if (name === 'foreign-js-stall') assert(first.wallMs >= 2000)
  } else if (name === 'native-handler-stall') {
    assert(first.wallMs >= 2000)
    assert.equal(first.ok, false)
    result.candidateAccepted = false
    result.diagnostic = 'A synchronous window procedure exceeded the outer wait deadline'
  } else {
    assert(first.wallMs < 1750, `Observed call overrun: ${first.wallMs}`)
  }
  if (plain) {
    assert.equal(first.ok, false)
    assert.equal(first.message_count, 0)
    result.candidateAccepted = false
    result.diagnostic = 'Plain wait: synchronous GUI message blocked until clear returned; not message-chain success'
    await until(() => addon.snapshot().clear_done === 1)
    assert.equal(addon.snapshot().send_ok, 1)
    assert.equal(measureClear().ok, false, 'Late completion must stay uncertain')
  } else if (['success', 'set-before-clear', 'aware-sync-message', 'log-hang'].includes(name)) {
    assert.equal(first.ok, true)
    if (name === 'aware-sync-message') assert(first.message_count > 0 && first.send_ok === 1)
    if (name === 'set-before-clear') assert.deepEqual(first.trace.slice(0, 4), [1, 2, 3, 4])
  } else if (!foreign) {
    assert.equal(first.ok, false)
    assert.equal(first.uncertain, true)
  }
  if (['late-set', 'late-clear'].includes(name)) {
    addon.release()
    await until(() => addon.snapshot().clear_done === 1)
    assert.equal(measureClear().ok, false)
    if (name === 'late-set') assert.deepEqual(addon.snapshot().trace.slice(0, 4), [1, 2, 3, 4])
  }
  result.final = addon.snapshot()
  result.stage = 'assertions-complete'
  result.finalReportEpochMs = Date.now()
  save()
  if (name === 'watchdog-negative-control') {
    setInterval(() => {}, 1000)
    return
  }
  if (options.exit === 'quit') app.quit()
  else app.exit(0)
}
app.whenReady().then(run).catch(error => {
  result.error = error.stack; result.stage = 'failed'; result.finalReportEpochMs = Date.now()
  try { save() } finally { app.exit(1) }
})
