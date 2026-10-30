// Renders docs/design/icon-mirage-gold.svg to build/icon.icns and build/icon.ico.
// Run with `bun run icons` (macOS; uses Electron's Chromium to rasterize and iconutil for .icns).
import { app, BrowserWindow } from 'electron'
import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const out = join(root, 'build')

/** ICO with PNG-encoded entries (supported since Windows Vista). */
function ico(pngs) {
  const header = Buffer.alloc(6 + 16 * pngs.length)
  header.writeUInt16LE(1, 2)
  header.writeUInt16LE(pngs.length, 4)
  let offset = header.length
  pngs.forEach(({ size, data }, i) => {
    const e = 6 + 16 * i
    header.writeUInt8(size >= 256 ? 0 : size, e)
    header.writeUInt8(size >= 256 ? 0 : size, e + 1)
    header.writeUInt16LE(1, e + 4)
    header.writeUInt16LE(32, e + 6)
    header.writeUInt32LE(data.length, e + 8)
    header.writeUInt32LE(offset, e + 12)
    offset += data.length
  })
  return Buffer.concat([header, ...pngs.map((p) => p.data)])
}

// No top-level await before 'ready': Electron waits for the ESM entry to finish evaluating first.
app.whenReady().then(async () => {
  const svg = await readFile(join(root, '../../docs/design/icon-mirage-gold.svg'), 'utf8')
  const win = new BrowserWindow({ show: false, webPreferences: { offscreen: true } })
  await win.loadURL('data:text/html,<body></body>')
  const src = 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64')
  /** PNG of the icon drawn at `inner` px, centred on a transparent `px` canvas. */
  async function render(px, inner = px) {
    const url = await win.webContents.executeJavaScript(`new Promise((resolve, reject) => {
      const img = new Image()
      img.onload = () => {
        const c = document.createElement('canvas'); c.width = c.height = ${px}
        const o = (${px} - ${inner}) / 2
        c.getContext('2d').drawImage(img, o, o, ${inner}, ${inner})
        resolve(c.toDataURL('image/png'))
      }
      img.onerror = reject
      img.src = ${JSON.stringify(src)}
    })`)
    return Buffer.from(url.split(',')[1], 'base64')
  }

  await mkdir(out, { recursive: true })
  const tmp = await mkdtemp(join(tmpdir(), 'kuro-icons-'))
  try {
    const iconset = join(tmp, 'icon.iconset')
    await mkdir(iconset)
    // macOS app icons keep a transparent margin: the 100-grid square is drawn at 824/1024 (Apple's template).
    for (const base of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const px = base * scale
        const inner = Math.round(px * 824 / 1024)
        await writeFile(join(iconset, `icon_${base}x${base}${scale === 2 ? '@2x' : ''}.png`), await render(px, inner))
      }
    }
    execFileSync('iconutil', ['-c', 'icns', iconset, '-o', join(out, 'icon.icns')])
    const sizes = [16, 24, 32, 48, 64, 128, 256]
    await writeFile(join(out, 'icon.ico'), ico(await Promise.all(sizes.map(async (size) => ({ size, data: await render(size) })))))
  } finally {
    await rm(tmp, { recursive: true, force: true })
    app.quit()
  }
}).catch((error) => {
  console.error(error)
  process.exitCode = 1
  app.quit()
})
