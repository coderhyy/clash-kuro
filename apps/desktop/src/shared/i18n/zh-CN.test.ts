import { beforeEach, describe, expect, it } from 'vitest'
import { getLanguage, setLanguage, t } from './index'
import { zhCN } from './zh-CN'
import { en } from './en'
import { buildTrayMenu } from '@kuro/state'
import { fakeSnapshot } from '@kuro/state/fake'

beforeEach(() => setLanguage('zh-CN'))

it('has identical translation keys and interpolation placeholders in both languages', () => {
  expect(Object.keys(en).sort()).toEqual(Object.keys(zhCN).sort())
  for (const key of Object.keys(zhCN) as (keyof typeof zhCN)[]) {
    expect(en[key].match(/\{\w+\}/g)?.sort() ?? []).toEqual(zhCN[key].match(/\{\w+\}/g)?.sort() ?? [])
  }
})

it('switches languages and supports explicit main-process translations without changing renderer language', () => {
  setLanguage('en')
  expect(getLanguage()).toBe('en')
  expect(t('rule')).toBe('Rule')
  expect(t('operationFailed', { error: 'offline' })).toBe('Operation failed: offline')
  expect(t('openWindow', {}, 'zh-CN')).toBe('打开 Clash Kuro')
  expect(getLanguage()).toBe('en')
})

it('translates every tray label in each language', () => {
  const items = buildTrayMenu(fakeSnapshot())
  expect(items.map((item) => t(item.label, {}, 'en'))).toEqual([
    'Rule Mode', 'Global Mode', 'Direct Mode', 'System Proxy', 'Open Clash Kuro', 'Quit'
  ])
  expect(items.map((item) => t(item.label, {}, 'zh-CN'))).toEqual([
    '规则模式', '全局模式', '直连模式', 'System Proxy', '打开 Clash Kuro', '退出'
  ])
})

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
