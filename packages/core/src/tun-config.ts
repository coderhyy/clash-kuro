import { stringify } from 'yaml'
import type { Mode } from './index'
import { applyOverride, parseOverride, parseProfile } from './config'

export const TUN_SESSION_LIMITS = { bytes: 65_536, proxies: 128, groups: 128, rules: 256, name: 128, credential: 1024, domain: 253, resolvers: 16, policies: 128 } as const
export type TunProxy = {
  name: string; server: string; port: number; udp?: boolean
} & (
  | { type: 'ss'; cipher: 'aes-128-gcm' | 'aes-192-gcm' | 'aes-256-gcm' | 'chacha20-ietf-poly1305'; password: string }
  | { type: 'socks5' | 'http'; username?: string; password?: string; tls?: false }
  | { type: 'trojan'; password: string; sni?: string; 'skip-cert-verify'?: false }
)
export interface TunRule {
  type: 'DOMAIN' | 'DOMAIN-SUFFIX' | 'DOMAIN-KEYWORD' | 'IP-CIDR' | 'IP-CIDR6' | 'MATCH'
  value: string
  target: string
  noResolve: boolean
}
/** JSON data only. The privileged helper must independently enforce this same closed schema. */
export interface TunSessionConfig {
  version: 1
  template: 'macos-dual-stack-v1'
  mode: Mode
  proxies: TunProxy[]
  groups: { name: string; type: 'select'; proxies: string[] }[]
  rules: TunRule[]
  dns: {
    nameservers: string[]
    bootstrap: string[]
    proxyNameservers: string[]
    policies: { domain: string; nameservers: string[] }[]
  }
}

type Mapping = Record<string, unknown>
function fail(path: string, reason: string): never { throw new Error(`TUN ${path}: ${reason}`) }
function mapping(value: unknown, path: string, keys: string[]): Mapping {
  if (!value || typeof value !== 'object' || Array.isArray(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) fail(path, 'must be a plain mapping')
  for (const key of Object.keys(value)) if (!keys.includes(key)) fail(`${path}.${key}`, 'unsupported field; it cannot be silently discarded')
  return value as Mapping
}
function text(value: unknown, path: string, max: number): string {
  if (typeof value !== 'string' || !value.length || value.length > max || /[\x00-\x1f\x7f]/.test(value)) fail(path, `must be non-empty text of at most ${max} UTF-16 units without control characters`)
  return value
}
function list(value: unknown, path: string, max: number, nonempty = false): unknown[] {
  if (!Array.isArray(value) || value.length > max || (nonempty && value.length === 0)) fail(path, `must be ${nonempty ? 'a non-empty' : 'an'} array with at most ${max} entries`)
  return value
}
function ip(value: string): number[] | undefined {
  const v4 = value.split('.')
  if (v4.length === 4 && v4.every(part => /^(0|[1-9]\d{0,2})$/.test(part) && Number(part) <= 255)) return v4.map(Number)
  if (!value.includes(':') || /[^0-9a-f:]/i.test(value)) return
  const sides = value.split('::')
  if (sides.length > 2) return
  const groups = sides.map(side => side ? side.split(':') : [])
  const count = groups.flat().length
  if (!groups.flat().every(part => /^[0-9a-f]{1,4}$/i.test(part)) || (sides.length === 1 ? count !== 8 : count >= 8)) return
  return [...groups[0]!.map(part => parseInt(part, 16)), ...Array<number>(8 - count).fill(0), ...(groups[1] ?? []).map(part => parseInt(part, 16))]
}
function domain(value: unknown, path: string): string {
  const name = text(value, path, TUN_SESSION_LIMITS.domain)
  if (!name.split('.').every(part => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(part))) fail(path, 'requires an ASCII DNS name; encode international names as punycode')
  return name
}
function proxyName(value: unknown, path: string): string {
  const name = text(value, path, TUN_SESSION_LIMITS.name)
  if (name.trim() !== name || /,/.test(name) || /^(DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE|GLOBAL|__proto__|constructor|prototype)$/i.test(name)) fail(path, 'reserved or ambiguous Proxy name')
  return name
}
function resolvers(value: unknown, path: string): void {
  for (const [index, item] of list(value, path, TUN_SESSION_LIMITS.resolvers, true).entries()) {
    const address = text(item, `${path}[${index}]`, 45)
    const parts = ip(address)
    if (!parts || parts.every(part => part === 0) || (parts.length === 4 ? parts[0]! >= 224 || parts[0] === 0 : (parts[0]! & 0xff00) === 0xff00)) fail(path, 'only explicit unicast IPv4/IPv6 literals using UDP port 53 are supported; DoH/DoT, URLs, system tokens, ports and implicit providers are unsupported')
    if ((parts.length === 4 && parts[0] === 198 && parts[1] === 18 && parts[2] === 0 && parts[3]! < 4)
      || (parts.length === 8 && parts[0] === 0xfdfe && parts[1] === 0xdcba && parts[2] === 0x9876 && parts.slice(3, 7).every(part => part === 0) && parts[7]! < 4)) fail(path, 'upstream overlaps the fixed internal TUN DNS addresses')
  }
}
function optionalBoolean(value: Mapping, key: string, path: string): void {
  if (Object.hasOwn(value, key) && typeof value[key] !== 'boolean') fail(`${path}.${key}`, 'must be boolean')
}
function validateProxy(value: unknown, path: string): void {
  const base = ['type', 'name', 'server', 'port', 'udp']
  const entry = mapping(value, path, [...base, 'cipher', 'password', 'username', 'tls', 'sni', 'skip-cert-verify'])
  if (typeof entry.type !== 'string' || !['ss', 'socks5', 'http', 'trojan'].includes(entry.type)) fail(`${path}.type`, 'only inline ss/socks5/http/trojan are supported; no provider or extra transport')
  const keys = entry.type === 'ss' ? ['cipher', 'password'] : entry.type === 'trojan' ? ['password', 'sni', 'skip-cert-verify'] : ['username', 'password', 'tls']
  mapping(entry, path, [...base, ...keys])
  proxyName(entry.name, `${path}.name`)
  const host = text(entry.server, `${path}.server`, TUN_SESSION_LIMITS.domain)
  if (!ip(host)) domain(host, `${path}.server`)
  if (!Number.isInteger(entry.port) || Number(entry.port) < 1 || Number(entry.port) > 65_535) fail(`${path}.port`, 'must be an integer from 1 to 65535')
  optionalBoolean(entry, 'udp', path)
  for (const key of ['username', 'password']) if (Object.hasOwn(entry, key)) text(entry[key], `${path}.${key}`, TUN_SESSION_LIMITS.credential)
  if (entry.type === 'ss') {
    if (!['aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305'].includes(String(entry.cipher))) fail(`${path}.cipher`, 'unsupported Shadowsocks cipher')
    text(entry.password, `${path}.password`, TUN_SESSION_LIMITS.credential)
  } else if (entry.type === 'trojan') {
    text(entry.password, `${path}.password`, TUN_SESSION_LIMITS.credential)
    if (Object.hasOwn(entry, 'sni')) domain(entry.sni, `${path}.sni`)
    if (Object.hasOwn(entry, 'skip-cert-verify') && entry['skip-cert-verify'] !== false) fail(path, 'TLS certificate verification cannot be disabled')
  } else {
    if (Object.hasOwn(entry, 'username') !== Object.hasOwn(entry, 'password')) fail(path, 'username and password must be supplied together')
    if (Object.hasOwn(entry, 'tls') && entry.tls !== false) fail(path, 'extra HTTP/SOCKS TLS transport is unsupported')
  }
}
function rule(value: unknown, path: string, targets: Set<string>): void {
  const entry = mapping(value, path, ['type', 'value', 'target', 'noResolve'])
  if (typeof entry.type !== 'string' || !['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'IP-CIDR', 'IP-CIDR6', 'MATCH'].includes(entry.type)) fail(path, 'unsupported rule; providers, Geo data, process rules and scripts are not permitted')
  if (typeof entry.target !== 'string' || !targets.has(entry.target)) fail(`${path}.target`, 'must reference DIRECT, REJECT or a declared Proxy/Group')
  if (typeof entry.noResolve !== 'boolean') fail(`${path}.noResolve`, 'must be boolean')
  if (entry.type === 'MATCH') {
    if (entry.value !== '' || entry.noResolve) fail(path, 'MATCH has an empty value and noResolve=false')
  } else if (entry.type === 'IP-CIDR' || entry.type === 'IP-CIDR6') {
    const value = text(entry.value, `${path}.value`, 49)
    const [address, prefix, extra] = value.split('/')
    const parts = ip(address!)
    const bits = entry.type === 'IP-CIDR' ? 32 : 128
    if (!parts || parts.length !== (bits === 32 ? 4 : 8) || extra !== undefined || !/^(0|[1-9]\d{0,2})$/.test(prefix ?? '') || Number(prefix) > bits) fail(path, 'invalid literal CIDR for this address family')
  } else {
    if (entry.noResolve) fail(path, 'no-resolve is only supported for IP-CIDR rules')
    if (entry.type === 'DOMAIN-KEYWORD') {
      if (!/^[a-z0-9.-]+$/i.test(text(entry.value, `${path}.value`, TUN_SESSION_LIMITS.domain))) fail(path, 'unsupported domain keyword')
    } else domain(entry.value, `${path}.value`)
  }
}
function jsonBytes(value: unknown): number {
  let bytes = 0
  for (const character of JSON.stringify(value)) {
    const code = character.codePointAt(0)!
    bytes += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4
  }
  return bytes
}

/** Validates data received across a trust boundary, including references and the aggregate UTF-8 limit. */
export function validateTunSessionConfig(value: unknown): TunSessionConfig {
  const session = mapping(value, 'session', ['version', 'template', 'mode', 'proxies', 'groups', 'rules', 'dns'])
  if (session.version !== 1 || session.template !== 'macos-dual-stack-v1') fail('session', 'unsupported version or fixed template')
  if (typeof session.mode !== 'string' || !['rule', 'global', 'direct'].includes(session.mode)) fail('mode', 'unsupported routing mode')
  const proxies = list(session.proxies, 'proxies', TUN_SESSION_LIMITS.proxies)
  const groups = list(session.groups, 'groups', TUN_SESSION_LIMITS.groups)
  const names = new Set<string>(['DIRECT', 'REJECT'])
  for (const [index, proxy] of proxies.entries()) {
    validateProxy(proxy, `proxies[${index}]`)
    const name = (proxy as TunProxy).name
    if (names.has(name)) fail('proxies', 'duplicate Proxy name')
    names.add(name)
  }
  const proxyTargets = new Set(names)
  for (const [index, value] of groups.entries()) {
    const path = `groups[${index}]`
    const group = mapping(value, path, ['name', 'type', 'proxies'])
    const name = proxyName(group.name, `${path}.name`)
    if (names.has(name)) fail(path, 'duplicate Proxy/Group name')
    names.add(name)
    if (group.type !== 'select') fail(path, 'only select groups are supported; health-check URLs and providers are not permitted')
    for (const target of list(group.proxies, `${path}.proxies`, TUN_SESSION_LIMITS.proxies + 2, true)) {
      if (typeof target !== 'string' || !proxyTargets.has(target)) fail(path, 'group members must reference declared Proxies, DIRECT or REJECT; nested groups are unsupported')
    }
  }
  const rules = list(session.rules, 'rules', TUN_SESSION_LIMITS.rules, true)
  rules.forEach((value, index) => rule(value, `rules[${index}]`, names))
  if (rules.some((value, index) => (value as TunRule).type === 'MATCH' && index !== rules.length - 1) || (rules.at(-1) as TunRule).type !== 'MATCH') fail('rules', 'require one explicit final MATCH; implicit DIRECT fallback is not accepted')
  const dns = mapping(session.dns, 'dns', ['nameservers', 'bootstrap', 'proxyNameservers', 'policies'])
  for (const key of ['nameservers', 'bootstrap', 'proxyNameservers']) resolvers(dns[key], `dns.${key}`)
  const policies = new Set<string>()
  for (const [index, value] of list(dns.policies, 'dns.policies', TUN_SESSION_LIMITS.policies).entries()) {
    const entry = mapping(value, `dns.policies[${index}]`, ['domain', 'nameservers'])
    const pattern = text(entry.domain, 'dns.policy.domain', TUN_SESSION_LIMITS.domain)
    domain(pattern.startsWith('+.') ? pattern.slice(2) : pattern, 'dns.policy.domain')
    if (policies.has(pattern.toLowerCase())) fail('dns.policies', 'duplicate DNS policy domain')
    policies.add(pattern.toLowerCase())
    resolvers(entry.nameservers, `dns.policies[${index}].nameservers`)
  }
  if (jsonBytes(session) > TUN_SESSION_LIMITS.bytes) fail('session', 'JSON exceeds 65536 UTF-8 bytes')
  return JSON.parse(JSON.stringify(session)) as TunSessionConfig
}

/** Preserves supported inline data; rejects every unhandled field instead of weakening Profile DNS/transport. */
export function createTunSessionConfig(profileYaml: string, mode: Mode, overrideYaml = ''): TunSessionConfig {
  if (profileYaml.length > 262_144 || overrideYaml.length > 262_144) fail('Profile', 'input YAML exceeds 262144 UTF-16 units')
  const parsed = parseProfile(profileYaml)
  if (!parsed.ok) throw new Error(parsed.error)
  const override = parseOverride(overrideYaml)
  if (!override.ok) throw new Error(override.error)
  const config = mapping(applyOverride(parsed.value, override.value), 'Profile', ['mode', 'ipv6', 'proxies', 'proxy-groups', 'rules', 'dns'])
  if (Object.hasOwn(config, 'ipv6') && config.ipv6 !== true) fail('Profile.ipv6', 'dual-stack TUN cannot disable IPv6')
  if (Object.hasOwn(config, 'mode') && !['rule', 'global', 'direct'].includes(String(config.mode))) fail('Profile.mode', 'unsupported routing mode')
  const dns = mapping(config.dns, 'Profile.dns', ['enable', 'ipv6', 'enhanced-mode', 'nameserver', 'default-nameserver', 'proxy-server-nameserver', 'nameserver-policy'])
  if (dns.enable !== true || dns.ipv6 !== true || dns['enhanced-mode'] !== 'redir-host') fail('Profile.dns', 'requires explicit enable:true, ipv6:true and enhanced-mode:redir-host; DNS is not silently enabled or changed')
  const rawPolicies = dns['nameserver-policy'] === undefined ? {} : dns['nameserver-policy']
  if (!rawPolicies || typeof rawPolicies !== 'object' || Array.isArray(rawPolicies)) fail('Profile.dns.nameserver-policy', 'must be a domain-to-resolvers mapping')
  const policies = mapping(rawPolicies, 'Profile.dns.nameserver-policy', Object.keys(rawPolicies))
  const groups = list(config['proxy-groups'] ?? [], 'Profile.proxy-groups', TUN_SESSION_LIMITS.groups).map((value, index) => {
    const group = mapping(value, `Profile.proxy-groups[${index}]`, ['name', 'type', 'proxies'])
    return group
  })
  const rules = list(config.rules, 'Profile.rules', TUN_SESSION_LIMITS.rules, true).map((value, index) => {
    const parts = text(value, `Profile.rules[${index}]`, 512).split(',')
    const [type, payload, target, option, extra] = parts
    if (type === 'MATCH') {
      if (parts.length !== 2) fail('Profile.rules', 'MATCH requires exactly one target')
      return { type, value: '', target: payload, noResolve: false }
    }
    if ((parts.length !== 3 && parts.length !== 4) || extra !== undefined || (option !== undefined && option !== 'no-resolve')) fail('Profile.rules', 'unsupported rule arguments')
    return { type, value: payload, target, noResolve: option === 'no-resolve' }
  })
  return validateTunSessionConfig({
    version: 1, template: 'macos-dual-stack-v1', mode,
    proxies: config.proxies ?? [], groups, rules,
    dns: { nameservers: dns.nameserver, bootstrap: dns['default-nameserver'], proxyNameservers: dns['proxy-server-nameserver'], policies: Object.entries(policies).map(([domain, nameservers]) => ({ domain, nameservers })) },
  })
}

/** Offline candidate only. Helper preflight, ownership journaling and root schema validation remain mandatory. */
export function buildTunRuntimeCandidate(value: unknown): string {
  const session = validateTunSessionConfig(value)
  return stringify({
    mode: session.mode, ipv6: true, 'allow-lan': false, 'bind-address': '127.0.0.1', 'log-level': 'info',
    'mixed-port': 0, port: 0, 'socks-port': 0, 'redir-port': 0, 'tproxy-port': 0,
    'find-process-mode': 'off', 'geo-auto-update': false, profile: { 'store-selected': false, 'store-fake-ip': false },
    proxies: session.proxies, 'proxy-groups': session.groups,
    rules: session.rules.map(rule => [rule.type, ...(rule.type === 'MATCH' ? [] : [rule.value]), rule.target, ...(rule.noResolve ? ['no-resolve'] : [])].join(',')),
    dns: {
      enable: true, ipv6: true, 'enhanced-mode': 'redir-host', listen: '', 'use-hosts': true, 'use-system-hosts': true,
      nameserver: session.dns.nameservers, 'default-nameserver': session.dns.bootstrap, 'proxy-server-nameserver': session.dns.proxyNameservers,
      'nameserver-policy': Object.fromEntries(session.dns.policies.map(policy => [policy.domain, policy.nameservers])),
      'proxy-server-nameserver-policy': {}, 'direct-nameserver': [], 'direct-nameserver-follow-policy': false,
      fallback: [], 'fallback-filter': { geoip: false }, 'respect-rules': false,
      'fake-ip-range': '198.18.0.1/16', 'fake-ip-range6': '',
    },
    // Core owns the fixed route plan; helper preflights LAN/scoped DNS and owns DNS restoration.
    tun: { enable: true, stack: 'mips', mtu: 1500, 'auto-route': true, 'route-address': ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1'], 'auto-detect-interface': true, 'strict-route': false, 'dns-mode': 'disabled', 'dns-hijack': [], 'inet6-address': ['fdfe:dcba:9876::1/126'] },
  })
}
