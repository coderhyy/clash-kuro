import { expect, test, vi } from 'vitest'
import { createLaunchAtLogin, type LoginItemApp } from './login-item'

function fakeApp(settings: ReturnType<LoginItemApp['getLoginItemSettings']>, isPackaged = true) {
  return { isPackaged, getLoginItemSettings: vi.fn(() => settings), setLoginItemSettings: vi.fn<LoginItemApp['setLoginItemSettings']>() }
}

test('maps macOS SMAppService status to Launch at Login status', async () => {
  const cases: Array<[{ openAtLogin: boolean; status?: string }, string]> = [
    [{ openAtLogin: true, status: 'enabled' }, 'enabled'],
    [{ openAtLogin: false, status: 'requires-approval' }, 'requires-approval'],
    [{ openAtLogin: false, status: 'not-registered' }, 'disabled'],
    [{ openAtLogin: false, status: 'not-found' }, 'disabled'],
    [{ openAtLogin: true }, 'enabled'],
    [{ openAtLogin: false }, 'disabled'],
  ]
  for (const [settings, expected] of cases) {
    expect(await createLaunchAtLogin({ os: 'darwin', app: fakeApp(settings) }).getLaunchAtLogin()).toBe(expected)
  }
})

test('registers only from a supported packaged build', async () => {
  const app = fakeApp({ openAtLogin: false, status: 'not-registered' })
  await createLaunchAtLogin({ os: 'darwin', app }).setLaunchAtLogin(true)
  expect(app.setLoginItemSettings).toHaveBeenCalledWith({ openAtLogin: true })

  const dev = fakeApp({ openAtLogin: false }, false)
  const devItem = createLaunchAtLogin({ os: 'darwin', app: dev })
  expect(await devItem.getLaunchAtLogin()).toBe('unpackaged')
  await expect(devItem.setLaunchAtLogin(true)).rejects.toThrow('unpackaged')

  for (const [os, app, expected] of [
    ['win32', fakeApp({ openAtLogin: false }, false), 'unpackaged'],
    ['linux', fakeApp({ openAtLogin: false }), 'unsupported'],
    ['win32', undefined, 'unsupported'],
  ] as const) {
    const item = createLaunchAtLogin({ os, app })
    expect(await item.getLaunchAtLogin()).toBe(expected)
    await expect(item.setLaunchAtLogin(true)).rejects.toThrow(expected)
    if (app) expect(app.setLoginItemSettings).not.toHaveBeenCalled()
  }
  expect(dev.setLoginItemSettings).not.toHaveBeenCalled()
})

test('Windows registers, removes and queries the same hidden startup arguments', async () => {
  const app = fakeApp({ openAtLogin: false, launchItems: [] })
  const item = createLaunchAtLogin({ os: 'win32', app })
  await item.setLaunchAtLogin(true)
  await item.setLaunchAtLogin(false)
  expect(app.getLoginItemSettings).toHaveBeenCalledWith({ args: ['--hidden'] })
  expect(app.setLoginItemSettings.mock.calls).toEqual([
    [{ openAtLogin: true, args: ['--hidden'] }],
    [{ openAtLogin: false, args: ['--hidden'] }],
  ])
})

test('Windows reports only an enabled matching executable and hidden startup entry', async () => {
  const entry = { path: process.execPath, args: ['--hidden'], enabled: true }
  for (const [settings, expected] of [
    [{ openAtLogin: true, launchItems: [entry] }, 'enabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, enabled: false }] }, 'disabled'],
    [{ openAtLogin: false, launchItems: [entry] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, args: [] }] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, args: ['--hidden', '--other'] }] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, path: `${process.execPath}.other` }] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, enabled: false }, { ...entry, args: [] }] }, 'disabled'],
    [{ openAtLogin: true, launchItems: [{ ...entry, path: process.execPath.toUpperCase().replaceAll('/', '\\') }] }, 'enabled'],
  ] satisfies Array<[ReturnType<LoginItemApp['getLoginItemSettings']>, string]>) {
    const app = fakeApp(settings)
    expect(await createLaunchAtLogin({ os: 'win32', app }).getLaunchAtLogin()).toBe(expected)
  }
})
