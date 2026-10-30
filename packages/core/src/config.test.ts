import { describe, expect, test } from 'vitest'
import { parse } from 'yaml'
import { buildRuntimeConfig, parseProfile } from './index'
import type { ControlChannel, Settings } from './index'

const settings: Settings = { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' }
const unix: ControlChannel = { kind: 'unix', path: '/app/core.sock' }

describe('parseProfile', () => {
  test('parses mappings, anchors and merge keys', () => {
    expect(parseProfile('base: &base {type: select}\nproxy-groups: [{<<: *base, name: test}]')).toEqual({
      ok: true,
      value: { base: { type: 'select' }, 'proxy-groups': [{ type: 'select', name: 'test' }] }
    })
  })

  test.each(['', '# comment', '{}', 'null', '42', 'hello', '- proxy', 'profile: null', 'profile: []'])('rejects invalid structure: %j', yaml => {
    const result = parseProfile(yaml)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toMatch(/mapping/)
  })

  test.each(['proxies: [', 'a: 1\na: 2', 'a: *missing', 'a: 1\n---\nb: 2'])('returns readable YAML errors: %j', yaml => {
    const result = parseProfile(yaml)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toMatch(/Invalid profile YAML: .+/)
  })

  test('limits alias expansion', () => {
    const result = parseProfile('a: &a [1, 2]\nb: &b [*a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b]\nd: [*c, *c, *c, *c, *c]')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toMatch(/alias/i)
  })
})

describe('buildRuntimeConfig', () => {
  const yaml = `mode: direct
mixed-port: 1
allow-lan: true
log-level: debug
external-controller: 0.0.0.0:9090
external-controller-tls: 0.0.0.0:9443
external-controller-unix: /untrusted.sock
external-controller-pipe: untrusted
external-controller-cors: {allow-origins: ['*']}
external-controller-future: unsafe
secret: untrusted-secret
profile: {store-selected: false, store-fake-ip: true}
proxies: []
rules: [MATCH,DIRECT]
`

  test.each<ControlChannel>([unix, { kind: 'pipe', name: '\\\\.\\pipe\\tern-random' }])('replaces all app-managed fields for $kind', channel => {
    const parsed = parseProfile(yaml)
    const original = JSON.parse(JSON.stringify(parsed))
    const result = parse(buildRuntimeConfig(parsed, settings, channel))
    const key = channel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe'
    expect(result).toEqual({
      mode: 'rule', 'mixed-port': 7890, 'allow-lan': false, 'log-level': 'info',
      profile: { 'store-selected': true, 'store-fake-ip': true },
      proxies: [], rules: ['MATCH', 'DIRECT'],
      [key]: channel.kind === 'unix' ? channel.path : channel.name
    })
    expect(parsed).toEqual(original)
    expect(buildRuntimeConfig(yaml, settings, channel)).toBe(buildRuntimeConfig(parsed, settings, channel))
  })

  test('overrides controller values inherited from YAML merge keys', () => {
    const result = parse(buildRuntimeConfig('<<: &base {external-controller: "0.0.0.0:9090", secret: unsafe}\nproxies: []', settings, unix))
    expect(result['external-controller']).toBeUndefined()
    expect(result.secret).toBeUndefined()
    expect(result['<<']).toBeUndefined()
    expect(result.profile).toEqual({ 'store-selected': true })
  })

  test('preserves proxy credentials, which are not controller secrets', () => {
    const result = parse(buildRuntimeConfig('proxies: [{name: test, password: password}]', settings, unix))
    expect(result.proxies[0].password).toBe('password')
  })

  test('rejects invalid YAML and failed parse results', () => {
    expect(() => buildRuntimeConfig('[', settings, unix)).toThrow(/YAML/)
    expect(() => buildRuntimeConfig({ ok: false, error: 'Invalid input' }, settings, unix)).toThrow('Invalid input')
  })

  test.each([0, -1, 65536, 1.5, NaN, Infinity])('rejects invalid port %s', mixedPort => {
    expect(() => buildRuntimeConfig('proxies: []', { ...settings, mixedPort }, unix)).toThrow(/mixedPort/)
  })

  test.each<ControlChannel>([{ kind: 'unix', path: ' ' }, { kind: 'pipe', name: '' }, { kind: 'unix', path: 'a\0b' }])('rejects invalid control addresses', channel => {
    expect(() => buildRuntimeConfig('proxies: []', settings, channel)).toThrow(/Control Channel/)
  })
})
