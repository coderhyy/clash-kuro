import { describe, expect, it } from 'vitest'
import { t } from './zh-CN'

describe('zh-CN translations', () => {
  it('translates and interpolates without hiding missing values', () => {
    expect(t('rule')).toBe('规则')
    expect(t('delay', { value: 82 })).toBe('82 ms')
    expect(t('delay')).toBe('{value} ms')
    expect(t('operationFailed', { error: '<script>' })).toBe(
      '操作失败：<script>'
    )
  })
  it('returns missing keys, including object prototype names, verbatim', () => {
    expect(t('missing.key')).toBe('missing.key')
    expect(t('toString')).toBe('toString')
    expect(t('__proto__')).toBe('__proto__')
  })
})
