import { isDue, nextUpdateAt, type Profile } from '@tern/core'

/**
 * Timed Profile updates. Checks every `tickMs`; a profile is due by `isDue` measured from its last attempt,
 * so a failure waits a full interval instead of retrying at once.
 */
export function createUpdateScheduler(deps: {
  profiles(): Profile[]
  update(profileId: string): Promise<unknown>
  now?: () => number
  tickMs?: number
}) {
  const now = deps.now ?? Date.now
  const lastAttempt = new Map<string, number>()
  let timer: ReturnType<typeof setInterval> | undefined
  let running = false

  async function tick() {
    if (running) return
    running = true
    try {
      for (const profile of deps.profiles()) {
        const attempted = lastAttempt.get(profile.id) ?? null
        if (!isDue(profile, now(), attempted)) continue
        lastAttempt.set(profile.id, now())
        await deps.update(profile.id)
      }
    } finally { running = false }
  }

  return {
    tick,
    start() {
      timer ??= setInterval(() => void tick(), deps.tickMs ?? 60_000)
      void tick()
    },
    stop() {
      clearInterval(timer)
      timer = undefined
    },
    /** For diagnostics/tests. */
    next(profile: Profile) {
      return nextUpdateAt(profile, now(), lastAttempt.get(profile.id) ?? null)
    }
  }
}
