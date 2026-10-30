import { app, BrowserWindow } from 'electron'
import { join } from 'node:path'

function createWindow(): void {
  const win = new BrowserWindow({
    width: 960,
    height: 640,
    webPreferences: { preload: join(__dirname, '../preload/index.js'), sandbox: true }
  })
  if (process.env.ELECTRON_RENDERER_URL) void win.loadURL(process.env.ELECTRON_RENDERER_URL)
  else void win.loadFile(join(__dirname, '../renderer/index.html'))
}

void app.whenReady().then(() => {
  createWindow()
  // Smoke test hook for packaging verification.
  if (process.env.TERN_SMOKE) {
    console.log('TERN_SMOKE_OK')
    app.quit()
  }
})
