import { spawn } from 'node:child_process'
import { join } from 'node:path'
import { prepareRecoveryHelper } from './recovery-helper'
import { residentClient, type AuthorizeResident } from './resident-client'

/** One helper/Core lifetime. Caller must complete legacy migration before calling. */
export async function startResidentSession(options: {
  helper: string; recoveryDirectory: string; dataDir: string; core: string; server: string; log: string; signal?: AbortSignal
  /** Native reservation holds ownership through evidence checks, replay and Core lifetime. */
  authorize?: AuthorizeResident
  initialEndpoints?: readonly string[]
}) {
  options.signal?.throwIfAborted()
  if (!options.authorize) throw new Error('Resident requires native reservation and migration authorization')
  const helper = await prepareRecoveryHelper(options.helper, options.recoveryDirectory)
  const journal = join(options.recoveryDirectory, 'recovery.bin')
  options.signal?.throwIfAborted()
  const child = spawn(helper, ['reserve', '--core', options.core, '--data', options.dataDir,
    '--expected-server', options.server, '--log', options.log,
    ...(options.initialEndpoints ?? []).flatMap(server => ['--initial-server', server])],
  { windowsHide: true, detached: true, stdio: 'pipe' })
  const client = residentClient(child, 10_000, options.authorize)
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
