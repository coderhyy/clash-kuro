import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { createSocket } from 'node:dgram'
import { once } from 'node:events'
import { chmod, lstat, mkdir, readFile, readlink, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { createConnection, createServer } from 'node:net'
import { isAbsolute, join, resolve, win32 } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import type { ControlChannel, Platform, TunPlatform, TunStatus, ValidationResult } from '@kuro/core'
import { fetchProfileText } from './fetch'
import { createLaunchAtLogin, type LoginItemApp } from './login-item'
import { createSystemProxy, execCommand, parseWindowsProxyServer, type Exec } from './system-proxy'
import { createSocketTransport } from './transport'
import type { startResidentSession } from './resident-session'

export { createSocketTransport } from './transport'
export { createSystemProxy, SystemProxyPermissionError, SystemProxyUnknownStateError } from './system-proxy'
export type { Exec } from './system-proxy'
export { createResumeHandler } from './resume'

export interface DesktopPlatformOptions {
  tun?: TunPlatform
  dataDir: string
  corePath: string
  /** Windows: absolute path to kuro-sysproxy.exe (issue 08). */
  sysproxyHelperPath?: string
  /** Windows: bounded native owner diagnostics (default <dataDir>\sysproxy-owner.log). */
  sysproxyLogPath?: string
  mixedPort: number | (() => number)
  appProcessName?: string
  userAgent?: string
  os?: NodeJS.Platform
  startTimeoutMs?: number
  stopTimeoutMs?: number
  exec?: Exec
  spawn?: (file: string, args: string[], options: SpawnOptions) => ChildProcess
  /** Windows native owner; production startup supplies the current-version session. */
  startResident?: typeof startResidentSession
  onResidentStopped?: (reason: string) => void
  powerMonitor?: { on(event: 'resume', listener: () => void): unknown; removeListener(event: 'resume', listener: () => void): unknown }
  fetchText?: Platform['fetchText']
  /** Electron `app`; omitted (tests) means Launch at Login is unsupported. */
  loginItemApp?: LoginItemApp
}

export interface DesktopPlatform extends Platform {
  cleanupStaleSystemProxy(port: number): Promise<void>
  shutdown(options: { timeoutMs: number }): Promise<void>
}

function validatePort(port: number): void {
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid mixed-port: expected 1-65535')
}

export async function assertMixedPortAvailable(port: number): Promise<void> {
  validatePort(port)
  const bindError = (protocol: string, error: NodeJS.ErrnoException) => new Error(
    error.code === 'EADDRINUSE' ? `mixed-port 127.0.0.1:${port} is already in use (${protocol}); close the other application or change mixed-port`
      : `Cannot bind mixed-port 127.0.0.1:${port} (${protocol}): ${error.message}`, { cause: error },
  )
  await new Promise<void>((resolve, reject) => {
    const server = createServer()
    server.once('error', (error: NodeJS.ErrnoException) => reject(bindError('TCP', error)))
    server.listen(port, '127.0.0.1', () => server.close((error) => error ? reject(error) : resolve()))
  })
  await new Promise<void>((resolve, reject) => {
    const socket = createSocket('udp4')
    socket.once('error', (error: NodeJS.ErrnoException) => socket.close(() => reject(bindError('UDP', error))))
    socket.bind(port, '127.0.0.1', () => socket.close(resolve))
  })
}

async function assertCoreReady(channel: ControlChannel, port: number, deadline: number): Promise<void> {
  const remaining = () => Math.min(250, Math.max(1, deadline - Date.now()))
  const res = await createSocketTransport(channel, { timeoutMs: remaining() }).request({ method: 'GET', path: '/version' })
  if (res.status < 200 || res.status >= 300) throw new Error(`Core API readiness returned HTTP ${res.status}`)
  if (Date.now() >= deadline) throw new Error('Core mixed-port readiness deadline exceeded')
  // The API can be ready even when Core failed to bind its mixed listener.
  await new Promise<void>((resolve, reject) => {
    const socket = createConnection({ host: '127.0.0.1', port })
    const timer = setTimeout(() => socket.destroy(new Error('Mixed listener SOCKS5 greeting or close timed out')), remaining())
    let reply = Buffer.alloc(0)
    let negotiated = false
    let failure: Error | undefined
    // Both no-auth and password negotiation prove readiness without credentials or an upstream request.
    socket.once('connect', () => socket.write(Buffer.from([5, 2, 0, 2])))
    socket.on('data', chunk => {
      if (negotiated) return
      reply = Buffer.concat([reply, chunk]).subarray(0, 2)
      if (reply.length < 2) return
      if (reply[0] !== 5 || (reply[1] !== 0 && reply[1] !== 2)) {
        socket.destroy(new Error('Invalid mixed listener SOCKS5 greeting'))
        return
      }
      negotiated = true
      // Local destroy does not establish peer closure before an immediate Core stop/rebind.
      socket.end()
    })
    socket.once('end', () => { if (reply.length < 2) socket.destroy(new Error('Mixed listener closed before SOCKS5 greeting')) })
    socket.once('error', error => {
      failure = new Error(`mixed-port 127.0.0.1:${port} is not ready: ${error.message}`, { cause: error })
    })
    socket.once('close', () => {
      clearTimeout(timer)
      if (failure) reject(failure)
      else if (!negotiated || !socket.readableEnded) reject(new Error('Mixed listener closed without completing probe teardown'))
      else resolve()
    })
  })
  if (Date.now() >= deadline) throw new Error('Core mixed-port readiness deadline exceeded')
}

function errorText(error: unknown): string {
  const details = error as { message?: string; stdout?: string; stderr?: string }
  return [details?.message, details?.stdout, details?.stderr].filter(Boolean).join('\n') || String(error)
}

export function createDesktopPlatform(options: DesktopPlatformOptions): DesktopPlatform {
  const dataDir = resolve(options.dataDir)
  const corePath = resolve(options.corePath)
  const os = options.os ?? process.platform
  const exec = options.exec ?? execCommand
  const spawnCore = options.spawn ?? spawn
  const stopTimeoutMs = options.stopTimeoutMs ?? 2_000
  const port = () => typeof options.mixedPort === 'function' ? options.mixedPort() : options.mixedPort
  if (options.startResident && (os !== 'win32' || !options.sysproxyHelperPath)) throw new Error('Resident requires Windows and a helper')
  type Resident = Awaited<ReturnType<typeof startResidentSession>>
  let resident: Resident | undefined
  let residentStarting: Promise<Resident> | undefined
  let residentStopping: Promise<void> | undefined
  let residentAbort: AbortController | undefined
  let residentFailed = false
  let residentGeneration = 0
  function makeSystemProxy() {
    const generation = residentGeneration
    const proxyExec: Exec = async (file, args) => {
      if (!options.startResident) return exec(file, args)
      if (!resident || residentFailed || generation !== residentGeneration) throw new Error('Resident proxy owner unavailable; no one-shot write fallback')
      return resident.request(args)
    }
    return createSystemProxy({
      os, exec: proxyExec, helperPath: options.sysproxyHelperPath, mixedPort: port,
      logPath: os === 'win32' && !options.startResident ? options.sysproxyLogPath ?? win32.join(dataDir, 'sysproxy.log') : undefined,
      memory: {
        async load() {
          const text = await read('system-proxy.json')
          const server = text ? (JSON.parse(text) as { server?: unknown }).server : null
          return typeof server === 'string' && parseWindowsProxyServer(server) ? server : null
        },
        async save(server) {
          if (server) await atomic('system-proxy.json', JSON.stringify({ server }))
          else await rm(await filePath('system-proxy.json'), { force: true })
        },
      },
    })
  }
  let systemProxy = makeSystemProxy()
  let channel: ControlChannel
  let usedPipe = false
  if (os === 'win32') channel = { kind: 'pipe', name: `\\\\.\\pipe\\kuro-${randomUUID()}` }
  else {
    let path = join(dataDir, 'mihomo.sock')
    if (Buffer.byteLength(path) > 103) path = join(dataDir, 'c')
    // Never fall back to /tmp: the private userData directory is part of the channel's security boundary.
    if (Buffer.byteLength(path) > 103) throw new Error('Control Channel path exceeds 103 bytes; configure a shorter userData directory')
    channel = { kind: 'unix', path }
  }
  let child: ChildProcess | undefined
  let childClosed: Promise<void> | undefined
  let queue: Promise<unknown> = Promise.resolve()
  let shuttingDown = false
  let shutdown: Promise<void> | undefined
  let tunStart: Promise<TunStatus> | undefined
  const tun: TunPlatform | undefined = options.tun && {
    inspect: () => options.tun!.inspect(),
    recover: () => options.tun!.recover(),
    stop: () => options.tun!.stop(),
    start(config) {
      if (shuttingDown) return Promise.reject(new Error('Platform is shutting down; TUN start is closed'))
      if (tunStart) return tunStart
      const pending = Promise.resolve().then(() => {
        if (shuttingDown) throw new Error('Platform is shutting down; TUN start is closed')
        return options.tun!.start(config)
      })
      tunStart = pending
      const clear = () => { if (tunStart === pending) tunStart = undefined }
      void pending.then(clear, clear)
      return pending
    },
  }
  async function requireTunOff(): Promise<void> {
    if (!options.tun) return
    if (tunStart) throw new Error('TUN startup must settle before ordinary Core or System Proxy writes')
    const status = await options.tun.inspect()
    if (status.state !== 'off') throw new Error(status.error || 'TUN must be confirmed off before ordinary Core or System Proxy writes')
  }
  async function stopTun(): Promise<void> {
    if (!options.tun) return
    // A start already sent to the helper must settle before stop/readback can prove off.
    // shortcut: native session lease/owner-death cleanup is required before enabling real TUN start.
    await tunStart?.catch(() => {})
    if ((await options.tun.inspect()).state === 'off') return
    await options.tun.stop()
    await requireTunOff()
  }
  const serialize = <T>(operation: () => Promise<T>): Promise<T> => {
    const result = queue.then(operation)
    queue = result.catch(() => {})
    return result
  }

  async function filePath(name: string, createParents = false): Promise<string> {
    if (!name || name.includes('\0') || isAbsolute(name) || win32.isAbsolute(name)
      || name.split(/[\\/]/).some((part) => !part || part === '..' || part === '.' || part.includes(':'))) {
      throw new Error('File name must be a relative path without traversal')
    }
    await mkdir(dataDir, { recursive: true, mode: 0o700 })
    let path = dataDir
    const parts = name.split(/[\\/]/)
    for (const [index, part] of parts.entries()) {
      path = join(path, part)
      try {
        const stat = await lstat(path)
        if (stat.isSymbolicLink()) throw new Error('Symlinks are not allowed in app data file names')
        if (index < parts.length - 1 && !stat.isDirectory()) throw new Error('File parent is not a directory')
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
        if (createParents && index < parts.length - 1) {
          await mkdir(path, { recursive: true, mode: 0o700 })
          const stat = await lstat(path)
          if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error('File parent must be a directory, not a symlink')
        }
      }
    }
    return path
  }

  async function read(name: string): Promise<string | null> {
    const path = await filePath(name)
    try { return await readFile(path, 'utf8') } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
      throw error
    }
  }

  async function atomic(name: string, data: string): Promise<void> {
    const path = await filePath(name, true)
    const tmp = `${path}.${randomUUID()}.tmp`
    try {
      await writeFile(tmp, data, { flag: 'wx', mode: 0o600 })
      await rename(tmp, path)
    } finally { await rm(tmp, { force: true }) }
  }

  async function apply(yaml: string): Promise<ValidationResult> {
    const path = await filePath('runtime.yaml')
    const tmp = `${path}.${randomUUID()}.tmp`
    try {
      await writeFile(tmp, yaml, { flag: 'wx', mode: 0o600 })
      await exec(corePath, ['-t', '-d', dataDir, '-f', tmp])
      await rename(tmp, path)
      return { ok: true }
    } catch (error) { return { ok: false, error: errorText(error) } }
    finally { await rm(tmp, { force: true }) }
  }

  async function matchesCore(pid: number): Promise<boolean> {
    try {
      const actual = os === 'win32'
        ? (await exec('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `(Get-Process -Id ${pid} -ErrorAction Stop).Path`])).stdout.trim()
        : os === 'darwin'
          ? (await exec('/bin/ps', ['-ww', '-p', String(pid), '-o', 'comm='])).stdout.trim()
          : await readlink(`/proc/${pid}/exe`)
      const [actualPath, expectedPath] = await Promise.all([realpath(actual), realpath(corePath)])
      return os === 'win32' ? actualPath.toLowerCase() === expectedPath.toLowerCase() : actualPath === expectedPath
    } catch { return false }
  }

  function alive(pid: number): boolean {
    try { process.kill(pid, 0); return true } catch (error) {
      return (error as NodeJS.ErrnoException).code === 'EPERM'
    }
  }

  async function waitForExit(pid: number, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs
    while (alive(pid)) {
      if (Date.now() >= deadline) return false
      await delay(Math.min(25, Math.max(1, deadline - Date.now())))
    }
    return true
  }

  async function terminate(pid: number, orphan = false): Promise<void> {
    try {
      process.kill(pid, 'SIGTERM')
      if (!await waitForExit(pid, stopTimeoutMs)) {
        if (orphan && !await matchesCore(pid)) return
        process.kill(pid, 'SIGKILL')
        if (!await waitForExit(pid, stopTimeoutMs)) throw new Error(`Core pid ${pid} did not exit after SIGKILL`)
      }
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error }
  }

  async function cleanupOrphan(): Promise<void> {
    const text = await read('core.pid')
    const pid = text !== null && /^[1-9]\d*\s*$/.test(text) ? Number(text.trim()) : 0
    if (Number.isSafeInteger(pid) && pid > 1 && pid !== process.pid && await matchesCore(pid)) await terminate(pid, true)
    await rm(await filePath('core.pid'), { force: true })
  }

  async function stop(): Promise<void> {
    if (options.startResident) {
      if (residentStopping) return residentStopping
      residentGeneration++
      if ('beginShutdown' in systemProxy) systemProxy.beginShutdown()
      residentAbort?.abort()
      residentStopping = (async () => {
        const owner = resident ?? await residentStarting?.catch(() => undefined)
        if (!owner && residentFailed) throw new Error('Resident exited unexpectedly; cleanup unverified')
        if (owner) {
          if (resident === owner) resident = undefined
            try {
              const result = await owner.close()
              if (result?.restartRequired) {
                residentFailed = true
                options.onResidentStopped?.('Native session ended during stop; application restart required')
              }
            }
            catch (error) {
              residentFailed = true
              options.onResidentStopped?.(`System Proxy cleanup unverified; restart required: ${errorText(error)}`)
              throw error
            }
        }
      })()
      return residentStopping
    }
    if (child && childClosed) {
      const owned = child, closed = childClosed
      const waitClosed = () => new Promise<boolean>(resolve => {
        const timer = setTimeout(() => resolve(false), stopTimeoutMs)
        void closed.then(() => { clearTimeout(timer); resolve(true) })
      })
      try {
        // The owned handle/close event, not PID polling, establishes completed process teardown.
        if (owned.exitCode === null && owned.signalCode === null) owned.kill('SIGTERM')
        if (!await waitClosed()) {
          if (owned.exitCode === null && owned.signalCode === null) owned.kill('SIGKILL')
          if (!await waitClosed()) throw new Error('Owned Core teardown did not complete after SIGKILL')
        }
      } catch (error) {
        shuttingDown = true
        throw error
      }
    }
    child = undefined
    childClosed = undefined
    await rm(await filePath('core.pid'), { force: true })
    if (channel.kind === 'unix') await rm(channel.path, { force: true })
  }

  const platform: DesktopPlatform = {
    tun,
    readFile: read,
    writeFileAtomic: atomic,
    async removeFile(name) { await rm(await filePath(name), { force: true }) },
    applyRuntimeConfig: (yaml) => serialize(() => apply(yaml)),
    startCore: () => serialize(async () => {
      if (shuttingDown) throw new Error('Platform is shutting down')
      await requireTunOff()
      if (residentFailed) throw new Error('Resident state uncertain; application restart required')
      if (resident) return
      if (child?.pid && child.exitCode === null && child.signalCode === null && alive(child.pid)) return
      if (!options.startResident) await cleanupOrphan()
      if (shuttingDown) throw new Error('Platform is shutting down')
      const mixedPort = port()
      await assertMixedPortAvailable(mixedPort)
      if (await read('runtime.yaml') === null) throw new Error('No Runtime Config has been applied')
      if (channel.kind === 'pipe' && usedPipe) {
        const yaml = (await read('runtime.yaml'))!
        const next: ControlChannel = { kind: 'pipe', name: `\\\\.\\pipe\\kuro-${randomUUID()}` }
        // shortcut: pipe rotation expects a top-level block scalar; widen if the generator adopts flow YAML.
        const directive = /^(?:external-controller-pipe|'external-controller-pipe'|"external-controller-pipe")\s*:.*$/m
        if (!directive.test(yaml)) throw new Error('Runtime Config is missing external-controller-pipe')
        const result = await apply(yaml.replace(directive, `external-controller-pipe: ${JSON.stringify(next.name)}`))
        if (!result.ok) throw new Error(result.error)
        channel = next
      }
      if (channel.kind === 'unix') {
        await chmod(dataDir, 0o700)
        await rm(channel.path, { force: true })
      }
      let output = ''
      let readinessError = ''
      if (shuttingDown || residentFailed) throw new Error('Platform is shutting down or requires restart')
      if (options.startResident) {
        residentStopping = undefined
        residentAbort = new AbortController()
        residentStarting = options.startResident({ helper: options.sysproxyHelperPath!,
          recoveryDirectory: join(dataDir, 'proxy-recovery'), dataDir, core: corePath,
          server: `127.0.0.1:${mixedPort}`, log: options.sysproxyLogPath ?? join(dataDir, 'sysproxy-owner.log'), signal: residentAbort.signal })
        try {
          const owner = resident = await residentStarting
          usedPipe = true
          void owner.exited.then(() => {
            if (resident === owner) {
              residentFailed = true
              if ('beginShutdown' in systemProxy) systemProxy.beginShutdown()
              options.onResidentStopped?.('System Proxy owner stopped; restart the application before starting Core or changing proxy settings')
              // Keep the exact owner's final report for shutdown verification, even after native session cleanup.
            }
          })
          const deadline = Date.now() + (options.startTimeoutMs ?? 10_000)
          while (Date.now() < deadline && !shuttingDown && !residentFailed && resident === owner) {
            try {
              await assertCoreReady(channel, mixedPort, deadline)
              if (!shuttingDown && !residentFailed && resident === owner) {
                systemProxy = makeSystemProxy()
                return
              }
            } catch (error) { readinessError = errorText(error) }
            await delay(Math.min(25, Math.max(0, deadline - Date.now())))
          }
          throw new Error(`Resident Core readiness failed: ${readinessError}\n${owner.diagnostics()}`)
        } catch (error) {
          residentFailed = true
          options.onResidentStopped?.(`System Proxy owner startup failed; restart required: ${errorText(error)}`)
          await stop().catch(() => {})
          throw error
        } finally { residentStarting = undefined }
      }
      const started = spawnCore(corePath, ['-d', dataDir, '-f', join(dataDir, 'runtime.yaml')], {
        cwd: dataDir, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      })
      child = started
      childClosed = new Promise(resolve => { started.once('close', () => resolve()) })
      let processError: Error | undefined
      started.on('error', (error) => { processError = error })
      started.stdout?.on('data', (chunk: Buffer) => { output = (output + chunk.toString()).slice(-8192) })
      started.stderr?.on('data', (chunk: Buffer) => { output = (output + chunk.toString()).slice(-8192) })
      try {
        await once(started, 'spawn')
        if (!started.pid) throw new Error('Core did not provide a pid')
        usedPipe = true
        await atomic('core.pid', String(started.pid))
        const deadline = Date.now() + (options.startTimeoutMs ?? 10_000)
        while (Date.now() < deadline && !shuttingDown) {
          if (processError) throw processError
          if (started.exitCode !== null || started.signalCode !== null) throw new Error(`Core exited before ready: ${output}`)
          try {
            if (channel.kind === 'unix') await chmod(channel.path, 0o600)
            await assertCoreReady(channel, mixedPort, deadline)
            if (!shuttingDown && started.exitCode === null && started.signalCode === null) return
          } catch (error) { readinessError = errorText(error) }
          await delay(Math.min(25, Math.max(0, deadline - Date.now())))
        }
        throw new Error(shuttingDown ? 'Platform is shutting down' : `Core readiness timed out: ${readinessError}\n${output}`)
      } catch (error) {
        await stop()
        throw error
      }
    }),
    stopCore: () => serialize(async () => {
      await stopTun()
      // The native owner starts its shared cleanup budget itself; never pre-clear over IPC.
      if (!options.startResident && !shuttingDown) await systemProxy.clearSystemProxy()
      await stop()
    }),
    async isCoreRunning() {
      if (options.startResident) return !!resident && !residentFailed
      return !!child?.pid && child.exitCode === null && child.signalCode === null && alive(child.pid)
    },
    controlChannel: () => ({ ...channel }),
    ...createLaunchAtLogin({ os, app: options.loginItemApp }),
    getSystemProxy: () => systemProxy.getSystemProxy(),
    async clearSystemProxy() { await requireTunOff(); await systemProxy.clearSystemProxy() },
    async cleanupStaleSystemProxy(port) { await requireTunOff(); await systemProxy.cleanupStaleSystemProxy(port) },
    async setSystemProxy(settings) {
      if (shuttingDown) throw new Error('Platform is shutting down; System Proxy writes are closed')
      if (residentFailed) throw new Error('Resident has exited; System Proxy writes are closed')
      await requireTunOff()
      if (shuttingDown) throw new Error('Platform is shutting down; System Proxy writes are closed')
      await systemProxy.setSystemProxy(settings)
    },
    fetchText: options.fetchText ?? ((url, input) => fetchProfileText(url, {
      ...input, userAgent: input.userAgent || options.userAgent || options.appProcessName || 'Clash Kuro', mixedPort: port(),
    })),
    onResume(listener) {
      options.powerMonitor?.on('resume', listener)
      return () => { options.powerMonitor?.removeListener('resume', listener) }
    },
    shutdown({ timeoutMs }) {
      if (shutdown) return shutdown
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return Promise.reject(new Error('Invalid shutdown budget'))
      shuttingDown = true
      if ('beginShutdown' in systemProxy) systemProxy.beginShutdown()
      const started = performance.now()
      const within = async (operation: () => Promise<void>, deadline: number, name: string) => {
        let timer: ReturnType<typeof setTimeout> | undefined
        try { await Promise.race([
          Promise.resolve().then(operation),
          new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(new Error(`${name} deadline exceeded; state unknown`)), Math.max(0, deadline - performance.now()))
          }),
        ]) } finally { clearTimeout(timer) }
      }
      shutdown = (async () => {
        if (options.startResident) {
            await within(async () => { await stop(); await queue }, started + timeoutMs, 'Resident cleanup and startup quiescence')
          return
        }
        const errors: unknown[] = []
        if (options.tun) {
          try { await within(stopTun, started + timeoutMs / 2, 'TUN cleanup') }
          catch (error) {
            // Do not write ordinary proxy settings while TUN ownership/cleanup is uncertain.
            errors.push(error)
            try { await within(stop, started + timeoutMs, 'Ordinary Core stop') }
            catch (stopError) { errors.push(stopError) }
            throw new AggregateError(errors, `Shutdown incomplete: ${errors.map(errorText).join('; ')}`)
          }
        }
        // Waiting is bounded, not cancellation: the resident owner must settle/terminate native writers.
        try { await within(() => platform.clearSystemProxy(), started + timeoutMs * (options.tun ? 0.75 : 0.5), 'Proxy cleanup') }
        catch (error) { errors.push(error) }
        try { await within(() => platform.stopCore(), started + timeoutMs, 'Core stop') }
        catch (error) { errors.push(error) }
        if (errors.length) throw new AggregateError(errors, `Shutdown incomplete: ${errors.map(errorText).join('; ')}`)
      })()
      return shutdown
    },
  }
  return platform
}
