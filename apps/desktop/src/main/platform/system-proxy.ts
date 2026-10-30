import { execFile } from 'node:child_process'
import { isIPv6 } from 'node:net'
import { promisify } from 'node:util'
import type { SystemProxySettings } from '@kuro/core'

export type Exec = (file: string, args: string[]) => Promise<{ stdout: string; stderr: string }>

const execFileAsync = promisify(execFile)
// execFile never uses a shell; windowsHide keeps helper/Core console windows from flashing.
export const execCommand: Exec = (file, args) => execFileAsync(file, args, { timeout: 10_000, maxBuffer: 1024 * 1024, windowsHide: true })

export class SystemProxyPermissionError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'SystemProxyPermissionError'
  }
}

export interface SystemProxyOptions {
  os?: NodeJS.Platform
  exec?: Exec
  /** Windows: absolute path to kuro-sysproxy.exe. */
  helperPath?: string
  /** Windows: current mixed-port, used when no earlier write is remembered. */
  mixedPort?: () => number
  /** Windows: remembers the last endpoint we wrote so clear can find it after a port change or crash. */
  memory?: { load(): Promise<string | null>; save(server: string | null): Promise<void> }
}

function validSettings(settings: SystemProxySettings): boolean {
  return !!settings.host && !/[\r\n\0]/.test(settings.host) && Number.isInteger(settings.port)
    && settings.port >= 1 && settings.port <= 65535 && settings.bypass.every((entry) => !!entry && !/[\r\n\0]/.test(entry))
}

export function createSystemProxy(options: SystemProxyOptions = {}) {
  const exec = options.exec ?? execCommand
  const os = options.os ?? process.platform
  if (os === 'win32') return createWindowsSystemProxy(exec, options)
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
      if (!validSettings(settings)) throw new Error('Invalid System Proxy settings')
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

// ---- Windows: kuro-sysproxy.exe (issue 08, ADR-0011) --------------------------------------

interface HelperError { code: number; message: string }
interface HelperConnection {
  name: string | null
  flags?: number
  proxyServer?: string | null
  bypass?: string | null
  autoConfigUrl?: string | null
  status?: 'set' | 'cleared' | 'unchanged' | 'notOurs' | 'error'
  error?: HelperError
}
interface HelperResult {
  ok: boolean
  command?: string
  connections?: HelperConnection[]
  error?: HelperError
  notifyError?: HelperError
  rasError?: HelperError
}

const PROXY_TYPE_PROXY = 2
const ERROR_ACCESS_DENIED = 5

/** Thrown when the helper timed out: the proxy may or may not have been changed. */
export class SystemProxyUnknownStateError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'SystemProxyUnknownStateError'
  }
}

/** Parses "host:port" or "http=host:port;https=..." into the single endpoint all entries share. */
export function parseWindowsProxyServer(server: string): { host: string; port: number } | null {
  const endpoints = server.split(';').map((part) => part.trim()).filter(Boolean)
    .map((part) => part.includes('=') ? part.slice(part.indexOf('=') + 1) : part)
  if (!endpoints.length || endpoints.some((endpoint) => endpoint !== endpoints[0])) return null
  const match = /^(.+):([1-9]\d{0,4})$/.exec(endpoints[0]!)
  const port = match ? Number(match[2]) : 0
  return match && port <= 65535 && !/[\s/=]/.test(match[1]!) ? { host: match[1]!, port } : null
}

function createWindowsSystemProxy(exec: Exec, options: SystemProxyOptions) {
  const helper = options.helperPath
  const memory = options.memory
  const manualHint = (port?: number) => `请在 Windows 设置 > 网络和 Internet > 代理 中手动设置 127.0.0.1:${port ?? options.mixedPort?.() ?? 7890}`
  // One helper at a time: overlapping set/clear would race on the same per-connection settings.
  let queue: Promise<unknown> = Promise.resolve()
  const serialize = <T>(operation: () => Promise<T>): Promise<T> => {
    const result = queue.then(operation)
    queue = result.catch(() => {})
    return result
  }

  async function run(args: string[], port?: number): Promise<HelperResult> {
    if (!helper) throw new Error('System Proxy helper path is not configured')
    let stdout: string
    try {
      stdout = (await exec(helper, args)).stdout
    } catch (error) {
      const details = error as NodeJS.ErrnoException & { stdout?: string; killed?: boolean; signal?: string | null }
      if (details.killed || details.code === 'ETIMEDOUT' || details.signal === 'SIGTERM') {
        throw new SystemProxyUnknownStateError(`System Proxy helper timed out; the proxy may be partially changed. ${manualHint(port)}`, { cause: error })
      }
      // Exit code 2 (partial failure) still carries a JSON report on stdout.
      if (typeof details.stdout === 'string' && details.stdout.trim()) stdout = details.stdout
      else {
        // Spawn refused (EACCES/EPERM, quarantined file, AppLocker) => security software or policy.
        const blocked = ['EACCES', 'EPERM', 'ENOENT', 'UNKNOWN'].includes(String(details.code))
        const message = `System Proxy helper could not run (${details.code ?? details.message}). ${manualHint(port)}`
        throw blocked ? new SystemProxyPermissionError(message, { cause: error }) : new Error(message, { cause: error })
      }
    }
    let result: HelperResult
    try { result = JSON.parse(stdout) as HelperResult } catch (error) {
      throw new Error(`System Proxy helper returned invalid output: ${stdout.slice(0, 200)}`, { cause: error })
    }
    if (typeof result !== 'object' || result === null || typeof result.ok !== 'boolean') throw new Error('System Proxy helper returned an unexpected result')
    return result
  }

  function failure(result: HelperResult, port?: number): Error {
    const errors = [
      result.error && `helper: ${result.error.message}`,
      ...(result.connections ?? []).filter((c) => c.error).map((c) => `${c.name ?? 'LAN'}: ${c.error!.message}`),
      result.notifyError && `notify: ${result.notifyError.message}`,
    ].filter(Boolean)
    const denied = [result.error, result.notifyError, ...(result.connections ?? []).map((c) => c.error)]
      // code 0 = the helper's read-back found the value overridden (policy lock).
      .some((error) => error && (error.code === ERROR_ACCESS_DENIED || error.code === 0))
    const message = `System Proxy change failed (${errors.join('; ') || 'unknown error'}). ${manualHint(port)}`
    return denied ? new SystemProxyPermissionError(message) : new Error(message)
  }

  async function expectedServers(extraPort?: number): Promise<string[]> {
    const servers = new Set<string>()
    const remembered = await memory?.load().catch(() => null)
    if (remembered) servers.add(remembered)
    if (extraPort !== undefined) servers.add(`127.0.0.1:${extraPort}`)
    const current = options.mixedPort?.()
    if (current !== undefined) servers.add(`127.0.0.1:${current}`)
    return [...servers].filter((server) => parseWindowsProxyServer(server))
  }

  async function clear(servers: string[]): Promise<void> {
    if (!servers.length) return
    const result = await run(['clear', ...servers.flatMap((server) => ['--expected-server', server])])
    if (!result.ok) throw failure(result)
    await memory?.save(null)
  }

  return {
    getSystemProxy: () => serialize(async (): Promise<SystemProxySettings | null> => {
      const result = await run(['get'])
      const lan = result.connections?.find((connection) => connection.name === null)
      if (!lan || lan.error) throw failure(result)
      if (!((lan.flags ?? 0) & PROXY_TYPE_PROXY) || !lan.proxyServer) return null
      const endpoint = parseWindowsProxyServer(lan.proxyServer)
      return endpoint && { ...endpoint, bypass: (lan.bypass ?? '').split(';').map((entry) => entry.trim()).filter(Boolean) }
    }),
    setSystemProxy: (settings: SystemProxySettings) => serialize(async (): Promise<void> => {
      if (!validSettings(settings) || settings.bypass.some((entry) => entry.includes(';'))) throw new Error('Invalid System Proxy settings')
      const server = `${settings.host}:${settings.port}`
      // WinINet rejects the whole bypass list (error 87) on a bare IPv6 literal such as ::1; it needs [::1].
      const bypass = settings.bypass.map((entry) => isIPv6(entry) ? `[${entry}]` : entry)
      // Remember before writing, so a crash mid-write is still cleaned up on next start.
      await memory?.save(server)
      const result = await run(['set', '--host', settings.host, '--port', String(settings.port), '--bypass', bypass.join(';')], settings.port)
      if (result.ok) return
      // Partial write: undo connections that did take our endpoint rather than leave a mix.
      await clear([server]).catch(() => {})
      throw failure(result, settings.port)
    }),
    clearSystemProxy: () => serialize(async () => clear(await expectedServers())),
    cleanupStaleSystemProxy: (port: number) => serialize(async () => clear(await expectedServers(port))),
  }
}
