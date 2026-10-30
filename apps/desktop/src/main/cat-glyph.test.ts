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
})
