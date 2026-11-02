import { spawn } from 'node:child_process'
import { join } from 'node:path'
import { prepareRecoveryHelper } from './recovery-helper'
import { recoverResident } from './resident-recovery'
import { residentClient } from './resident-client'

/** One helper/Core lifetime. Caller must complete legacy migration before calling. */
export async function startResidentSession(options: {
  helper: string; recoveryDirectory: string; dataDir: string; core: string; server: string; log: string; signal?: AbortSignal
}) {
  options.signal?.throwIfAborted()
  const helper = await prepareRecoveryHelper(options.helper, options.recoveryDirectory)
  const journal = join(options.recoveryDirectory, 'recovery.bin')
  options.signal?.throwIfAborted()
  await recoverResident(helper, journal, options.log)
  options.signal?.throwIfAborted()
  const child = spawn(helper, ['serve', '--core', options.core, '--data', options.dataDir,
    '--recovery', journal, '--expected-server', options.server, '--log', options.log],
  { windowsHide: true, detached: true, stdio: 'pipe' })
  const client = residentClient(child)
  let closing: Promise<void> | undefined
  function close(): Promise<void> {
    if (closing) return closing
    client.close()
    closing = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('Resident exit deadline exceeded; new proxy writes forbidden'))
        try {
          if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
        } catch { /* No termination request can turn unknown cleanup into success. */ }
      }, 2500)
      void client.closed.then(result => {
        clearTimeout(timer)
        if (result.code === 0 && result.signal === null && result.report?.ok === true &&
            !result.report.timedOut && result.report.coreGone) resolve()
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
