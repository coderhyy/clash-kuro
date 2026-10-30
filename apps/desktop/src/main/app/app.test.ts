import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import type { Profile } from '@kuro/core'
import { FakePlatform } from '@kuro/core/fake'
import { contentFile, createProfileSource } from './profiles'
import { createUpdateScheduler } from './scheduler'
import { checkForUpdate, isNewer } from './release-check'
import { installGeoData } from './geo'

const remote: Profile = {
  id: 'p1', name: 'sub', source: { kind: 'remote', url: 'https://example.com/sub' }, updatedAt: null, lastError: null,
  subscriptionInfo: null, serverUpdateIntervalHours: null, userUpdateIntervalHours: null
}
const ok = { status: 200, headers: { 'subscription-userinfo': 'upload=1; download=2; total=3', 'profile-update-interval': '12' }, body: 'proxies: []\nrules: [MATCH,DIRECT]\n' }

test('remote refresh: direct first, then once through Core; stores content and metadata', async () => {
  const platform = new FakePlatform()
  platform.fetchText = vi.fn()
    .mockRejectedValueOnce(new Error('blocked'))
    .mockResolvedValueOnce(ok)
  const source = createProfileSource({ platform, userAgent: 'Clash Kuro', isCoreRunning: async () => true, now: () => 5 })
  const next = await source.refreshProfile(remote)
  expect(vi.mocked(platform.fetchText).mock.calls.map((c) => c[1].viaCore)).toEqual([false, true])
  expect(next).toMatchObject({ updatedAt: 5, lastError: null, serverUpdateIntervalHours: 12, subscriptionInfo: { total: 3 } })
  expect(platform.files.get(contentFile('p1'))).toBe(ok.body)
})

test('remote refresh does not retry through a stopped Core and keeps old content on failure', async () => {
  const platform = new FakePlatform()
  platform.files.set(contentFile('p1'), 'old')
  platform.fetchText = vi.fn().mockResolvedValue({ status: 500, headers: {}, body: '' })
  const source = createProfileSource({ platform, userAgent: 'Clash Kuro', isCoreRunning: async () => false })
  await expect(source.refreshProfile(remote)).rejects.toThrow(/HTTP 500/)
  expect(platform.fetchText).toHaveBeenCalledTimes(1)
  expect(platform.files.get(contentFile('p1'))).toBe('old')
})

test('local refresh reads an absolute path; Runtime Config is built from stored content', async () => {
  const platform = new FakePlatform()
  const source = createProfileSource({ platform, userAgent: 'Clash Kuro', isCoreRunning: async () => false, readLocal: async () => 'mode: global\nsecret: x\n' })
  const local: Profile = { ...remote, source: { kind: 'local', path: '/tmp/a.yaml' } }
  await source.refreshProfile(local)
  await expect(source.refreshProfile({ ...local, source: { kind: 'local', path: 'a.yaml' } })).rejects.toThrow(/absolute/)
  const yaml = await source.buildRuntimeConfig({
    profile: local, settings: { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' },
    controlChannel: { kind: 'unix', path: '/d/mihomo.sock' }
  })
  expect(yaml).toContain('mode: rule')
  expect(yaml).not.toContain('secret')
  expect(yaml).toContain('geo-auto-update: false')
})

test('scheduler updates due profiles and waits a full interval after an attempt', async () => {
  let now = 0
  const update = vi.fn(async () => {})
  const s = createUpdateScheduler({ profiles: () => [remote], update, now: () => now })
  await s.tick()
  await s.tick()
  expect(update).toHaveBeenCalledTimes(1)
  now = 24 * 3600_000
  await s.tick()
  expect(update).toHaveBeenCalledTimes(2)
})

test('release check compares versions and only trusts the configured repo', async () => {
  expect(isNewer('v0.2.0', '0.1.9')).toBe(true)
  expect(isNewer('v0.1.0', '0.1.0')).toBe(false)
  const reply = (body: unknown) => vi.fn(async () => new Response(JSON.stringify(body)))
  const good = reply({ tag_name: 'v9.0.0', html_url: 'https://github.com/a/b/releases/tag/v9.0.0' })
  expect(await checkForUpdate({ repo: 'a/b', currentVersion: '0.0.1', fetch: good })).toEqual({ version: 'v9.0.0', url: 'https://github.com/a/b/releases/tag/v9.0.0' })
  const evil = reply({ tag_name: 'v9.0.0', html_url: 'https://evil.example/x' })
  expect(await checkForUpdate({ repo: 'a/b', currentVersion: '0.0.1', fetch: evil })).toBeNull()
  expect(await checkForUpdate({ repo: null, currentVersion: '0.0.1', fetch: good })).toBeNull()
})

test('geo data is copied once per bundled version', async () => {
  const bundled = await mkdtemp(join(tmpdir(), 'geo-b-'))
  const data = await mkdtemp(join(tmpdir(), 'geo-d-'))
  for (const f of ['Country.mmdb', 'GeoSite.dat', 'ASN.mmdb']) await writeFile(join(bundled, f), f)
  await writeFile(join(bundled, 'VERSION'), 'abc')
  await installGeoData(bundled, data)
  expect(await readFile(join(data, 'GeoSite.dat'), 'utf8')).toBe('GeoSite.dat')
  await writeFile(join(data, 'GeoSite.dat'), 'user-touched')
  await installGeoData(bundled, data)
  expect(await readFile(join(data, 'GeoSite.dat'), 'utf8')).toBe('user-touched')
})
