import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { SystemProxySettings } from '@kuro/core'

export type Exec = (file: string, args: string[]) => Promise<{ stdout: string; stderr: string }>

const execFileAsync = promisify(execFile)
export const execCommand: Exec = (file, args) => execFileAsync(file, args, { timeout: 10_000, maxBuffer: 1024 * 1024 })

export class SystemProxyPermissionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'SystemProxyPermissionError'
  }
}

export function createSystemProxy(options: { os?: NodeJS.Platform; exec?: Exec } = {}) {
  const exec = options.exec ?? execCommand
  const os = options.os ?? process.platform
  async function run(...args: string[]): Promise<string> {
    if (os !== 'darwin') throw new Error('System Proxy not implemented on this platform')
    const permission = /(?:permission(?:s)?\s+(?:denied|required)|not authorized|not permitted|authorization.*(?:denied|required|failed)|(?:need|require|must).*administrator|administrator.*required|must be root|access.*denied|(?:do not have|insufficient).*permission)/i
    try {
      const result = await exec('/usr/sbin/networksetup', args)
      const output = `${result.stdout}\n${result.stderr}`
      if (permission.test(output)) throw new SystemProxyPermissionError(output.trim())
      if (/^(?:\*+\s*)?Error:/im.test(output)) throw new Error(output.trim())
      return result.stdout.trim()
    } catch (error) {
      if (error instanceof SystemProxyPermissionError) throw error
      const details = error as { message?: string; stdout?: string; stderr?: string }
      const message = [details.message, details.stdout, details.stderr].filter(Boolean).join('\n')
      if (permission.test(message)) throw new SystemProxyPermissionError(message, { cause: error })
      throw error
    }
  }
  async function services(): Promise<string[]> {
    return (await run('-listallnetworkservices')).split(/\r?\n/)
      .map((line) => line.trim()).filter((line) => line && !line.startsWith('*') && !line.startsWith('An asterisk'))
  }
  async function read(service: string, secure: boolean) {
    const output = await run(secure ? '-getsecurewebproxy' : '-getwebproxy', service)
    const fields = Object.fromEntries(output.split(/\r?\n/).map((line) => {
      const colon = line.indexOf(':')
      return [line.slice(0, colon).trim(), line.slice(colon + 1).trim()]
    }))
    const port = Number(fields.Port)
    return fields.Enabled === 'Yes' && fields.Server && Number.isInteger(port) && port > 0 && port <= 65535
      ? { host: fields.Server, port } : null
  }
  async function disable(names: string[]): Promise<void> {
    let failure: unknown
    for (const service of names) {
      for (const command of ['-setwebproxystate', '-setsecurewebproxystate']) {
        try { await run(command, service, 'off') } catch (error) { failure ??= error }
      }
    }
    if (failure) throw failure
  }
  return {
    async getSystemProxy(): Promise<SystemProxySettings | null> {
      // Platform has one proxy value; report the first active HTTP/HTTPS service.
      for (const service of await services()) {
        const proxy = await read(service, false) ?? await read(service, true)
        if (!proxy) continue
        const output = await run('-getproxybypassdomains', service)
        const bypass = output.startsWith("There aren't any bypass domains") ? [] : output.split(/\r?\n/).filter(Boolean)
        return { ...proxy, bypass }
      }
      return null
    },
    async setSystemProxy(settings: SystemProxySettings): Promise<void> {
      if (!settings.host || /[\r\n\0]/.test(settings.host) || !Number.isInteger(settings.port)
        || settings.port < 1 || settings.port > 65535 || settings.bypass.some((entry) => !entry || /[\r\n\0]/.test(entry))) {
        throw new Error('Invalid System Proxy settings')
      }
      // On partial failure, disable services already touched rather than leave a broken proxy enabled.
      const touched: string[] = []
      try {
        for (const service of await services()) {
          touched.push(service)
          await run('-setwebproxy', service, settings.host, String(settings.port))
          await run('-setsecurewebproxy', service, settings.host, String(settings.port))
          await run('-setproxybypassdomains', service, ...(settings.bypass.length ? settings.bypass : ['Empty']))
          await run('-setwebproxystate', service, 'on')
          await run('-setsecurewebproxystate', service, 'on')
        }
      } catch (error) {
        await disable(touched).catch(() => {})
        throw error
      }
    },
    async clearSystemProxy(): Promise<void> {
      await disable(await services())
    },
    async cleanupStaleSystemProxy(port: number): Promise<void> {
      for (const service of await services()) {
        for (const secure of [false, true]) {
          const proxy = await read(service, secure)
          if (proxy?.host === '127.0.0.1' && proxy.port === port) {
            await run(secure ? '-setsecurewebproxystate' : '-setwebproxystate', service, 'off')
          }
        }
      }
    },
  }
}
