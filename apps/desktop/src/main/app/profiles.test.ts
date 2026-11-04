import { expect, test } from 'vitest'
import { FakePlatform } from '@kuro/core/fake'
import { fakeSnapshot } from '@kuro/state/fake'
import { contentFile, createProfileSource } from './profiles'

const original = `proxies: []
rules: ["MATCH,DIRECT"]
dns:
  enable: true
  ipv6: true
  enhanced-mode: redir-host
  nameserver: [192.0.2.53]
  default-nameserver: [192.0.2.53]
  proxy-server-nameserver: [192.0.2.53]
`

test('TUN preparation reads original Profile and Override without rewriting either', async () => {
  const platform = new FakePlatform()
  const state = fakeSnapshot()
  const profile = state.profiles[0]!
  platform.files.set(contentFile(profile.id), original)
  const source = createProfileSource({ platform, userAgent: 'test', isCoreRunning: async () => false })
  const config = await source.buildTunConfig({ profile, settings: { ...state.settings, mode: 'direct' }, override: 'dns:\n  nameserver: [192.0.2.54]' })
  expect(config.mode).toBe('direct')
  expect(config.dns.nameservers).toEqual(['192.0.2.54'])
  expect(config.dns.bootstrap).toEqual(['192.0.2.53'])
  expect(platform.files.get(contentFile(profile.id))).toBe(original)
})

test('TUN preparation refuses missing source and unsupported DNS instead of using ordinary Runtime Config', async () => {
  const platform = new FakePlatform()
  const state = fakeSnapshot()
  const profile = state.profiles[0]!
  const source = createProfileSource({ platform, userAgent: 'test', isCoreRunning: async () => false })
  const input = { profile, settings: state.settings, override: '' }
  await expect(source.buildTunConfig(input)).rejects.toThrow('Profile content is missing')
  platform.files.set(contentFile(profile.id), original)
  await expect(source.buildTunConfig({ ...input, override: 'dns:\n  nameserver: [https://example.com/dns-query]' })).rejects.toThrow('only explicit unicast')
  expect(platform.files.get(contentFile(profile.id))).toBe(original)
})
