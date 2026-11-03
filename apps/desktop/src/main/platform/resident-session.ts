import { spawn } from 'node:child_process'
import { join } from 'node:path'
import { prepareRecoveryHelper } from './recovery-helper'
import { residentClient } from './resident-client'

/** One native owner holds recovery and Core lifetime without a second proxy writer. */
export async function startResidentSession(options: {
  helper: string; recoveryDirectory: string; dataDir: string; core: string; server: string; log: string; signal?: AbortSignal
}) {
  options.signal?.throwIfAborted()
  const helper = await prepareRecoveryHelper(options.helper, options.recoveryDirectory)
  const journal = join(options.recoveryDirectory, 'recovery.bin')
  options.signal?.throwIfAborted()
  const child = spawn(helper, ['start', '--core', options.core, '--data', options.dataDir,
    '--log', options.log],
  { windowsHide: true, detached: true, stdio: 'pipe' })
  const client = residentClient(child, 10_000)
  let closing: Promise<void | { restartRequired: boolean }> | undefined
  function close(): Promise<void | { restartRequired: boolean }> {
    if (closing) return closing
    client.close()
    closing = new Promise<void | { restartRequired: boolean }>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('Resident exit deadline exceeded; new proxy writes forbidden'))
        try {
          if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
        } catch { /* No termination request can turn unknown cleanup into success. */ }
      }, 2500)
      void client.closed.then(result => {
        clearTimeout(timer)
        if (result.code === 0 && result.signal === null && result.report?.ok === true &&
            !result.report.timedOut && result.report.coreGone) resolve({ restartRequired:
              result.report.firstTrigger !== 2 || (result.report.queryEvents ?? 0) > 0 || (result.report.endEvents ?? 0) > 0 })
        else reject(new Error(`Resident cleanup unverified (${result.code ?? result.signal}); ${client.diagnostics()}`))
      })
    })
    return closing
  }
  const abort = () => { void close().catch(() => {}) }
  options.signal?.addEventListener('abort', abort, { once: true })
  void client.exited.then(() => options.signal?.removeEventListener('abort', abort))
  if (options.signal?.aborted) abort()
  try { await client.ready; options.signal?.throwIfAborted() }
  catch (error) {
    try { await close() } catch { /* Preserve startup error; this session is never returned for reuse. */ }
    throw error
  }
  return { request: client.request, close, exited: client.exited, diagnostics: client.diagnostics, helper, journal }
}
