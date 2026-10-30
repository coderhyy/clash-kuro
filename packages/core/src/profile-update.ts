import type { FetchResult, Profile, SubscriptionInfo } from './index'
import { parseProfile } from './config'

const HOUR_MS = 60 * 60 * 1000

function positiveHours(value: number | null): value is number {
  return value !== null && Number.isFinite(value) && value > 0 && Number.isFinite(value * HOUR_MS)
}

/** Missing or malformed headers are absent metadata, not zero-valued metadata. */
export function parseSubscriptionUserinfo(header: string | null | undefined): SubscriptionInfo | null {
  if (!header?.trim()) return null
  const fields = new Map<string, number>()
  for (const part of header.split(';')) {
    if (!part.trim()) continue
    const match = /^\s*([\w-]+)\s*=\s*(.*?)\s*$/.exec(part)
    if (!match) return null
    const key = match[1]!.toLowerCase()
    if (!['upload', 'download', 'total', 'expire'].includes(key)) continue
    const raw = match[2]!
    const value = Number(raw)
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || fields.has(key)) return null
    fields.set(key, value)
  }
  const upload = fields.get('upload')
  const download = fields.get('download')
  const total = fields.get('total')
  if (upload === undefined || download === undefined || total === undefined) return null
  const expireAt = fields.get('expire')
  return { upload, download, total, ...(expireAt === undefined ? {} : { expireAt }) }
}

export function parseUpdateInterval(header: string | null | undefined): number | null {
  if (!header || !/^\d+(?:\.\d+)?$/.test(header.trim())) return null
  const hours = Number(header)
  return positiveHours(hours) ? hours : null
}

export function effectiveUpdateIntervalHours(profile: Profile): number {
  if (positiveHours(profile.userUpdateIntervalHours)) return profile.userUpdateIntervalHours
  if (positiveHours(profile.serverUpdateIntervalHours)) return profile.serverUpdateIntervalHours
  return 24
}

/** Local profiles do not auto-update; a never-fetched remote profile is due now.
 * Pass the last attempt separately after failure: updatedAt only tracks success.
 */
export function nextUpdateAt(profile: Profile, now: number, lastAttemptAt: number | null = null): number | null {
  if (profile.source.kind === 'local') return null
  const anchors = [profile.updatedAt, lastAttemptAt].filter((value): value is number => value !== null)
  const anchor = anchors.length ? Math.max(...anchors) : now
  return anchors.length ? anchor + effectiveUpdateIntervalHours(profile) * HOUR_MS : now
}

export function isDue(profile: Profile, now: number, lastAttemptAt: number | null = null): boolean {
  const next = nextUpdateAt(profile, now, lastAttemptAt)
  return next !== null && now >= next
}

export interface ProfileUpdateResult {
  ok: boolean
  profile: Profile
  content: string
  attemptedAt: number
  nextUpdateAt: number | null
}

/** Fetch/retry and persistence belong to Platform's caller, not this pure reducer. */
export function applyProfileUpdate(
  profile: Profile,
  previousContent: string,
  result: FetchResult | { error: string },
  now: number
): ProfileUpdateResult {
  let error: string | null = null
  if ('error' in result) error = result.error.trim() || 'Profile update failed.'
  else if (result.status < 200 || result.status >= 300 || !Number.isInteger(result.status)) {
    error = `Profile update failed: HTTP ${result.status}.`
  } else {
    const parsed = parseProfile(result.body)
    if (!parsed.ok) error = parsed.error
  }

  const updated: Profile = error !== null || 'error' in result
    ? { ...profile, lastError: error }
    : {
        ...profile,
        updatedAt: now,
        lastError: null,
        subscriptionInfo: parseSubscriptionUserinfo(result.headers['subscription-userinfo']),
        serverUpdateIntervalHours: parseUpdateInterval(result.headers['profile-update-interval'])
      }
  return {
    ok: error === null,
    profile: updated,
    content: error !== null || 'error' in result ? previousContent : result.body,
    attemptedAt: now,
    nextUpdateAt: nextUpdateAt(updated, now, now)
  }
}
