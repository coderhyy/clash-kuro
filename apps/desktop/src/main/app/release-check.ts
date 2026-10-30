/** Compare dotted versions (`v1.2.3` or `1.2.3`); pre-release suffixes are ignored. */
export function isNewer(latest: string, current: string): boolean {
  const parts = (v: string) => v.replace(/^v/, '').split(/[-+]/)[0]!.split('.').map((n) => Number(n) || 0)
  const a = parts(latest)
  const b = parts(current)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0)
  }
  return false
}

/**
 * Ask GitHub for the latest release (ADR-0010). Returns null when there is nothing newer or the check fails;
 * the check is advisory and must never block startup.
 */
export async function checkForUpdate(options: {
  repo: string | null
  currentVersion: string
  fetch?: typeof fetch
  timeoutMs?: number
}): Promise<{ version: string; url: string } | null> {
  if (!options.repo || !/^[\w.-]+\/[\w.-]+$/.test(options.repo)) return null
  try {
    const res = await (options.fetch ?? fetch)(`https://api.github.com/repos/${options.repo}/releases/latest`, {
      headers: { accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(options.timeoutMs ?? 10_000)
    })
    if (!res.ok) return null
    const body = (await res.json()) as { tag_name?: unknown; html_url?: unknown }
    if (typeof body.tag_name !== 'string' || typeof body.html_url !== 'string') return null
    if (!body.html_url.startsWith(`https://github.com/${options.repo}/releases/`)) return null
    return isNewer(body.tag_name, options.currentVersion) ? { version: body.tag_name, url: body.html_url } : null
  } catch {
    return null
  }
}
