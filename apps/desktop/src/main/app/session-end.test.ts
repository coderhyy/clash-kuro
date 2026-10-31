import { EventEmitter } from 'node:events'
import { expect, test, vi } from 'vitest'
import type { SyncClearReport } from '../platform'
import { formatSyncClear, watchSessionEnd } from './session-end'

const sessionEvent = (reasons: string[]) => ({ reasons, preventDefault: vi.fn() })
const report = (extra: Partial<SyncClearReport>): SyncClearReport =>
  ({ ran: true, ok: true, exitCode: 0, timedOut: false, durationMs: 80, servers: ['127.0.0.1:7891'], ...extra })

function fixture(...reports: SyncClearReport[]) {
  const source = new EventEmitter()
  const order: string[] = []
  const lines: string[] = []
  const deps = {
    clearSystemProxySync: vi.fn(() => { order.push('clear'); return reports.shift() ?? report({}) }),
    exit: vi.fn((phase: string) => { order.push(`exit ${phase}`) }),
    log: vi.fn((line: string) => { lines.push(line) }),
  }
  watchSessionEnd(source, deps)
  return { source, deps, order, lines }
}

test('query-session-end clears the proxy synchronously before exit, without delaying the session end', () => {
  const { source, order, lines } = fixture()
  const event = sessionEvent(['logoff'])
  source.emit('query-session-end', event)
  expect(order).toEqual(['clear', 'exit query-session-end'])
  expect(event.preventDefault).not.toHaveBeenCalled()
  expect(lines).toEqual(['query-session-end (logoff)', 'sync clear ok: exit=0 timedOut=false 80 ms servers=127.0.0.1:7891'])
})

test('session-end does not clear again after a successful clear', () => {
  const { source, deps, order } = fixture()
  source.emit('query-session-end', sessionEvent(['shutdown']))
  const event = sessionEvent(['shutdown'])
  source.emit('session-end', event)
  expect(deps.clearSystemProxySync).toHaveBeenCalledOnce()
  expect(order).toEqual(['clear', 'exit query-session-end', 'exit session-end'])
  expect(event.preventDefault).not.toHaveBeenCalled()
})

test('session-end retries a clear that failed or timed out', () => {
  const { source, deps, lines } = fixture(report({ ok: false, exitCode: null, timedOut: true, durationMs: 1500 }), report({}))
  source.emit('query-session-end', sessionEvent(['critical', 'logoff']))
  source.emit('session-end', sessionEvent(['critical', 'logoff']))
  expect(deps.clearSystemProxySync).toHaveBeenCalledTimes(2)
  expect(lines[1]).toBe('sync clear FAILED: exit=none timedOut=true 1500 ms servers=127.0.0.1:7891')
  expect(lines[3]).toMatch(/^sync clear ok/)
})

test('a throwing clear is logged and exit still runs', () => {
  const source = new EventEmitter()
  const exit = vi.fn()
  const lines: string[] = []
  watchSessionEnd(source, { clearSystemProxySync: () => { throw new Error('boom') }, exit, log: (line) => lines.push(line) })
  source.emit('query-session-end', sessionEvent(['logoff']))
  expect(exit).toHaveBeenCalledWith('query-session-end')
  expect(lines[1]).toMatch(/skipped \(threw: Error: boom\)/)
})

test('the log names a helper that Windows failed to initialize (0xC0000142, clash-verge-rev #5018)', () => {
  expect(formatSyncClear(report({ ok: false, exitCode: 3221225794, durationMs: 12 })))
    .toBe('sync clear FAILED: exit=3221225794 (0xC0000142 DLL init failed) timedOut=false 12 ms servers=127.0.0.1:7891')
  expect(formatSyncClear({ ran: false, ok: true, exitCode: null, timedOut: false, durationMs: 0, servers: [], detail: 'nothing of ours to clear' }))
    .toBe('sync clear skipped (nothing of ours to clear)')
})
