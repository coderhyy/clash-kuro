import { nativeImage, type NativeImage } from 'electron'
import { catMask } from './cat-glyph'

/** 18x18 template cat head drawn in code: eyes cut out while Core runs, closed-eye arcs when stopped. */
export function trayIcon(running: boolean): NativeImage {
  const image = nativeImage.createEmpty()
  for (const scale of [1, 2]) {
    const size = 18 * scale
    const mask = catMask(size, running)
    const buf = Buffer.alloc(size * size * 4)
    // BGRA black with mask alpha; template images only use alpha.
    mask.forEach((a, i) => buf.writeUInt32LE((a << 24) >>> 0, i * 4))
    image.addRepresentation({ scaleFactor: scale, width: size, height: size, buffer: nativeImage.createFromBitmap(buf, { width: size, height: size }).toPNG() })
  }
  image.setTemplateImage(true)
  return image
}
