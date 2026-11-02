import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { StringDecoder } from 'node:string_decoder'
import { residentClose, residentRequest } from './resident-protocol'

/** One prestarted process, one outstanding command. Lifecycle supervision remains native.
 * close() sends a trigger; only exited proves that this process can no longer write proxy settings.
 */
export function residentClient(child: ChildProcessWithoutNullStreams, timeoutMs = 10_000) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid resident request timeout')
  let state: 'starting' | 'ready' | 'busy' | 'closing' | 'exited' = 'starting'
  let buffer = ''
  const decoder = new StringDecoder('utf8')
  let readyResolve!: () => void
  let readyReject!: (error: Error) => void
  const ready = new Promise<void>((resolve, reject) => { readyResolve = resolve; readyReject = reject })
  // A native session event can close the process before its caller reaches await ready.
  void ready.catch(() => {})
  let pending: { command: string; resolve(value: { stdout: string; stderr: string }): void; reject(error: Error): void } | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  function close(error = new Error('Resident helper is closing; state unknown')): void {
    if (state === 'closing' || state === 'exited') return
    state = 'closing'
    clearTimeout(timer)
    readyReject(error)
    pending?.reject(error)
    pending = undefined
    buffer = ''
    // No waiting for backpressure or JS acknowledgement: the native reader owns the trigger.
    // This write is not proof of delivery; callers must still await bounded native exit evidence.
    if (child.stdin && !child.stdin.destroyed && !child.stdin.writableEnded) child.stdin.end(residentClose())
  }
  function arm(): void {
    clearTimeout(timer)
    timer = setTimeout(() => close(new Error('Resident helper request timed out; state unknown')), timeoutMs)
  }
  arm()
  child.stdin?.on('error', error => close(error))
  child.stdout?.on('error', error => close(error))
  child.stderr?.on('error', error => close(error))
  // Never let unread diagnostics block a native worker; bounded reports arrive on stdout.
  child.stderr?.resume()
  child.on('error', error => close(error))
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => {
    const finish = (code: number | null, signal: NodeJS.Signals | null) => {
      close(new Error(`Resident helper exited (${code ?? signal}); state unknown`))
      state = 'exited'
      resolve({ code, signal })
    }
    child.once('exit', finish)
    child.once('error', error => {
      // A spawn error has no process and may have no exit event; a runtime error is not exit proof.
      if (child.pid === undefined) { state = 'exited'; resolve({ code: null, signal: null }); readyReject(error) }
    })
    if (child.exitCode !== null || child.signalCode !== null) finish(child.exitCode, child.signalCode)
  })
  child.stdout?.on('data', (chunk: Buffer) => {
    if (state === 'closing' || state === 'exited') return
    buffer += decoder.write(chunk)
    if (Buffer.byteLength(buffer) > 1024 * 1024) { close(new Error('Resident helper response exceeds limit')); return }
    for (;;) {
      const newline = buffer.indexOf('\n')
      if (newline < 0) break
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1)
      let value: { ready?: unknown; protocol?: unknown; command?: unknown; ok?: unknown }
      try {
        value = JSON.parse(line)
        if (!value || typeof value !== 'object') throw new Error('Not an object')
      } catch { close(new Error('Invalid resident helper response')); return }
      if (state === 'starting' && value.ready === true && value.protocol === 1) {
        state = 'ready'; clearTimeout(timer); readyResolve()
      } else if (state === 'busy' && pending && value.command === pending.command && typeof value.ok === 'boolean') {
        const result = pending; pending = undefined
        state = 'ready'; clearTimeout(timer)
        result.resolve({ stdout: line + '\n', stderr: '' })
      } else { close(new Error('Unexpected resident helper response')); return }
    }
  })
  child.stdout?.once('end', () => close(new Error('Resident helper output ended; state unknown')))
  if (!child.stdin || !child.stdout || !child.stderr) close(new Error('Resident helper pipes unavailable'))
  return {
    ready, exited, close,
    request(args: readonly string[]): Promise<{ stdout: string; stderr: string }> {
      if (state !== 'ready') return Promise.reject(new Error(`Resident helper cannot accept writes (${state})`))
      let frame: Buffer
      try { frame = residentRequest(args) } catch (error) { return Promise.reject(error) }
      state = 'busy'
      return new Promise((resolve, reject) => {
        pending = { command: args[0]!, resolve, reject }
        arm()
        child.stdin.write(frame)
      })
    },
  }
}
