import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { chmod, lstat, mkdir, readFile, readlink, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { isAbsolute, join, resolve, win32 } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import type { ControlChannel, Platform, ValidationResult } from '@kuro/core'
import { fetchProfileText } from './fetch'
import { createSystemProxy, execCommand, type Exec } from './system-proxy'
import { createSocketTransport } from './transport'

export { createSocketTransport } from './transport'
export { createSystemProxy, SystemProxyPermissionError } from './system-proxy'
export type { Exec } from './system-proxy'
export { createResumeHandler } from './resume'

export interface DesktopPlatformOptions {
  dataDir: string
  corePath: string
  mixedPort: number | (() => number)
  appProcessName?: string
  userAgent?: string
  os?: NodeJS.Platform
  startTimeoutMs?: number
  stopTimeoutMs?: number
  exec?: Exec
  spawn?: (file: string, args: string[], options: SpawnOptions) => ChildProcess
  powerMonitor?: { on(event: 'resume', listener: () => void): unknown; removeListener(event: 'resume', listener: () => void): unknown }
  fetchText?: Platform['fetchText']
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
  await new Promise<void>((resolve, reject) => {
    const server = createServer()
    server.once('error', (error: NodeJS.ErrnoException) => reject(new Error(
      error.code === 'EADDRINUSE' ? `mixed-port 127.0.0.1:${port} is already in use; close the other application or change mixed-port`
        : `Cannot bind mixed-port 127.0.0.1:${port}: ${error.message}`, { cause: error },
    )))
    server.listen(port, '127.0.0.1', () => server.close((error) => error ? reject(error) : resolve()))
  })
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
  const systemProxy = createSystemProxy({ os, exec })
  const port = () => typeof options.mixedPort === 'function' ? options.mixedPort() : options.mixedPort
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
  let queue: Promise<unknown> = Promise.resolve()
  let shuttingDown = false
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
    if (child?.pid && child.exitCode === null && child.signalCode === null) {
      await terminate(child.pid)
    }
    child = undefined
    await rm(await filePath('core.pid'), { force: true })
    if (channel.kind === 'unix') await rm(channel.path, { force: true })
  }

  const platform: DesktopPlatform = {
    readFile: read,
    writeFileAtomic: atomic,
    async removeFile(name) { await rm(await filePath(name), { force: true }) },
    applyRuntimeConfig: (yaml) => serialize(() => apply(yaml)),
    startCore: () => serialize(async () => {
      if (shuttingDown) throw new Error('Platform is shutting down')
      if (child?.pid && child.exitCode === null && child.signalCode === null && alive(child.pid)) return
      await cleanupOrphan()
      if (shuttingDown) throw new Error('Platform is shutting down')
      await assertMixedPortAvailable(port())
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
      const started = spawnCore(corePath, ['-d', dataDir, '-f', join(dataDir, 'runtime.yaml')], {
        cwd: dataDir, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      })
      child = started
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
        let readinessError = ''
        while (Date.now() < deadline && !shuttingDown) {
          if (processError) throw processError
          if (started.exitCode !== null || started.signalCode !== null) throw new Error(`Core exited before ready: ${output}`)
          try {
            if (channel.kind === 'unix') await chmod(channel.path, 0o600)
            const res = await createSocketTransport(channel, { timeoutMs: Math.min(250, Math.max(1, deadline - Date.now())) })
              .request({ method: 'GET', path: '/version' })
            if (res.status >= 200 && res.status < 300) return
          } catch (error) { readinessError = errorText(error) }
          await delay(25)
        }
        throw new Error(shuttingDown ? 'Platform is shutting down' : `Core Control Channel readiness timed out: ${readinessError}\n${output}`)
      } catch (error) {
        await stop()
        throw error
      }
    }),
    stopCore: () => serialize(stop),
    async isCoreRunning() {
      return !!child?.pid && child.exitCode === null && child.signalCode === null && alive(child.pid)
    },
    controlChannel: () => ({ ...channel }),
    ...systemProxy,
    fetchText: options.fetchText ?? ((url, input) => fetchProfileText(url, {
      ...input, userAgent: input.userAgent || options.userAgent || options.appProcessName || 'Clash Kuro', mixedPort: port(),
    })),
    onResume(listener) {
      options.powerMonitor?.on('resume', listener)
      return () => { options.powerMonitor?.removeListener('resume', listener) }
    },
    async shutdown({ timeoutMs }) {
      shuttingDown = true
      let timer: ReturnType<typeof setTimeout> | undefined
      const cleanup = async () => {
        let proxyTimer: ReturnType<typeof setTimeout> | undefined
        try {
          await Promise.race([
            platform.clearSystemProxy(),
            new Promise<void>((resolve) => { proxyTimer = setTimeout(resolve, Math.max(0, timeoutMs / 2)) }),
          ])
        } catch { /* A permissions failure must not prevent Core cleanup. */ }
        finally { clearTimeout(proxyTimer) }
        await platform.stopCore()
      }
      try {
        await Promise.race([
          cleanup().catch(() => {}),
          new Promise<void>((resolve) => { timer = setTimeout(resolve, Math.max(0, timeoutMs)) }),
        ])
      } finally { clearTimeout(timer) }
    },
  }
  return platform
}
