import { describe, expect, test } from 'vitest'
import {
  applyProfileUpdate, effectiveUpdateIntervalHours, isDue, nextUpdateAt,
  parseSubscriptionUserinfo, parseUpdateInterval
} from './index'
import type { FetchResult, Profile } from './index'

const HOUR = 3_600_000
const profile: Profile = {
  id: 'p1', name: 'Test', source: { kind: 'remote', url: 'https://example.com/sub' },
  updatedAt: HOUR, lastError: null, subscriptionInfo: { upload: 1, download: 2, total: 10 },
  serverUpdateIntervalHours: 12, userUpdateIntervalHours: null
}

describe('parseSubscriptionUserinfo', () => {
  test('parses bytes and expiry in Unix seconds, tolerating whitespace and unknown fields', () => {
    expect(parseSubscriptionUserinfo(' download = 2 ; UPLOAD=1; total=10; expire=1800000000; extra=value; ')).toEqual({
      upload: 1, download: 2, total: 10, expireAt: 1800000000
    })
  })

  test('expiry is optional; zero values are preserved', () => {
    expect(parseSubscriptionUserinfo('upload=0; download=0; total=0')).toEqual({ upload: 0, download: 0, total: 0 })
    expect(parseSubscriptionUserinfo('upload=0; download=0; total=0; expire=0')?.expireAt).toBe(0)
  })

  test.each([undefined, null, '', ' ', 'upload=1', 'upload=1; download=2',
    'upload=1; download=2; total=3; expire=', 'upload=1; download=2; total=3; expire=invalid',
    'upload=1; download=2; total=3; total=4', 'upload=1; download=2; total=3; broken'])('ignores malformed header %j', header => {
    expect(parseSubscriptionUserinfo(header)).toBeNull()
  })

  test.each(['-1', '1.2', 'NaN', 'Infinity', '0x10', '1e3', '9007199254740992', ''])('rejects invalid counters %s', value => {
    expect(parseSubscriptionUserinfo(`upload=${value}; download=2; total=3`)).toBeNull()
  })
})

describe('parseUpdateInterval', () => {
  test.each([['24', 24], [' 12 ', 12], ['0.5', 0.5]])('parses hours: %s', (header, expected) => {
    expect(parseUpdateInterval(header)).toBe(expected)
  })

  test.each([undefined, null, '', ' ', '0', '-1', 'NaN', 'Infinity', '1e309', '0x18', '24h', '12;24', '9'.repeat(310)])('rejects %j', header => {
    expect(parseUpdateInterval(header)).toBeNull()
  })
})

describe('update scheduling', () => {
  test('user override wins, then server, then 24 hours', () => {
    expect(effectiveUpdateIntervalHours({ ...profile, userUpdateIntervalHours: 2 })).toBe(2)
    expect(effectiveUpdateIntervalHours(profile)).toBe(12)
    expect(effectiveUpdateIntervalHours({ ...profile, serverUpdateIntervalHours: null })).toBe(24)
  })

  test.each([0, -1, NaN, Infinity, Number.MAX_VALUE])('ignores invalid persisted intervals %s', invalid => {
    expect(effectiveUpdateIntervalHours({ ...profile, userUpdateIntervalHours: invalid })).toBe(12)
    expect(effectiveUpdateIntervalHours({ ...profile, userUpdateIntervalHours: invalid, serverUpdateIntervalHours: invalid })).toBe(24)
  })

  test('calculates absolute timestamps; due is inclusive', () => {
    expect(nextUpdateAt(profile, 2 * HOUR)).toBe(13 * HOUR)
    expect(isDue(profile, 13 * HOUR - 1)).toBe(false)
    expect(isDue(profile, 13 * HOUR)).toBe(true)
    expect(isDue(profile, 14 * HOUR)).toBe(true)
    expect(nextUpdateAt({ ...profile, userUpdateIntervalHours: 0.5 }, HOUR)).toBe(1.5 * HOUR)
  })

  test('never-fetched remote profiles are due immediately, including at epoch zero', () => {
    const fresh = { ...profile, updatedAt: null }
    expect(nextUpdateAt(fresh, 0)).toBe(0)
    expect(isDue(fresh, 0)).toBe(true)
    expect(nextUpdateAt({ ...profile, updatedAt: 0 }, 0)).toBe(12 * HOUR)
  })

  test('last failed attempt delays retries without changing the successful timestamp', () => {
    expect(nextUpdateAt(profile, 14 * HOUR, 14 * HOUR)).toBe(26 * HOUR)
    expect(isDue(profile, 14 * HOUR, 14 * HOUR)).toBe(false)
    expect(isDue(profile, 26 * HOUR, 14 * HOUR)).toBe(true)
    expect(nextUpdateAt(profile, 2 * HOUR, 0)).toBe(13 * HOUR)
  })

  test('local profiles never auto-update', () => {
    const local: Profile = { ...profile, source: { kind: 'local', path: '/config.yaml' } }
    expect(nextUpdateAt(local, 100 * HOUR)).toBeNull()
    expect(isDue(local, 100 * HOUR)).toBe(false)
  })
})

describe('applyProfileUpdate', () => {
  const success: FetchResult = {
    status: 200,
    headers: { 'subscription-userinfo': 'upload=3; download=4; total=20', 'profile-update-interval': '6' },
    body: '# original content\nproxies: []\nsecret: keep-original\nexternal-controller: 0.0.0.0:9090\n'
  }

  test('success replaces raw content and metadata, clears errors and preserves user settings', () => {
    const previous = { ...profile, lastError: 'failed', userUpdateIntervalHours: 2 }
    const before = JSON.parse(JSON.stringify(previous))
    const result = applyProfileUpdate(previous, 'old', success, 20 * HOUR)
    expect(result).toEqual({
      ok: true, content: success.body, attemptedAt: 20 * HOUR, nextUpdateAt: 22 * HOUR,
      profile: {
        ...previous, updatedAt: 20 * HOUR, lastError: null,
        subscriptionInfo: { upload: 3, download: 4, total: 20 }, serverUpdateIntervalHours: 6
      }
    })
    expect(previous).toEqual(before)
  })

  test('absent or malformed metadata clears stale values and falls back to 24 hours', () => {
    const examples: Record<string, string>[] = [{}, { 'subscription-userinfo': 'invalid', 'profile-update-interval': '-1' }]
    for (const headers of examples) {
      const result = applyProfileUpdate(profile, 'old', { ...success, headers }, 20 * HOUR)
      expect(result.profile.subscriptionInfo).toBeNull()
      expect(result.profile.serverUpdateIntervalHours).toBeNull()
      expect(result.nextUpdateAt).toBe(44 * HOUR)
    }
  })

  test.each<FetchResult | { error: string }>([
    { error: 'Network failure' }, { error: '' },
    { ...success, status: 404 }, { ...success, status: 304 }, { ...success, status: 500 },
    { ...success, status: NaN }, { ...success, status: 200.5 },
    { ...success, body: 'proxies: [' }, { ...success, body: '' }
  ])('failure preserves content and successful metadata and schedules the next cycle: %j', failure => {
    const before = JSON.parse(JSON.stringify(profile))
    const result = applyProfileUpdate(profile, 'old content', failure, 20 * HOUR)
    expect(result.ok).toBe(false)
    expect(result.content).toBe('old content')
    expect(result.profile).toEqual({ ...profile, lastError: expect.any(String) })
    expect(result.profile.lastError?.length).toBeGreaterThan(0)
    expect(result.attemptedAt).toBe(20 * HOUR)
    expect(result.nextUpdateAt).toBe(32 * HOUR)
    expect(isDue(result.profile, 20 * HOUR, result.attemptedAt)).toBe(false)
    expect(isDue(result.profile, 32 * HOUR, result.attemptedAt)).toBe(true)
    expect(profile).toEqual(before)
  })

  test('a local import has no automatic update deadline', () => {
    expect(applyProfileUpdate({ ...profile, source: { kind: 'local', path: 'a.yaml' } }, '', success, 0).nextUpdateAt).toBeNull()
  })
})
