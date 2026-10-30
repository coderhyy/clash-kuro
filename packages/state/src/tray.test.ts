import { expect, test } from 'vitest'
import { fakeSnapshot } from './fake'
import { buildTrayMenu } from './index'

test.each(['rule', 'global', 'direct'] as const)('tray checks exactly the current %s mode and maps every click to a Command', (mode) => {
  const snapshot = fakeSnapshot({ settings: { ...fakeSnapshot().settings, mode } })
  const menu = buildTrayMenu(snapshot)
  expect(menu).toHaveLength(6)
  expect(menu.filter((item) => item.type === 'radio' && item.checked).map((item) => item.id)).toEqual([`mode.${mode}`])
  expect(menu.map((item) => item.command)).toEqual([
    { name: 'setMode', input: { mode: 'rule' } },
    { name: 'setMode', input: { mode: 'global' } },
    { name: 'setMode', input: { mode: 'direct' } },
    { name: 'setSystemProxy', input: { enabled: true } },
    { name: 'openWindow', input: {} },
    { name: 'quit', input: {} }
  ])
  expect(snapshot.settings.mode).toBe(mode)
})

test('System Proxy click inverts only the snapshot toggle', () => {
  const item = buildTrayMenu(fakeSnapshot({ systemProxy: { enabled: true } })).find((item) => item.id === 'systemProxy')
  expect(item).toMatchObject({ checked: true, command: { name: 'setSystemProxy', input: { enabled: false } } })
})
