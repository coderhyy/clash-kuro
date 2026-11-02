import { createHash } from 'node:crypto'
import { expect, test } from 'vitest'
import { catMask, flatten } from './cat-glyph'

test('flatten handles implicit lineto and quadratic segments', () => {
  const [poly] = flatten('M0 0 10 0Q10 10 0 10Z', 2)
  expect(poly).toEqual([[0, 0], [10, 0], [7.5, 7.5], [0, 10]])
})

test('open and closed cats differ only around the eyes', () => {
  const size = 86
  const open = catMask(size, true), shut = catMask(size, false)
  const at = (m: Uint8Array, x: number, y: number): number => m[y * size + x]!
  // Corner is outside the head, chin is solid in both states.
  expect(at(open, 0, 0)).toBe(0)
  expect(at(open, 43, 70)).toBe(255)
  expect(at(shut, 43, 70)).toBe(255)
  // At size 86 one px is one grid unit (offset 7, 8). Grid (33.5, 54.5): inside the open eye, above the closed arc.
  const eye = [33 - 7, 54 - 8] as const
  expect(at(open, ...eye)).toBeLessThan(128)
  expect(at(shut, ...eye)).toBeGreaterThan(128)
  expect(open.some((v, i) => v !== shut[i])).toBe(true)
  expect(createHash('sha256').update(open).digest('hex')).toBe('0af7a26faf4383eff833e83205c9a6cfbea4663d1784183f868650a7d6a0a23b')
  expect(createHash('sha256').update(shut).digest('hex')).toBe('0dcf1237562d781a973feb9c4b279b0f106af56b28f84523e73cefc2d363eb09')
})

test.each([
  { size: 18, open: '7a24bab908aff0316edee163ebfb595fdd913c545a62c5fcb40d8db5c9228949', shut: 'ff5ec52bb76daadcd18b0ef23ce15c6500a7acdfc3f6ee4fa412cb9da678fec4' },
  { size: 36, open: '02a84217c3d62af4b1fc09cd17c70c8c0c7e11c25cbdd2de54a94c05c1d57aed', shut: '0ef59f7f8f740db681c632f922e7f933ad69170c4997ff0212ec1639d165da78' },
])('tray masks preserve every alpha byte at $size px', ({ size, open, shut }) => {
  expect(createHash('sha256').update(catMask(size, true)).digest('hex')).toBe(open)
  expect(createHash('sha256').update(catMask(size, false)).digest('hex')).toBe(shut)
})
