// Isolated manual experiment. Native helper owns session events and cleanup.
const { app, BaseWindow, Tray, Menu, nativeImage } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const data = process.argv.find(x => x.startsWith('--session-dir='))?.slice(14)
const fixture = process.argv.includes('--fixture-close')
if (!data || !path.isAbsolute(data)) throw new Error('Require absolute --session-dir')
if (!fs.existsSync(path.join(data, 'lan-ras.bin')) && !fixture) throw new Error('Prepare backup first')
// One manual attempt per backup directory; retain this marker even after exit.
fs.writeFileSync(path.join(data, 'attempt.json'), JSON.stringify({ pid: process.pid, at: Date.now(), fixture }), { flag: 'wx' })
app.setPath('userData', path.join(data, 'electron-profile'))
app.setPath('sessionData', path.join(data, 'electron-profile'))
app.disableHardwareAcceleration()
const state = { pid: process.pid, startedAt: Date.now(), fixture, ready: false, events: [] }
const record = event => {
  state.events.push({ event, at: Date.now() })
  fs.writeFileSync(path.join(data, 'carrier.json'), JSON.stringify(state, null, 2))
}
let child, tray, window, exiting = false
const close = () => child?.stdin.write(Buffer.from([2, 0, 0, 0, 0, 0, 0, 0]))
app.on('before-quit', event => {
  if (!exiting && child) { event.preventDefault(); record('normal-close-request'); close() }
})
app.whenReady().then(() => {
  if (process.versions.electron !== '45.1.0') throw new Error('Wrong Electron version')
  window = new BaseWindow({ show: false, width: 1, height: 1 })
  // These are evidence only: do not race native delivery by issuing an IPC clear.
  window.on('query-session-end', () => record('query-session-end'))
  window.on('session-end', () => record('session-end'))
  const pixels = Buffer.alloc(16 * 16 * 4, 255)
  for (let i = 0; i < pixels.length; i += 4) { pixels[i] = 40; pixels[i + 1] = 130; pixels[i + 2] = 220 }
  tray = new Tray(nativeImage.createFromBitmap(pixels, { width: 16, height: 16 }))
  tray.setToolTip('Kuro isolated session experiment - not production')
  tray.setContextMenu(Menu.buildFromTemplate([{ label: 'Clear and exit experiment', click: close }]))
  const exe = path.join(__dirname, 'bin', fixture ? 'session-fake.exe' : 'session.exe')
  child = spawn(exe, ['arm', path.join(data, 'lan-ras.bin'), path.join(data, 'helper-report.json'),
    path.join(__dirname, 'bin/mihomo.exe'), path.join(data, 'core')],
  { detached: true, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
  state.helperPid = child.pid
  state.helperStartedAt = Date.now()
  record('helper-spawned')
  child.stdin.on('error', error => record(`pipe-error:${error.code}`))
  child.on('error', error => { record(`spawn-error:${error.code}`); exiting = true; app.exit(2) })
  let buffer = ''
  child.stdout.on('data', bytes => {
    buffer += bytes
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'), line = buffer.slice(0, end).trim()
      buffer = buffer.slice(end + 1)
      record(`native:${line}`)
      if (line === 'ready') {
        state.ready = true; record('ready')
        if (fixture) close()
      }
    }
  })
  child.stderr.on('data', bytes => record(`native-stderr:${bytes.toString().slice(0, 4096)}`))
  child.on('close', (code, signal) => {
    state.helperExit = { code, signal }; record('helper-exited')
    exiting = true; app.exit(code === 0 ? 0 : 2)
  })
})
