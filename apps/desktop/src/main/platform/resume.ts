import type { Platform } from '@kuro/core'
import type { MihomoClient } from '@kuro/api'

export function createResumeHandler(options: {
  platform: Pick<Platform, 'isCoreRunning' | 'startCore'>
  client?: Pick<MihomoClient, 'closeAllConnections'>
  closeAllConnections?: () => Promise<void>
  reapplySystemProxy: () => Promise<void>
}): () => Promise<void> {
  const closeConnections = options.closeAllConnections ?? (options.client && (() => options.client!.closeAllConnections()))
  if (!closeConnections) throw new Error('Resume handler requires client or closeAllConnections')
  let pending: Promise<void> | undefined
  return () => {
    // Coalesce duplicate OS resume events without hiding errors from the caller.
    pending ??= (async () => {
      const running = await options.platform.isCoreRunning()
      if (!running) await options.platform.startCore()
      try {
        if (running) await closeConnections()
      } finally { await options.reapplySystemProxy() }
    })().finally(() => { pending = undefined })
    return pending
  }
}
