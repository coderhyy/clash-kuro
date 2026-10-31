import { describe, expect, test } from 'vitest'
import { parse } from 'yaml'
import { applyOverride, buildRuntimeConfig, parseOverride, parseProfile } from './index'
import type { ControlChannel, Settings } from './index'

const settings: Settings = { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' }
const unix: ControlChannel = { kind: 'unix', path: '/app/core.sock' }

describe('parseOverride', () => {
  test.each(['', '  \n', '# no Override', '{}'])('accepts an empty Override: %j', yaml => {
    expect(parseOverride(yaml)).toEqual({ ok: true, value: {} })
  })

  test('parses mappings, anchors and merge keys', () => {
    expect(parseOverride('dns: &dns {enable: true}\ncopy: {<<: *dns}')).toEqual({
      ok: true, value: { dns: { enable: true }, copy: { enable: true } }
    })
  })

  test.each(['null', '42', 'hello', '- rule', '[', 'a: 1\na: 2', 'a: *missing', 'a: 1\n---\nb: 2'])('rejects invalid Override YAML: %j', yaml => {
    const result = parseOverride(yaml)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toMatch(/Override.*(mapping|YAML)/)
  })

  test('limits alias expansion', () => {
    expect(parseOverride('a: &a [1, 2]\nb: &b [*a, *a, *a, *a, *a]\nc: &c [*b, *b, *b, *b, *b]\nd: [*c, *c, *c, *c, *c]').ok).toBe(false)
  })
})

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

describe('applyOverride', () => {
  test('recursively merges mappings, replaces arrays and scalars, and deletes null keys', () => {
    expect(applyOverride(
      { dns: { enable: true, nameserver: ['old'], fallback: ['old'], nested: { keep: 1, remove: 2 } }, rules: ['old'], mode: 'rule' },
      { dns: { nameserver: ['new'], fallback: null, nested: { remove: null, add: 3 } }, rules: ['new'], mode: 'direct', absent: null }
    )).toEqual({ dns: { enable: true, nameserver: ['new'], nested: { keep: 1, add: 3 } }, rules: ['new'], mode: 'direct' })
  })

  test('prepends and appends arrays at any mapping depth', () => {
    expect(applyOverride(
      { rules: ['middle'], dns: { nameserver: ['middle'] } },
      { '+rules': ['first'], 'rules+': ['last'], dns: { '+nameserver': ['first'], 'nameserver+': ['last'] } }
    )).toEqual({ rules: ['first', 'middle', 'last'], dns: { nameserver: ['first', 'middle', 'last'] } })
  })

  test('treats absent and non-array targets as empty arrays, including new mappings', () => {
    expect(applyOverride(
      { rules: 'old', dns: false },
      { '+rules': ['first'], 'proxies+': [], dns: { '+nameserver': ['new'], removed: null }, fresh: { 'values+': [1] } }
    )).toEqual({ rules: ['first'], proxies: [], dns: { nameserver: ['new'] }, fresh: { values: [1] } })
  })

  test.each(['+rules', 'rules+'])('rejects a non-array value for %s', key => {
    for (const value of [null, 1, 'rule', {}]) {
      expect(() => applyOverride({}, { dns: { [key]: value } })).toThrow(/array/)
    }
  })

  test('does not modify either input, including shared YAML aliases', () => {
    const base = parse('dns: &dns {nameserver: [old]}\ncopy: *dns\nrules: [old]')
    const override = { dns: { '+nameserver': ['new'] }, '+rules': ['new'] }
    const beforeBase = JSON.stringify(base)
    const beforeOverride = JSON.stringify(override)
    expect(applyOverride(base, override)).toEqual({ dns: { nameserver: ['new', 'old'] }, copy: { nameserver: ['old'] }, rules: ['new', 'old'] })
    expect(JSON.stringify(base)).toBe(beforeBase)
    expect(JSON.stringify(override)).toBe(beforeOverride)
  })

  test('handles prototype-named YAML keys as own data without polluting prototypes', () => {
    const result = applyOverride({}, parse('__proto__: {polluted: true}\nconstructor: {prototype: {polluted: true}}'))
    expect(Object.hasOwn(result, '__proto__')).toBe(true)
    expect(Object.getPrototypeOf(result)).toBe(Object.prototype)
    expect(Object.hasOwn(Object.prototype, 'polluted')).toBe(false)
    expect(result.__proto__).toEqual({ polluted: true })
  })
})

describe('buildRuntimeConfig', () => {
  test.each<ControlChannel>([unix, { kind: 'pipe', name: '\\\\.\\pipe\\kuro-random' }])('applies Override before App-managed Fields and controller sanitization for $kind', channel => {
    const result = parse(buildRuntimeConfig(
      'rules: [old]\ndns: {enable: false, nameserver: [old]}\nprofile: {store-fake-ip: true}',
      settings, channel,
      `mode: direct
mixed-port: 1234
allow-lan: true
log-level: debug
geo-auto-update: true
profile: {store-selected: false}
external-controller: 0.0.0.0:9090
external-controller-tls: 0.0.0.0:9443
external-controller-unix: /untrusted.sock
external-controller-pipe: untrusted
external-controller-cors: {allow-origins: ['*']}
external-controller-future: unsafe
secret: untrusted
rules: ['MATCH,DIRECT']
dns: {enable: true, nameserver: [new]}`
    ))
    expect(result).toEqual({
      mode: 'rule', 'mixed-port': 7890, 'allow-lan': false, 'log-level': 'info', 'geo-auto-update': false,
      profile: { 'store-selected': true, 'store-fake-ip': true },
      rules: ['MATCH,DIRECT'], dns: { enable: true, nameserver: ['new'] },
      [channel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe']: channel.kind === 'unix' ? channel.path : channel.name
    })
  })

  test('empty Override leaves Runtime Config unchanged and invalid Override is rejected', () => {
    const base = 'proxies: []'
    expect(buildRuntimeConfig(base, settings, unix, '# none')).toBe(buildRuntimeConfig(base, settings, unix))
    expect(() => buildRuntimeConfig(base, settings, unix, '[')).toThrow(/Override YAML/)
    expect(() => buildRuntimeConfig(base, settings, unix, '+rules: not-an-array')).toThrow(/array/)
  })

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
geo-auto-update: true
profile: {store-selected: false, store-fake-ip: true}
proxies: []
rules: [MATCH,DIRECT]
`

  test.each<ControlChannel>([unix, { kind: 'pipe', name: '\\\\.\\pipe\\kuro-random' }])('replaces all app-managed fields for $kind', channel => {
    const parsed = parseProfile(yaml)
    const original = JSON.parse(JSON.stringify(parsed))
    const result = parse(buildRuntimeConfig(parsed, settings, channel))
    const key = channel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe'
    expect(result).toEqual({
      mode: 'rule', 'mixed-port': 7890, 'allow-lan': false, 'log-level': 'info', 'geo-auto-update': false,
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
