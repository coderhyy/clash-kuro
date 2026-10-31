import { beforeEach, describe, expect, it } from 'vitest'
import { date, formatBytes, releaseUrl } from './display'
import { setLanguage } from '../../shared/i18n'

beforeEach(() => setLanguage('zh-CN'))

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
  it('formats dates and numbers using the current language', () => {
    const value = new Date(2026, 9, 31).getTime()
    expect(date(value)).toBe('2026/10/31')
    setLanguage('en')
    expect(date(value)).toBe('10/31/2026')
    expect(formatBytes(1023)).toBe('1,023 B')
    expect(formatBytes(1536)).toBe('1.5 KiB')
    setLanguage('zh-CN')
    expect(date(value)).toBe('2026/10/31')
  })
})
