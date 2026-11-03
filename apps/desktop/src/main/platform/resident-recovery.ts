import { spawn } from 'node:child_process'
import { performance } from 'node:perf_hooks'
import { residentClient } from './resident-client'

/** Caller must not launch a new writer after rejection. No PID lookup or retry. */
export async function recoverResident(helper: string, log: string, timeoutMs = 2500): Promise<void> {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid recovery budget')
  const deadline = performance.now() + timeoutMs
  const child = spawn(helper, ['recover-admitted', '--log', log], {
    windowsHide: true, detached: true, stdio: 'pipe',
  })
  const client = residentClient(child, timeoutMs)
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    const result = await Promise.race([
      client.closed,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
          // Exact child object only. Sending termination is not proof it has exited.
          client.close()
          reject(new Error('Recovery deadline exceeded; writer state unknown, new writes forbidden'))
          try {
            if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
          } catch { /* Rejection already forbids admission, including a failed termination request. */ }
        }, Math.max(0, deadline - performance.now()))
      }),
    ])
    if (result.code !== 0 || result.signal !== null || result.report?.ok !== true ||
        result.report.timedOut || !result.report.coreGone || result.report.corePid !== 0) {
      throw new Error(`Recovery not verified; new writes forbidden (${result.code ?? result.signal}): ${client.diagnostics()}`)
    }
  } finally { clearTimeout(timer) }
}
