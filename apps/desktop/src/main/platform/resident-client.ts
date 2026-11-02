import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { StringDecoder } from 'node:string_decoder'
import { residentClose, residentRequest } from './resident-protocol'

type ShutdownReport = { command: 'shutdown'; ok: boolean; timedOut: boolean; coreGone: boolean; corePid: number; durationMs: number }

/** One prestarted process, one outstanding command. Lifecycle supervision remains native.
 * close() sends a trigger; only exited proves that this process can no longer write proxy settings.
 */
export function residentClient(child: ChildProcessWithoutNullStreams, timeoutMs = 10_000) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid resident request timeout')
  let state: 'starting' | 'ready' | 'busy' | 'closing' | 'exited' = 'starting'
  let buffer = ''
  let report: ShutdownReport | null = null
  let invalidOutput = false
  let diagnostics = Buffer.alloc(0)
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
  child.stdout?.on('error', error => badOutput(error.message))
  child.stderr?.on('error', error => close(error))
  // Never let unread diagnostics block a native worker; bounded reports arrive on stdout.
  child.stderr?.on('data', (chunk: Buffer) => {
    diagnostics = Buffer.from(Buffer.concat([diagnostics, chunk]).subarray(-16 * 1024))
  })
  child.on('error', error => close(error))
  let finishClosed!: (value: { code: number | null; signal: NodeJS.Signals | null; report: ShutdownReport | null }) => void
  // exit alone does not mean stdout has drained; final evidence is available only after close.
  const closed = new Promise<{ code: number | null; signal: NodeJS.Signals | null; report: ShutdownReport | null }>(resolve => { finishClosed = resolve })
  function outputClosed(code: number | null, signal: NodeJS.Signals | null): void {
    finishClosed({ code, signal, report: invalidOutput || buffer.length ? null : report })
  }
  child.once('close', outputClosed)
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(resolve => {
    const finish = (code: number | null, signal: NodeJS.Signals | null) => {
      close(new Error(`Resident helper exited (${code ?? signal}); state unknown`))
      state = 'exited'
      resolve({ code, signal })
    }
    child.once('exit', finish)
    child.once('error', error => {
      // A spawn error has no process and may have no exit event; a runtime error is not exit proof.
      if (child.pid === undefined) { state = 'exited'; resolve({ code: null, signal: null }); readyReject(error); outputClosed(null, null) }
    })
    if (child.exitCode !== null || child.signalCode !== null) {
      finish(child.exitCode, child.signalCode)
      if (child.stdout?.destroyed && child.stderr?.destroyed) outputClosed(child.exitCode, child.signalCode)
    }
  })
  function badOutput(message: string): void {
    invalidOutput = true; buffer = ''; close(new Error(message))
  }
  child.stdout?.on('data', (chunk: Buffer) => {
    if (invalidOutput) return
    buffer += decoder.write(chunk)
    if (Buffer.byteLength(buffer) > 1024 * 1024) { badOutput('Resident helper response exceeds limit'); return }
    for (;;) {
      const newline = buffer.indexOf('\n')
      if (newline < 0) break
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1)
      let value: { ready?: unknown; protocol?: unknown; command?: unknown; ok?: unknown; timedOut?: unknown; coreGone?: unknown; corePid?: unknown; durationMs?: unknown }
      try {
        value = JSON.parse(line)
        if (!value || typeof value !== 'object') throw new Error('Not an object')
      } catch { badOutput('Invalid resident helper response'); return }
      if (report) { badOutput('Output after final shutdown report'); return }
      if (value.command === 'shutdown') {
        if (typeof value.ok !== 'boolean' || typeof value.timedOut !== 'boolean' || typeof value.coreGone !== 'boolean' ||
            typeof value.corePid !== 'number' || !Number.isInteger(value.corePid) || value.corePid < 0 || value.corePid > 0xffffffff ||
            typeof value.durationMs !== 'number' || !Number.isFinite(value.durationMs) || value.durationMs < 0 ||
            (value.ok && (value.timedOut || !value.coreGone))) {
          badOutput('Invalid shutdown report'); return
        }
        report = { command: 'shutdown', ok: value.ok, timedOut: value.timedOut, coreGone: value.coreGone, corePid: value.corePid, durationMs: value.durationMs }
        close(new Error('Native helper has closed; no further writes allowed'))
      } else if (state === 'closing' || state === 'exited') {
        // An already admitted operation may finish after close; never reopen admission.
        if (!['get', 'set', 'clear'].includes(String(value.command)) || typeof value.ok !== 'boolean') {
          badOutput('Unexpected late response'); return
        }
      } else if (state === 'starting' && value.ready === true && value.protocol === 1) {
        state = 'ready'; clearTimeout(timer); readyResolve()
      } else if (state === 'busy' && pending && value.command === pending.command && typeof value.ok === 'boolean') {
        const result = pending; pending = undefined
        state = 'ready'; clearTimeout(timer)
        result.resolve({ stdout: line + '\n', stderr: '' })
      } else { badOutput('Unexpected resident helper response'); return }
    }
  })
  child.stdout?.once('end', () => {
    buffer += decoder.end()
    close(new Error('Resident helper output ended; state unknown'))
  })
  if (!child.stdin || !child.stdout || !child.stderr) close(new Error('Resident helper pipes unavailable'))
  return {
    ready, exited, closed, close,
    diagnostics: () => diagnostics.toString('utf8'),
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
