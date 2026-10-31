import type { SyncClearReport } from '../platform'

export type SessionEndPhase = 'query-session-end' | 'session-end'

/** The part of Electron's BaseWindow that carries Windows session-end events (WM_QUERYENDSESSION / WM_ENDSESSION). */
export interface SessionEndSource {
  on(event: 'query-session-end', listener: (event: { reasons: string[] }) => void): unknown
  on(event: 'session-end', listener: (event: { reasons: string[] }) => void): unknown
}

/** 0xC0000142 STATUS_DLL_INIT_FAILED: Windows refused to start the helper (seen during shutdown, clash-verge-rev #5018). */
const DLL_INIT_FAILED = 0xC0000142

export function formatSyncClear(report: SyncClearReport): string {
  if (!report.ran) return `sync clear skipped (${report.detail ?? 'not run'})`
  const exitCode = report.exitCode
  // NTSTATUS exit codes are shown as unsigned hex whichever sign Node reports them with.
  const ntstatus = exitCode !== null && (exitCode < 0 || exitCode > 255) ? exitCode >>> 0 : null
  const code = exitCode === null ? 'none'
    : ntstatus !== null ? `${exitCode} (0x${ntstatus.toString(16).toUpperCase()}${ntstatus === DLL_INIT_FAILED ? ' DLL init failed' : ''})`
      : String(exitCode)
  return `sync clear ${report.ok ? 'ok' : 'FAILED'}: exit=${code} timedOut=${report.timedOut} ${report.durationMs} ms`
    + ` servers=${report.servers.join(',') || 'none'}${report.detail ? ` ${report.detail}` : ''}`
}

/**
 * Windows logoff/shutdown. The process may be ended right after session-end returns, so the System Proxy is
 * cleared synchronously inside the handler; Core is then stopped asynchronously by `exit`. session-end retries
 * the clear when query-session-end did not succeed. Never calls preventDefault: Kuro must not delay or veto the end.
 */
export function watchSessionEnd(source: SessionEndSource, deps: {
  clearSystemProxySync(): SyncClearReport
  exit(phase: SessionEndPhase): void
  log(line: string): void
}): void {
  let cleared = false
  const onEnd = (phase: SessionEndPhase, reasons: string[]) => {
    deps.log(`${phase} (${reasons.join(',') || 'no reason'})`)
    if (!cleared) {
      let report: SyncClearReport
      try { report = deps.clearSystemProxySync() } catch (error) {
        report = { ran: false, ok: false, exitCode: null, timedOut: false, durationMs: 0, servers: [], detail: `threw: ${String(error)}` }
      }
      cleared = report.ok
      deps.log(formatSyncClear(report))
    }
    deps.exit(phase)
  }
  source.on('query-session-end', (event) => onEnd('query-session-end', event.reasons))
  source.on('session-end', (event) => onEnd('session-end', event.reasons))
}
