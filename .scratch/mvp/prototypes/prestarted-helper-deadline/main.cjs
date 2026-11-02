// Isolated fake-operation carrier. No Core, proxy, registry or session APIs.
const { app } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const opts = Object.fromEntries(process.argv.filter(x => x.startsWith('--probe-')).map(x => {
  const i = x.indexOf('='); return [x.slice(8, i), x.slice(i + 1)]
}))
if (!opts.dir || !opts.case) throw new Error('Use the supervised test runner')
app.setPath('userData', path.join(opts.dir, 'profile'))
app.setPath('sessionData', path.join(opts.dir, 'profile'))
app.disableHardwareAcceleration()
const state = { electron: process.versions.electron, versions: process.versions, pid: process.pid, events: [] }
function record(event) {
  state.events.push({ event, at: Date.now() })
  fs.writeFileSync(path.join(opts.dir, 'electron.json'), JSON.stringify(state, null, 2))
}
app.whenReady().then(() => {
  if (process.versions.electron !== '45.1.0') throw new Error('Unexpected Electron')
  const helper = spawn(path.join(__dirname, 'out/helper.exe'), [opts.case, path.join(opts.dir, 'helper.json')],
    // Detach from the Electron/libuv child-lifetime job, NOT from the external test Job.
    { detached: true, windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] })
  state.helperPid = helper.pid
  record('spawned')
  helper.stdin.on('error', error => record(`stdin-error:${error.code}`))
  helper.on('error', error => { record(`spawn-error:${error.code}`); app.exit(2) })
  let buffer = ''
  helper.stdout.on('data', data => {
    buffer += data
    while (buffer.includes('\n')) {
      const i = buffer.indexOf('\n'), line = buffer.slice(0, i); buffer = buffer.slice(i + 1)
      record(line)
      if (line === 'ready') {
        if (opts.case === 'window-stall') {
          record('stall-start')
          helper.stdin.write('W')
          const end = performance.now() + 4000
          while (performance.now() < end) { /* Native window dispatch must not need JS. */ }
          record('stall-end')
        } else if (opts.case === 'ipc-before') helper.stdin.end()
        else helper.stdin.write('C')
      }
      if (line === 'triggered') {
        if (opts.case === 'repeat') setTimeout(() => { record('repeat-sent'); helper.stdin.write('CCCCCCC') }, 1200)
        if (opts.case === 'electron-exit') { record('early-exit'); app.exit(0); return }
        if (opts.case === 'ipc-after') helper.stdin.end()
        if (opts.case === 'electron-hang-negative') {
          record('permanent-stall')
          for (;;) { /* Only the external rescue may end this carrier. */ }
        }
        if (opts.case === 'electron-stall') {
          record('stall-start')
          const end = performance.now() + 4000
          while (performance.now() < end) { /* Test-only blocked GUI thread. */ }
          record('stall-end')
        }
      }
    }
  })
  helper.on('exit', (code, signal) => { state.helperExit = { code, signal }; record('helper-exit'); app.exit(0) })
})
