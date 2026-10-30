import { nativeImage, type NativeImage } from 'electron'

/** 18x18 template icon drawn in code (a ring with a dot), so no binary asset is needed. */
export function trayIcon(): NativeImage {
  const scale = 2
  const size = 18 * scale
  const buf = Buffer.alloc(size * size * 4)
  const c = (size - 1) / 2
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const d = Math.hypot(x - c, y - c) / scale
      const on = (d > 5.5 && d < 7.5) || d < 2.5
      // BGRA; template images only use alpha.
      buf.writeUInt32LE(on ? 0xff000000 : 0, (y * size + x) * 4)
    }
  }
  const image = nativeImage.createFromBitmap(buf, { width: size, height: size, scaleFactor: scale })
  image.setTemplateImage(true)
  return image
}
