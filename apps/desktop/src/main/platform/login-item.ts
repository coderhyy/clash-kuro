import { win32 } from 'node:path'
import type { LaunchAtLoginStatus, Platform } from '@kuro/core'

/** The slice of Electron's `app` this needs. */
export interface LoginItemApp {
  isPackaged: boolean
  getLoginItemSettings(options?: { args: string[] }): {
    openAtLogin: boolean
    status?: string
    launchItems?: Array<{ path: string; args: string[]; enabled: boolean }>
  }
  setLoginItemSettings(settings: { openAtLogin: boolean; args?: string[] }): void
}

export type LaunchAtLogin = Pick<Platform, 'getLaunchAtLogin' | 'setLaunchAtLogin'>

export function createLaunchAtLogin({ os, app }: { os: NodeJS.Platform; app?: LoginItemApp }): LaunchAtLogin {
  function status(): LaunchAtLoginStatus {
    if ((os !== 'darwin' && os !== 'win32') || !app) return 'unsupported'
    if (!app.isPackaged) return 'unpackaged'
    const settings = os === 'win32' ? app.getLoginItemSettings({ args: ['--hidden'] }) : app.getLoginItemSettings()
    if (os === 'win32') {
      const enabled = settings.openAtLogin && settings.launchItems?.some(item => item.enabled
        && win32.normalize(item.path).toLowerCase() === win32.normalize(process.execPath).toLowerCase()
        && item.args.length === 1 && item.args[0] === '--hidden')
      return enabled ? 'enabled' : 'disabled'
    }
    if (settings.status === 'requires-approval') return 'requires-approval'
    // `not-registered` / `not-found` mean off; `status` is absent on macOS < 13.
    return (settings.status ?? (settings.openAtLogin ? 'enabled' : '')) === 'enabled' ? 'enabled' : 'disabled'
  }
  return {
    async getLaunchAtLogin() { return status() },
    async setLaunchAtLogin(enabled) {
      const current = status()
      if (current === 'unsupported' || current === 'unpackaged') throw new Error(`Launch at Login is ${current}`)
      app!.setLoginItemSettings(os === 'win32' ? { openAtLogin: enabled, args: ['--hidden'] } : { openAtLogin: enabled })
    },
  }
}
