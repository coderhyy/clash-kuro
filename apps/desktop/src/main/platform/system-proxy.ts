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
  /** Optional diagnostics for standalone helper calls; native owner logging is separate. */
  logPath?: string
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
    const output = await run('-listallnetworkservices')
    if (!output) throw new Error('System Proxy service enumeration unconfirmed')
    return output.split(/\r?\n/)
      .map((line) => line.trim()).filter((line) => line && !line.startsWith('*') && !line.startsWith('An asterisk'))
  }
  type ProxyValue = { enabled: boolean; host: string; port: number; authenticated: boolean }
  type OwnedProxy = { service: string; secure: boolean; before: ProxyValue; expected: ProxyValue[] }
  type OwnedBypass = { service: string; before: string[]; expected: string[][] }
  const owned: OwnedProxy[] = []
  const bypassOwned: OwnedBypass[] = []
  let queue: Promise<unknown> = Promise.resolve()
  const serialize = <T>(operation: () => Promise<T>): Promise<T> => {
    const result = queue.then(operation)
    queue = result.catch(() => {})
    return result
  }
  const equal = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)
  async function read(service: string, secure: boolean): Promise<ProxyValue> {
    const output = await run(secure ? '-getsecurewebproxy' : '-getwebproxy', service)
    const fields = new Map<string, string>()
    for (const line of output.split(/\r?\n/).filter(line => line.trim())) {
      const colon = line.indexOf(':')
      const key = line.slice(0, colon).trim()
      if (colon < 0 || fields.has(key)) throw new Error(`System Proxy state unknown for ${service}`)
      fields.set(key, line.slice(colon + 1).trim())
    }
    const enabled = fields.get('Enabled'), host = fields.get('Server'), rawPort = fields.get('Port')
    const auth = fields.get('Authenticated Proxy Enabled')
    const port = Number(rawPort)
    if (!['Yes', 'No'].includes(enabled ?? '') || host === undefined || /[\r\n\0]/.test(host)
      || !/^(?:0|[1-9]\d{0,4})$/.test(rawPort ?? '') || port > 65535
      || !['0', '1'].includes(auth ?? '') || (enabled === 'Yes' && (!host || port === 0))) {
      throw new Error(`System Proxy state unknown for ${service}`)
    }
    return { enabled: enabled === 'Yes', host, port, authenticated: auth === '1' }
  }
  async function readBypass(service: string): Promise<string[]> {
    const output = await run('-getproxybypassdomains', service)
    if (output === "There aren't any bypass domains set on this service." || output === `There aren't any bypass domains set on ${service}.`) return []
    const entries = output.split(/\r?\n/)
    if (!output || entries.some(entry => !entry || /[\0]/.test(entry) || entry === 'Empty')) {
      throw new Error(`System Proxy bypass state unknown for ${service}`)
    }
    return entries
  }
  async function writeProxy(record: OwnedProxy, target: ProxyValue): Promise<void> {
    const set = record.secure ? '-setsecurewebproxy' : '-setwebproxy'
    const state = record.secure ? '-setsecurewebproxystate' : '-setwebproxystate'
    let current = await read(record.service, record.secure)
    if (!record.expected.some(value => equal(value, current))) throw new Error(`System Proxy changed for ${record.service}; preserved`)
    if (current.host !== target.host || current.port !== target.port || current.authenticated !== target.authenticated) {
      const configured = { ...target, enabled: true, authenticated: false }
      record.expected = [current, configured]
      // networksetup(8): setting an endpoint turns it on; explicitly disable authentication.
      await run(set, record.service, target.host, String(target.port), 'off')
      current = await read(record.service, record.secure)
      if (!equal(current, configured)) throw new Error(`System Proxy write unconfirmed for ${record.service}`)
      record.expected = [current]
    }
    if (current.enabled !== target.enabled) {
      record.expected = [current, target]
      await run(state, record.service, target.enabled ? 'on' : 'off')
      current = await read(record.service, record.secure)
      if (!equal(current, target)) throw new Error(`System Proxy write unconfirmed for ${record.service}`)
      record.expected = [current]
    }
  }
  async function writeBypass(record: OwnedBypass, target: string[]): Promise<void> {
    const current = await readBypass(record.service)
    if (!record.expected.some(value => equal(value, current))) throw new Error(`System Proxy bypass changed for ${record.service}; preserved`)
    if (equal(current, target)) return
    record.expected = [current, target]
    await run('-setproxybypassdomains', record.service, ...(target.length ? target : ['Empty']))
    if (!equal(await readBypass(record.service), target)) throw new Error(`System Proxy bypass write unconfirmed for ${record.service}`)
    record.expected = [target]
  }
  async function clearOwned(): Promise<void> {
    let failure: unknown
    for (const record of [...owned].reverse()) {
      try {
        const current = await read(record.service, record.secure)
        if (!record.expected.some(value => equal(value, current))) throw new Error(`System Proxy changed for ${record.service}; preserved`)
        // A previously disabled endpoint need not be re-created: restore its effective off state.
        // The inactive host/port may retain our value; no previous credentials are reconstructed.
        const target = record.before.enabled ? record.before : { ...current, enabled: false }
        await writeProxy(record, target)
        owned.splice(owned.indexOf(record), 1)
      } catch (error) { failure ??= error }
    }
    for (const record of [...bypassOwned].reverse()) {
      try {
        // Do not change shared bypass while a protocol on this service has uncertain ownership.
        if (owned.some(proxy => proxy.service === record.service)) throw new Error(`System Proxy bypass cleanup unconfirmed for ${record.service}`)
        await writeBypass(record, record.before)
        bypassOwned.splice(bypassOwned.indexOf(record), 1)
      } catch (error) { failure ??= error }
    }
    if (failure) throw failure
  }
  return {
    getSystemProxy: () => serialize(async (): Promise<SystemProxySettings | null> => {
      let first: SystemProxySettings | null = null
      // Read every protocol: a later unknown state must never be mistaken for all-off.
      for (const service of await services()) {
        for (const secure of [false, true]) {
          const proxy = await read(service, secure)
          if (proxy.enabled && !first) first = { host: proxy.host, port: proxy.port, bypass: await readBypass(service) }
        }
      }
      return first
    }),
    setSystemProxy: (settings: SystemProxySettings) => serialize(async (): Promise<void> => {
      if (!validSettings(settings)) throw new Error('Invalid System Proxy settings')
      await clearOwned()
      // Preflight all services before the first write; active authenticated proxies cannot be restored.
      const snapshots = []
      for (const service of await services()) {
        const web = await read(service, false), secure = await read(service, true)
        if ([web, secure].some(value => value.enabled && value.authenticated)) throw new Error(`Authenticated System Proxy cannot be safely replaced for ${service}`)
        snapshots.push({ service, web, secure, bypass: await readBypass(service) })
      }
      try {
        for (const snapshot of snapshots) {
          for (const secure of [false, true]) {
            const before = secure ? snapshot.secure : snapshot.web
            const record = { service: snapshot.service, secure, before, expected: [before] }
            owned.push(record)
            await writeProxy(record, { enabled: true, host: settings.host, port: settings.port, authenticated: false })
          }
          const record = { service: snapshot.service, before: snapshot.bypass, expected: [snapshot.bypass] }
          bypassOwned.push(record)
          await writeBypass(record, [...settings.bypass])
        }
      } catch (error) {
        try { await clearOwned() } catch (cleanup) { throw new AggregateError([error, cleanup], `System Proxy set failed; cleanup unconfirmed: ${String(error)}; ${String(cleanup)}`) }
        throw error
      }
    }),
    clearSystemProxy: () => serialize(clearOwned),
    cleanupStaleSystemProxy: (_port: number) => serialize(async (): Promise<void> => {
      // No durable macOS ownership receipt exists. An endpoint match is not ownership evidence.
      for (const service of await services()) {
        for (const secure of [false, true]) {
          if ((await read(service, secure)).enabled) throw new Error(`Existing System Proxy on ${service} has no ownership receipt; preserved. Review macOS Network proxy settings before continuing.`)
        }
      }
    }),
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
  // Cache the last endpoint across asynchronous operations.
  // undefined = not loaded yet (unknown); null = nothing of ours outstanding.
  let remembered: string | null | undefined
  // A clear that failed leaves the proxy state unknown even when nothing is remembered.
  let uncertain = false
  // Irreversible per instance: shutdown or uncertain mutation closes later sets.
  let closing = false
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
        if (args[0] !== 'get') { closing = true; uncertain = true }
        throw new SystemProxyUnknownStateError(`System Proxy helper timed out; the proxy may be partially changed. ${manualHint(port)}`, { cause: error })
      }
      // Exit code 2 (partial failure) still carries a JSON report on stdout.
      if (typeof details.stdout === 'string' && details.stdout.trim()) stdout = details.stdout
      else {
        if (args[0] !== 'get') { closing = true; uncertain = true }
        // Spawn refused (EACCES/EPERM, quarantined file, AppLocker) => security software or policy.
        const blocked = ['EACCES', 'EPERM', 'ENOENT', 'UNKNOWN'].includes(String(details.code))
        const message = `System Proxy helper could not run (${details.code ?? details.message}). ${manualHint(port)}`
        throw blocked ? new SystemProxyPermissionError(message, { cause: error }) : new Error(message, { cause: error })
      }
    }
    let result: HelperResult
    try { result = JSON.parse(stdout) as HelperResult } catch (error) {
      if (args[0] !== 'get') { closing = true; uncertain = true }
      throw new Error(`System Proxy helper returned invalid output: ${stdout.slice(0, 200)}`, { cause: error })
    }
    if (typeof result !== 'object' || result === null || typeof result.ok !== 'boolean') {
      if (args[0] !== 'get') { closing = true; uncertain = true }
      throw new Error('System Proxy helper returned an unexpected result')
    }
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

  async function loadRemembered(): Promise<string | null> {
    if (remembered === undefined && memory) {
      try {
        const loaded = await memory.load()
        // A set/clear that finished while loading is newer than the file.
        if (remembered === undefined) remembered = loaded
      } catch { /* stays unknown; retried next time */ }
    }
    return remembered ?? null
  }
  async function remember(server: string | null): Promise<void> {
    remembered = server
    await memory?.save(server)
  }
  // Preload the last endpoint when the adapter is initialized.
  void loadRemembered()

  function withCurrentPort(servers: Set<string>): string[] {
    const current = options.mixedPort?.()
    if (current !== undefined) servers.add(`127.0.0.1:${current}`)
    return [...servers].filter((server) => parseWindowsProxyServer(server))
  }

  async function expectedServers(extraPort?: number): Promise<string[]> {
    const servers = new Set<string>()
    const last = await loadRemembered()
    if (last) servers.add(last)
    if (extraPort !== undefined) servers.add(`127.0.0.1:${extraPort}`)
    return withCurrentPort(servers)
  }

  async function clear(servers: string[]): Promise<void> {
    if (!servers.length) return
    let result: HelperResult
    try { result = await run(['clear', ...servers.flatMap((server) => ['--expected-server', server])]) } catch (error) {
      uncertain = true
      closing = true
      throw error
    }
    if (!result.ok) {
      uncertain = true
      closing = true
      throw failure(result)
    }
    uncertain = false
    await remember(null)
  }

  return {
    beginShutdown() { closing = true },
    getSystemProxy: () => serialize(async (): Promise<SystemProxySettings | null> => {
      const result = await run(['get'])
      const lan = result.connections?.find((connection) => connection.name === null)
      if (!lan || lan.error) throw failure(result)
      if (!((lan.flags ?? 0) & PROXY_TYPE_PROXY) || !lan.proxyServer) return null
      const endpoint = parseWindowsProxyServer(lan.proxyServer)
      return endpoint && { ...endpoint, bypass: (lan.bypass ?? '').split(';').map((entry) => entry.trim()).filter(Boolean) }
    }),
    setSystemProxy: (settings: SystemProxySettings) => serialize(async (): Promise<void> => {
      if (closing) throw new Error('System Proxy writes are closed for logoff/shutdown or uncertain state')
      if (!validSettings(settings) || settings.bypass.some((entry) => entry.includes(';'))) throw new Error('Invalid System Proxy settings')
      const server = `${settings.host}:${settings.port}`
      // WinINet rejects the whole bypass list (error 87) on a bare IPv6 literal such as ::1; it needs [::1].
      const bypass = settings.bypass.map((entry) => isIPv6(entry) ? `[${entry}]` : entry)
      // Remember before writing, so a crash mid-write is still cleaned up on next start.
      await remember(server)
      // Shutdown may have closed writes while the memory file was being written.
      if (closing) throw new Error('System Proxy writes are closed for logoff/shutdown or uncertain state')
      const log = options.logPath ? ['--log', options.logPath] : []
      const result = await run(['set', '--host', settings.host, '--port', String(settings.port), '--bypass', bypass.join(';'), ...log], settings.port)
      if (result.ok) {
        // The proxy works without the fallback; only logoff/shutdown cleanup loses its safety net.
        return
      }
      // Partial write: undo connections that did take our endpoint rather than leave a mix.
      await clear([server]).catch(() => {})
      throw failure(result, settings.port)
    }),
    clearSystemProxy: () => serialize(async () => {
      // Once writes close, skip redundant clears only when no endpoint or failed cleanup remains.
      if (closing && remembered === null && !uncertain) return
      await clear(await expectedServers())
    }),
    cleanupStaleSystemProxy: (port: number) => serialize(async () => clear(await expectedServers(port))),
  }
}
