// Cat paths on the 100 grid, shared with docs/design/icon-*.svg.
const HEAD = 'M19 15 39 31Q50 28.5 61 31L81 15Q86.5 11.5 86.5 18L84.5 44Q92 55 89 69Q83 90 50 90Q17 90 11 69Q8 55 15.5 44L13.5 18Q13.5 11.5 19 15Z'
const EYES = 'M24.5 57Q36 49.5 44.5 61Q34 67.5 24.5 57ZM75.5 57Q64 49.5 55.5 61Q66 67.5 75.5 57Z'
const SLITS = 'M35 52.6Q37.2 58.5 35 64.6Q32.8 58.5 35 52.6ZM65 52.6Q67.2 58.5 65 64.6Q62.8 58.5 65 52.6Z'
// Closed eyes: downward arcs, thickened into tapered lenses so they survive at 18 px.
const CLOSED = 'M24 57Q34.5 69 45 57Q34.5 58 24 57ZM76 57Q65.5 69 55 57Q65.5 58 76 57Z'

type Polygon = [number, number][]

/** Flattens an absolute M/L/Q/Z path (implicit repeats allowed) into polygons. */
export function flatten(d: string, steps = 8): Polygon[] {
  const tokens = d.match(/[MLQZ]|-?\d*\.?\d+/g) ?? []
  const polys: Polygon[] = []
  let poly: Polygon = []
  let cmd = ''
  let i = 0
  const num = (): number => Number(tokens[i++])
  while (i < tokens.length) {
    if (/[MLQZ]/.test(tokens[i]!)) cmd = tokens[i++]!
    else if (cmd === 'M') cmd = 'L'
    if (cmd === 'Z') { if (poly.length) polys.push(poly); poly = []; continue }
    if (cmd === 'M') { if (poly.length) polys.push(poly); poly = [[num(), num()]]; continue }
    if (cmd === 'L') { poly.push([num(), num()]); continue }
    const [x0, y0] = poly[poly.length - 1]!
    const cx = num(), cy = num(), x = num(), y = num()
    for (let s = 1; s <= steps; s++) {
      const t = s / steps, u = 1 - t
      poly.push([u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y])
    }
  }
  if (poly.length) polys.push(poly)
  return polys
}

function inside(polys: Polygon[], x: number, y: number): boolean {
  let hit = false
  for (const p of polys) {
    for (let a = 0, b = p.length - 1; a < p.length; b = a++) {
      const [xa, ya] = p[a]!, [xb, yb] = p[b]!
      if (ya > y !== yb > y && x < ((xb - xa) * (y - ya)) / (yb - ya) + xa) hit = !hit
    }
  }
  return hit
}

const head = flatten(HEAD), eyes = flatten(EYES), slits = flatten(SLITS), closed = flatten(CLOSED)

/**
 * Alpha mask (0-255, row-major) of the cat head at size x size px, 4x4 supersampled.
 * Open: eyes cut out with the slit pupils kept. Closed: arcs cut out.
 */
export function catMask(size: number, open: boolean): Uint8Array {
  // Head spans x 8..92, y 11.5..90 on the 100 grid; fit its width and centre it.
  const scale = size / 86, ox = 50 - size / scale / 2, oy = 51 - size / scale / 2
  const out = new Uint8Array(size * size)
  const n = 4
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let hits = 0
      for (let sy = 0; sy < n; sy++) {
        for (let sx = 0; sx < n; sx++) {
          const x = ox + (px + (sx + 0.5) / n) / scale, y = oy + (py + (sy + 0.5) / n) / scale
          if (!inside(head, x, y)) continue
          const cut = open ? inside(eyes, x, y) && !inside(slits, x, y) : inside(closed, x, y)
          if (!cut) hits++
        }
      }
      out[py * size + px] = Math.round((hits / (n * n)) * 255)
    }
  }
  return out
}
