export type SessionEndPhase = 'query-session-end' | 'session-end'

/** The part of Electron's BaseWindow that carries Windows session-end events (WM_QUERYENDSESSION / WM_ENDSESSION). */
export interface SessionEndSource {
  on(event: 'query-session-end', listener: (event: { reasons: string[] }) => void): unknown
  on(event: 'session-end', listener: (event: { reasons: string[] }) => void): unknown
}

/**
 * Runs `onEnd` on logoff, shutdown or restart. Cleanup should start at query-session-end, because Windows
 * may end the process any time after session-end returns; session-end calls `onEnd` again as a fallback.
 * Never calls preventDefault: Clash Kuro must not delay or veto the session end.
 */
export function watchSessionEnd(source: SessionEndSource, onEnd: (phase: SessionEndPhase, reasons: string[]) => void): void {
  source.on('query-session-end', (event) => onEnd('query-session-end', event.reasons))
  source.on('session-end', (event) => onEnd('session-end', event.reasons))
}
