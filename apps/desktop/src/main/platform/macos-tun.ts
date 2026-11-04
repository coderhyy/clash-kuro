import { lstat } from 'node:fs/promises'
import { createConnection } from 'node:net'
import type { TunPlatform, TunStatus } from '@kuro/core'

const socketPath = '/var/run/dev.kuro.tun/control.sock'
const installationPaths = [
  '/Library/PrivilegedHelperTools/dev.kuro.tun',
  '/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall',
  '/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall.json',
  '/Library/LaunchDaemons/dev.kuro.tun.plist',
  '/Library/Application Support/Clash Kuro/Privileged',
  '/var/run/dev.kuro.tun',
]
const maxBytes = 64 * 1024
type Operation = 'status' | 'recover' | 'start' | 'stop'

function keys(value: unknown, allowed: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every(key => allowed.includes(key))
}

export function parseTunResponse(text: string): TunStatus {
  const value: unknown = JSON.parse(text)
  if (!keys(value, ['version', 'ok', 'status', 'error']) || value.version !== 1 || typeof value.ok !== 'boolean') {
    throw new Error('Invalid TUN helper response')
  }
  if (!value.ok) {
    if (typeof value.error !== 'string' || !value.error || value.error.length > 4096 || value.status !== undefined) {
      throw new Error('Invalid TUN helper error')
    }
    throw new Error(value.error)
  }
  const status = value.status
  if (value.error !== undefined || !keys(status, ['availability', 'state', 'error'])
    || typeof status.availability !== 'string' || !['ready', 'blocked'].includes(status.availability)
    || typeof status.state !== 'string' || !['off', 'on', 'unknown'].includes(status.state)
    || (status.error !== undefined && (typeof status.error !== 'string' || status.error.length > 4096))
    || (status.state === 'unknown' && (typeof status.error !== 'string' || !status.error))) {
    throw new Error('Invalid TUN helper status')
  }
  return status as unknown as TunStatus
}

/** A missing endpoint is only safe when no installation or retained-state footprint exists. */
async function endpointPresent(): Promise<boolean> {
  let present = false
  for (const path of installationPaths) {
    try {
      const info = await lstat(path)
      if (info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o022)) throw new Error('Untrusted TUN helper installation')
      present = true
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  if (!present) return false
  const endpoint = await lstat(socketPath)
  // Ordinary users may connect; the root-owned directory protects the endpoint, native audit-token checks authorize writes.
  if (!endpoint.isSocket() || endpoint.uid !== 0) throw new Error('Untrusted TUN helper socket')
  return true
}

/** Transport only: native helper must still authorize every state-changing request. */
export function requestTunHelper(operation: Operation, path = socketPath, timeoutMs = 2000): Promise<TunStatus> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(path)
    let bytes = Buffer.alloc(0)
    let settled = false
    const finish = (error?: Error, result?: TunStatus) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      socket.destroy()
      if (error) reject(error)
      else resolve(result!)
    }
    const timer = setTimeout(() => finish(new Error('TUN helper response timed out; network state unknown')), timeoutMs)
    socket.once('connect', () => socket.end(`${JSON.stringify({ version: 1, operation })}\n`))
    socket.on('data', chunk => {
      if (bytes.length + chunk.length > maxBytes) { finish(new Error('TUN helper response exceeds limit')); return }
      bytes = Buffer.concat([bytes, chunk])
    })
    socket.once('end', () => {
      try {
        const text = bytes.toString('utf8')
        if (!text.endsWith('\n') || text.trim().includes('\n')) throw new Error('Invalid TUN helper response framing')
        finish(undefined, parseTunResponse(text.trim()))
      } catch (error) { finish(error as Error) }
    })
    socket.once('error', error => finish(error))
    socket.once('close', () => { if (!settled) finish(new Error('TUN helper disconnected without a complete response')) })
  })
}

export function createMacosTun(options: {
  endpointPresent?: () => Promise<boolean>
  request?: (operation: Operation) => Promise<TunStatus>
} = {}): TunPlatform {
  const present = options.endpointPresent ?? endpointPresent
  const request = options.request ?? requestTunHelper
  const missing: TunStatus = { availability: 'not-installed', state: 'off' }
  const inspect = async (): Promise<TunStatus> => {
    try { return await present() ? await request('status') : { ...missing } }
    catch (error) {
      return { availability: 'blocked', state: 'unknown', error: error instanceof Error ? error.message : String(error) }
    }
  }
  const change = async (operation: Exclude<Operation, 'status'>): Promise<TunStatus> => {
    if (!await present()) {
      if (operation === 'start') throw new Error('TUN helper is not installed')
      return { ...missing }
    }
    const before = await request('status')
    if (operation === 'start' && (before.availability !== 'ready' || before.state !== 'off')) {
      throw new Error(before.error || 'TUN helper is not ready for a new session')
    }
    if (operation !== 'start' && before.state === 'off') return before
    const result = await request(operation)
    if (result.state !== (operation === 'start' ? 'on' : 'off')) throw new Error(result.error || 'TUN helper could not confirm the requested network state')
    const observed = await request('status')
    if (observed.state !== result.state) throw new Error(observed.error || 'TUN helper state confirmation failed')
    return observed
  }
  return { inspect, recover: () => change('recover'), start: () => change('start'), stop: () => change('stop') }
}

