import { expect, test, vi } from 'vitest'
import { createLaunchAtLogin, type LoginItemApp } from './login-item'

function fakeApp(settings: { openAtLogin: boolean; status?: string }, isPackaged = true) {
  return { isPackaged, getLoginItemSettings: () => settings, setLoginItemSettings: vi.fn<LoginItemApp['setLoginItemSettings']>() }
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

test('registers only from a packaged macOS build', async () => {
  const app = fakeApp({ openAtLogin: false, status: 'not-registered' })
  await createLaunchAtLogin({ os: 'darwin', app }).setLaunchAtLogin(true)
  expect(app.setLoginItemSettings).toHaveBeenCalledWith({ openAtLogin: true })

  const dev = fakeApp({ openAtLogin: false }, false)
  const devItem = createLaunchAtLogin({ os: 'darwin', app: dev })
  expect(await devItem.getLaunchAtLogin()).toBe('unpackaged')
  await expect(devItem.setLaunchAtLogin(true)).rejects.toThrow('unpackaged')

  const win = fakeApp({ openAtLogin: false })
  const winItem = createLaunchAtLogin({ os: 'win32', app: win })
  expect(await winItem.getLaunchAtLogin()).toBe('unsupported')
  await expect(winItem.setLaunchAtLogin(true)).rejects.toThrow('unsupported')
  expect(dev.setLoginItemSettings).not.toHaveBeenCalled()
  expect(win.setLoginItemSettings).not.toHaveBeenCalled()
})
