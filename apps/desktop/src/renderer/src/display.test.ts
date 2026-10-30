import { describe, expect, it } from 'vitest'
import { formatBytes, releaseUrl } from './display'

describe('display values', () => {
  it('formats zero, byte boundaries, and large capacities', () => {
    expect(formatBytes(0)).toBe('0 B')
    expect(formatBytes(1023)).toBe('1,023 B')
    expect(formatBytes(1024)).toBe('1 KiB')
    expect(formatBytes(1024 ** 3 * 1.5)).toBe('1.5 GiB')
    expect(formatBytes(1024 ** 5)).toBe('1,024 TiB')
  })
  it('only offers HTTPS download links, never executable or local schemes', () => {
    expect(releaseUrl('https://example.com/release')).toBe(
      'https://example.com/release'
    )
    for (const input of [
      'javascript:alert(1)',
      'file:///tmp/release',
      'http://example.com',
      'invalid'
    ]) {
      expect(releaseUrl(input)).toBeNull()
    }
  })
})
