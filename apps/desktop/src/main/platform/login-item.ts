import type { LaunchAtLoginStatus, Platform } from '@kuro/core'

/** The slice of Electron's `app` this needs. */
export interface LoginItemApp {
  isPackaged: boolean
  getLoginItemSettings(): { openAtLogin: boolean; status?: string }
  setLoginItemSettings(settings: { openAtLogin: boolean }): void
}

export type LaunchAtLogin = Pick<Platform, 'getLaunchAtLogin' | 'setLaunchAtLogin'>

// shortcut: macOS only (SMAppService mainAppService); Windows waits for 08 to merge (.scratch/launch-at-login/issues/03).
export function createLaunchAtLogin({ os, app }: { os: NodeJS.Platform; app?: LoginItemApp }): LaunchAtLogin {
  function status(): LaunchAtLoginStatus {
    if (os !== 'darwin' || !app) return 'unsupported'
    if (!app.isPackaged) return 'unpackaged'
    const settings = app.getLoginItemSettings()
    if (settings.status === 'requires-approval') return 'requires-approval'
    // `not-registered` / `not-found` mean off; `status` is absent on macOS < 13.
    return (settings.status ?? (settings.openAtLogin ? 'enabled' : '')) === 'enabled' ? 'enabled' : 'disabled'
  }
  return {
    async getLaunchAtLogin() { return status() },
    async setLaunchAtLogin(enabled) {
      const current = status()
      if (current === 'unsupported' || current === 'unpackaged') throw new Error(`Launch at Login is ${current}`)
      app!.setLoginItemSettings({ openAtLogin: enabled })
    },
  }
}
