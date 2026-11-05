import { lstat } from 'node:fs/promises'
import { createConnection } from 'node:net'
import { performance } from 'node:perf_hooks'
import { validateTunSessionConfig, type TunPlatform, type TunSessionConfig, type TunStatus } from '@kuro/core'

import { TUN_RUN_DIRECTORY, TUN_CONTROL_SOCKET, assertTrustedTunEndpoint } from '../tun-endpoints'

const socketPath = TUN_CONTROL_SOCKET
const installationPaths = [
  '/Library/PrivilegedHelperTools/dev.kuro.tun',
  '/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall',
  '/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall.json',
  '/Library/LaunchDaemons/dev.kuro.tun.plist',
  '/Library/Application Support/Clash Kuro/Privileged',
  TUN_RUN_DIRECTORY,
  // A legacy footprint still means unknown; clients never connect to its old endpoint.
  '/var/run/dev.kuro.tun',
]
const maxBytes = 64 * 1024
type Operation = 'status' | 'recover' | 'stop'

function keys(value: unknown, allowed: string[]): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every(key => allowed.includes(key))
}

/** JSON.parse alone silently accepts duplicate keys, including escaped spellings. */
function parseResponse(text: string): unknown {
  const value: unknown = JSON.parse(text)
  const objects: Set<string>[] = []
  for (let index = 0; index < text.length; index++) {
    if (text[index] === '{') objects.push(new Set())
    else if (text[index] === '}') objects.pop()
    else if (text[index] === '"') {
      const start = index++
      while (index < text.length && text[index] !== '"') {
        if (text[index] === '\\') index++
        index++
      }
      let next = index + 1
      while (/\s/.test(text[next] ?? '') && next < text.length) next++
      if (text[next] === ':') {
        const key: string = JSON.parse(text.slice(start, index + 1))
        const object = objects.at(-1)
        if (!object || object.has(key)) throw new Error('Duplicate TUN helper response key')
        object.add(key)
      }
    }
  }
  return value
}

export function parseTunResponse(text: string): TunStatus {
  const value = parseResponse(text)
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
      if (info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o6022)) throw new Error('Untrusted TUN helper installation')
      present = true
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  if (!present) return false
  await assertTrustedTunEndpoint(socketPath)
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
        const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
        if (!text.endsWith('\n') || text.trim().includes('\n')) throw new Error('Invalid TUN helper response framing')
        finish(undefined, parseTunResponse(text.trim()))
      } catch (error) { finish(error as Error) }
    })
    socket.once('error', error => finish(error))
    socket.once('close', () => { if (!settled) finish(new Error('TUN helper disconnected without a complete response')) })
  })
}

export interface TunHelperSession {
  subscribe?(listener: () => void): () => void
  stop(): Promise<TunStatus>
  error(): Error | undefined
  disconnect(): void
}

/** V2 exclusively carries admitted config; V1 must never be used to start a session. */
export async function openTunHelperSession(config: TunSessionConfig, path = socketPath, options: {
  timeoutMs?: number
  heartbeatMs?: number
} = {}): Promise<TunHelperSession> {
  const admitted = validateTunSessionConfig(config)
  const frame = `${JSON.stringify({ version: 2, operation: 'open', config: admitted })}\n`
  if (Buffer.byteLength(frame) > 66000) throw new Error('TUN open frame exceeds limit')
  const timeoutMs = options.timeoutMs ?? 2000
  const heartbeatMs = options.heartbeatMs ?? 5000
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isFinite(heartbeatMs) || heartbeatMs <= 0 || heartbeatMs > 5000) {
    throw new Error('Invalid TUN session timing')
  }
  const socket = createConnection(path)
  const listeners = new Set<() => void>()
  let bytes = Buffer.alloc(0)
  let failure: Error | undefined
  let finished = false
  let stopping = false
  let session = ''
  let sequence = 0
  let leaseDeadline = Infinity
  let lastSentAt = performance.now()
  let leaseTimer: ReturnType<typeof setTimeout> | undefined
  let heartbeatTimer: ReturnType<typeof setTimeout> | undefined
  let heartbeatFlight: Promise<void> | undefined
  let pending: { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> } | undefined
  const fail = (error: Error) => {
    if (finished || failure) return
    failure = error
    clearTimeout(leaseTimer)
    clearTimeout(heartbeatTimer)
    if (pending) { clearTimeout(pending.timer); pending.reject(error); pending = undefined }
    socket.destroy()
    for (const listener of listeners) listener()
  }
  const renewLease = (sentAt: number) => {
    leaseDeadline = sentAt + 15000
    clearTimeout(leaseTimer)
    const remaining = leaseDeadline - performance.now()
    if (remaining <= 0) { fail(new Error('TUN session lease expired; network state unknown')); return }
    leaseTimer = setTimeout(() => fail(new Error('TUN session lease expired; network state unknown')), remaining)
    leaseTimer.unref()
  }
  const exchange = (frame: string): Promise<unknown> => new Promise((resolve, reject) => {
    if (failure || finished || pending) { reject(failure ?? new Error('TUN session is not available')); return }
    const timer = setTimeout(() => fail(new Error('TUN session response timed out; network state unknown')), timeoutMs)
    pending = { resolve, reject, timer }
    socket.write(frame)
  })
  socket.on('data', chunk => {
    try {
      if (!pending || performance.now() >= leaseDeadline) throw new Error('Unexpected or expired TUN session response')
      if (bytes.length + chunk.length > maxBytes) throw new Error('TUN session response exceeds limit')
      bytes = Buffer.concat([bytes, chunk])
      const end = bytes.indexOf(10)
      if (end === -1) return
      if (end !== bytes.length - 1) throw new Error('Invalid TUN session response framing')
      const value = parseResponse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, end)))
      bytes = Buffer.alloc(0)
      const current = pending
      pending = undefined
      clearTimeout(current.timer)
      current.resolve(value)
    } catch (error) { fail(error as Error) }
  })
  socket.on('error', fail)
  socket.on('end', () => fail(new Error('TUN session disconnected; network state unknown')))
  socket.on('close', () => fail(new Error('TUN session disconnected; network state unknown')))
  const response = (value: unknown, allowed: string[]): Record<string, unknown> => {
    if (!keys(value, allowed) || value.version !== 2 || typeof value.ok !== 'boolean') throw new Error('Invalid TUN session response')
    if (!value.ok) {
      if (!keys(value, ['version', 'ok', 'error']) || typeof value.error !== 'string' || !value.error || value.error.length > 4096) {
        throw new Error('Invalid TUN session error')
      }
      throw new Error(value.error)
    }
    if (value.error !== undefined) throw new Error('Invalid TUN session response')
    return value
  }
  const status = (value: unknown, state: 'on' | 'off'): TunStatus => {
    if (!keys(value, ['availability', 'state']) || value.availability !== 'ready' || value.state !== state) {
      throw new Error('Invalid TUN session status')
    }
    return { availability: 'ready', state }
  }
  const command = async (operation: 'heartbeat' | 'stop'): Promise<TunStatus | undefined> => {
    if (!Number.isSafeInteger(sequence + 1)) throw new Error('TUN session sequence exhausted')
    const expected = ++sequence
    const sentAt = performance.now()
    lastSentAt = sentAt
    const value = response(await exchange(`${JSON.stringify({ version: 2, operation, session, sequence: expected })}\n`),
      operation === 'stop' ? ['version', 'ok', 'sequence', 'status', 'error'] : ['version', 'ok', 'sequence', 'error'])
    if (failure) throw failure
    if (value.sequence !== expected) throw new Error('Invalid TUN session sequence')
    if (operation === 'stop') return status(value.status, 'off')
    renewLease(sentAt)
  }
  const scheduleHeartbeat = () => {
    if (stopping || failure || finished) return
    heartbeatTimer = setTimeout(() => {
      heartbeatFlight = command('heartbeat').then(() => { scheduleHeartbeat() }, error => { fail(error as Error) })
    }, Math.max(0, heartbeatMs - (performance.now() - lastSentAt)))
    heartbeatTimer.unref()
  }
  try {
    const sentAt = performance.now()
    const opened = response(await exchange(frame), ['version', 'ok', 'session', 'leaseMilliseconds', 'sequence', 'status', 'error'])
    if (typeof opened.session !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(opened.session)
      || opened.leaseMilliseconds !== 15000 || opened.sequence !== 0) throw new Error('Invalid TUN session opening')
    status(opened.status, 'on')
    if (failure) throw failure
    session = opened.session
    renewLease(sentAt)
    scheduleHeartbeat()
  } catch (error) { fail(error as Error); throw error }
  return {
    subscribe: listener => { listeners.add(listener); return () => { listeners.delete(listener) } },
    error: () => failure,
    disconnect: () => fail(new Error('TUN session disconnected; network state unknown')),
    stop: async () => {
      if (stopping) throw new Error('TUN session stop is already in progress')
      stopping = true
      clearTimeout(heartbeatTimer)
      await heartbeatFlight
      try {
        const result = await command('stop')
        // The stop reply proves cleanup; a separate status connection is still required by the adapter.
        finished = true
        clearTimeout(leaseTimer)
        socket.destroy()
        return result!
      } catch (error) { fail(error as Error); throw error }
    },
  }
}

export function createMacosTun(options: {
  endpointPresent?: () => Promise<boolean>
  request?: (operation: Operation) => Promise<TunStatus>
  open?: (config: TunSessionConfig) => Promise<TunHelperSession>
} = {}): TunPlatform {
  const present = options.endpointPresent ?? endpointPresent
  const request = options.request ?? requestTunHelper
  const open = options.open ?? openTunHelperSession
  const missing: TunStatus = { availability: 'not-installed', state: 'off' }
  let session: TunHelperSession | undefined
  let detachSession: (() => void) | undefined
  const listeners = new Set<() => void>()
  const clearSession = (owner: TunHelperSession) => {
    if (session !== owner) return
    detachSession?.()
    detachSession = undefined
    session = undefined
  }
  let busy = false
  const inspect = async (): Promise<TunStatus> => {
    const inspectingSession = session
    try {
      const installed = await present()
      if (!installed && inspectingSession) throw new Error('TUN helper disappeared; network state unknown')
      const observed = installed ? await request('status') : { ...missing }
      const failure = inspectingSession?.error()
      if (failure && observed.state !== 'off') throw failure
      if (inspectingSession && session === inspectingSession && observed.state === 'off') {
        clearSession(inspectingSession)
        inspectingSession.disconnect()
      }
      return observed
    } catch (error) {
      return { availability: 'blocked', state: 'unknown', error: error instanceof Error ? error.message : String(error) }
    }
  }
  const change = async (operation: 'start' | 'stop' | 'recover', config?: TunSessionConfig): Promise<TunStatus> => {
    if (busy) throw new Error('TUN operation is already in progress')
    busy = true
    try {
      const admitted = operation === 'start' ? validateTunSessionConfig(config) : undefined
      const ownedSession = session
      if (operation !== 'start' && ownedSession) {
        try { await ownedSession.stop() }
        catch { /* A lost acknowledgement is not evidence of failure or cleanup; read back independently. */ }
        ownedSession.disconnect()
        let observed = await request('status')
        if (observed.state !== 'off' && operation === 'recover') {
          const recovered = await request('recover')
          if (recovered.state !== 'off') throw new Error(recovered.error || 'TUN helper recovery could not confirm cleanup')
          observed = await request('status')
        }
        if (observed.state !== 'off') throw new Error(observed.error || 'TUN helper state confirmation failed; network state unknown')
        clearSession(ownedSession)
        return observed
      }
      if (!await present()) {
        if (operation === 'start') throw new Error('TUN helper is not installed')
        if (session) throw new Error('TUN helper disappeared; network state unknown')
        return { ...missing }
      }
      const before = await request('status')
      if (operation === 'start') {
        if (session || before.availability !== 'ready' || before.state !== 'off') throw new Error(before.error || 'TUN helper is not ready for a new session')
        const openedSession = await open(admitted!)
        session = openedSession
        detachSession = openedSession.subscribe?.(() => {
          if (session === openedSession) for (const listener of listeners) listener()
        })
        try {
          const observed = await request('status')
          if (session !== openedSession || openedSession.error() || observed.availability !== 'ready' || observed.state !== 'on') {
            throw new Error(observed.error || 'TUN helper state confirmation failed; network state unknown')
          }
          return observed
        } catch (error) { openedSession.disconnect(); throw error }
      }
      if (before.state === 'off') return before
      const result = await request(operation)
      if (result.state !== 'off') throw new Error(result.error || 'TUN helper could not confirm the requested network state')
      const observed = await request('status')
      if (observed.state !== 'off') throw new Error(observed.error || 'TUN helper state confirmation failed')
      return observed
    } finally { busy = false }
  }
  return { subscribe: listener => { listeners.add(listener); return () => { listeners.delete(listener) } },
    inspect, recover: () => change('recover'), start: config => change('start', config), stop: () => change('stop') }
}
