import { expect, test } from 'vitest'
import { parse, stringify } from 'yaml'
import { buildTunRuntimeCandidate, createTunSessionConfig, TUN_SESSION_LIMITS, validateTunSessionConfig, type TunSessionConfig } from './index'

function profile() {
  return {
    mode: 'rule', ipv6: true,
    proxies: [
      { name: 'SS 节点', type: 'ss', server: 'proxy.example', port: 443, cipher: 'aes-128-gcm', password: 'secret', udp: true },
      { name: 'Trojan', type: 'trojan', server: '192.0.2.1', port: 443, password: 'secret', sni: 'proxy.example', 'skip-cert-verify': false },
      { name: 'HTTP', type: 'http', server: 'proxy.example', port: 8080, username: 'user', password: 'pass' },
      { name: 'SOCKS', type: 'socks5', server: '2001:db8::1', port: 1080 },
    ],
    'proxy-groups': [{ name: '手动选择', type: 'select', proxies: ['SS 节点', 'Trojan', 'DIRECT', 'REJECT'] }],
    rules: ['DOMAIN,printer.home.arpa,DIRECT', 'DOMAIN-SUFFIX,example.com,手动选择', 'DOMAIN-KEYWORD,blocked,REJECT', 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve', 'IP-CIDR6,fd00::/8,DIRECT,no-resolve', 'MATCH,手动选择'],
    dns: { enable: true, ipv6: true, 'enhanced-mode': 'redir-host', nameserver: ['192.0.2.53'], 'default-nameserver': ['2001:db8::53'], 'proxy-server-nameserver': ['192.0.2.54'], 'nameserver-policy': { '+.home.arpa': ['192.168.1.1'] } },
  }
}
function session(): TunSessionConfig { return createTunSessionConfig(stringify(profile()), 'rule') }

test('admits explicit inline data, preserves DIRECT and local DNS policy, and does not mutate Profile or Override', () => {
  const original = profile()
  const yaml = stringify(original)
  const override = '"rules+": []\ndns:\n  nameserver: [192.0.2.55]\n'
  const result = createTunSessionConfig(yaml, 'direct', override)
  expect(result.mode).toBe('direct')
  expect(result.proxies).toEqual(original.proxies)
  expect(result.groups).toEqual(original['proxy-groups'])
  expect(result.rules[0]).toEqual({ type: 'DOMAIN', value: 'printer.home.arpa', target: 'DIRECT', noResolve: false })
  expect(result.dns).toEqual({ nameservers: ['192.0.2.55'], bootstrap: ['2001:db8::53'], proxyNameservers: ['192.0.2.54'], policies: [{ domain: '+.home.arpa', nameservers: ['192.168.1.1'] }] })
  expect(yaml).toBe(stringify(original))
  expect(override).toBe('"rules+": []\ndns:\n  nameserver: [192.0.2.55]\n')
  const copied = validateTunSessionConfig(result)
  copied.proxies[0]!.name = 'changed copy'
  expect(result.proxies[0]!.name).toBe('SS 节点')
})

test('fixed dual-stack candidate does not delegate routes or system DNS to Core, add providers or open listeners', () => {
  const source = session()
  const output = parse(buildTunRuntimeCandidate(source))
  expect(output.tun).toEqual({ enable: true, stack: 'mips', mtu: 1500, 'auto-route': true, 'route-address': ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1'], 'auto-detect-interface': true, 'strict-route': false, 'dns-mode': 'disabled', 'dns-hijack': [], 'inet6-address': ['fdfe:dcba:9876::1/126'] })
  expect(output.ipv6).toBe(true)
  expect(output.dns).toMatchObject({ enable: true, ipv6: true, 'enhanced-mode': 'redir-host', listen: '', fallback: [], 'default-nameserver': source.dns.bootstrap, nameserver: source.dns.nameservers, 'proxy-server-nameserver': source.dns.proxyNameservers, 'fake-ip-range': '198.18.0.1/16', 'respect-rules': false })
  expect(output['geo-auto-update']).toBe(false)
  expect(output['mixed-port']).toBe(0)
  for (const key of ['external-controller', 'external-controller-unix', 'external-controller-pipe', 'secret', 'proxy-providers', 'rule-providers', 'tun.inet4-address', 'geox-url', 'ntp']) expect(output).not.toHaveProperty(key)
  expect(output.rules).toEqual(profile().rules)
  expect(output.proxies).toEqual(source.proxies)
})

test.each(['proxy-providers', 'rule-providers', 'listeners', 'tun', 'script', 'ntp', 'hosts', 'external-controller', 'geox-url', 'sniffer'])('rejects unhandled Profile %s and never silently discards it', key => {
  expect(() => createTunSessionConfig(stringify({ ...profile(), [key]: {} }), 'rule')).toThrow(`Profile.${key}`)
})

test.each(['fallback', 'fallback-filter', 'direct-nameserver', 'proxy-server-nameserver-policy', 'listen', 'respect-rules', 'use-system-hosts', 'fake-ip-range'])('rejects unsupported DNS %s instead of changing DNS semantics', key => {
  const data = profile()
  Object.assign(data.dns, { [key]: key === 'fallback' ? [] : true })
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow(`Profile.dns.${key}`)
})

test.each(['nameserver', 'default-nameserver', 'proxy-server-nameserver'])('requires explicit %s; no implicit bootstrap, proxy DNS or public supplier', key => {
  const data = profile()
  Reflect.deleteProperty(data.dns, key)
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow(/must be a non-empty array/)
})

test.each(['enable', 'ipv6', 'enhanced-mode'])('requires explicit compatible DNS %s instead of silently enabling/changing it', key => {
  const data = profile()
  Reflect.deleteProperty(data.dns, key)
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow(/DNS is not silently enabled or changed/)
})

test.each(['https://resolver.example/dns-query', 'tls://192.0.2.53', 'system', '192.0.2.53:53', 'udp://192.0.2.53', '192.0.2.53#Proxy', 'fe80::1%en0', '::ffff:192.0.2.53', '::', '0.0.0.0', '224.0.0.53', 'ff02::fb', '198.18.0.2', 'fdfe:dcba:9876::2'])('rejects unsupported or unsafe resolver %s with a DNS-specific reason', address => {
  const source = session()
  source.dns.nameservers = [address]
  expect(() => validateTunSessionConfig(source)).toThrow(/TUN dns.nameservers/)
})

test.each(['plugin', 'plugin-opts', 'dialer-proxy', 'interface-name', 'certificate', 'private-key', 'ws-opts', 'smux'])('rejects Proxy %s outside the closed inline transport schema', key => {
  const source = session()
  Object.assign(source.proxies[0]!, { [key]: key === 'plugin' ? 'obfs' : {} })
  expect(() => validateTunSessionConfig(source)).toThrow('unsupported field')
})

test.each(['vmess', 'vless', 'wireguard', 'hysteria2', 'direct'])('rejects unimplemented Proxy type %s explicitly', type => {
  const source = session()
  Object.assign(source.proxies[0]!, { type })
  expect(() => validateTunSessionConfig(source)).toThrow('only inline ss/socks5/http/trojan')
})

test('refuses insecure TLS, file/URL server addresses, missing credentials and unsupported cipher', () => {
  for (const change of [
    { 'skip-cert-verify': true }, { server: 'file:///etc/passwd' }, { server: 'proxy.example/path' }, { password: '' }, { password: 'secret\nlog' },
  ]) {
    const source = session()
    Object.assign(source.proxies[1]!, change)
    expect(() => validateTunSessionConfig(source)).toThrow(/TUN proxies/)
  }
  const source = session()
  Object.assign(source.proxies[0]!, { cipher: 'none' })
  expect(() => validateTunSessionConfig(source)).toThrow('unsupported Shadowsocks cipher')
})

test.each(['DIRECT', 'direct', 'REJECT', 'REJECT-DROP', 'GLOBAL', 'COMPATIBLE', 'PASS', '__proto__', 'constructor', 'prototype', 'a,b', ' leading'])('rejects reserved/ambiguous Proxy name %s', name => {
  const source = session()
  source.proxies[0]!.name = name
  expect(() => validateTunSessionConfig(source)).toThrow('reserved or ambiguous')
})

test('rejects duplicate names, undefined targets, nested groups, provider groups and hidden health-check URLs', () => {
  const sources = Array.from({ length: 6 }, session)
  sources[0]!.proxies[1]!.name = sources[0]!.proxies[0]!.name
  sources[1]!.groups[0]!.name = sources[1]!.proxies[0]!.name
  sources[2]!.rules[0]!.target = 'missing'
  sources[3]!.groups[0]!.proxies = [sources[3]!.groups[0]!.name]
  Object.assign(sources[4]!.groups[0]!, { type: 'url-test' })
  Object.assign(sources[5]!.groups[0]!, { url: 'https://example/healthcheck' })
  for (const source of sources) expect(() => validateTunSessionConfig(source)).toThrow(/TUN/)
})

test.each(['GEOSITE,cn,DIRECT', 'GEOIP,CN,DIRECT', 'RULE-SET,remote,DIRECT', 'PROCESS-NAME,app,DIRECT', 'MATCH,DIRECT,extra', 'IP-CIDR,::/0,DIRECT', 'DOMAIN,example.com,DIRECT,no-resolve', 'DOMAIN,example.com,DIRECT,script'])('rejects unsafe or unsupported rule %s', entry => {
  const data = profile()
  data.rules.unshift(entry)
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow(/TUN/)
})

test('requires an explicit final MATCH and preserves no-resolve only for literal CIDR rules', () => {
  const data = profile()
  data.rules.pop()
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow('explicit final MATCH')
  data.rules.unshift('MATCH,DIRECT')
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow('explicit final MATCH')
  expect(session().rules[3]).toMatchObject({ type: 'IP-CIDR', noResolve: true })
})

test('DNS policies reject Geo/providers, URLs, duplicate domains and null mappings instead of dropping split DNS', () => {
  for (const domain of ['geosite:cn', 'rule-set:private', '*', '*.example.com', 'https://resolver.example']) {
    const source = session()
    source.dns.policies = [{ domain, nameservers: ['192.168.1.1'] }]
    expect(() => validateTunSessionConfig(source)).toThrow('dns.policy.domain')
  }
  const source = session()
  source.dns.policies.push({ domain: '+.HOME.ARPA', nameservers: ['192.168.1.2'] })
  expect(() => validateTunSessionConfig(source)).toThrow('duplicate DNS policy')
  const data = profile()
  Object.assign(data.dns, { 'nameserver-policy': null })
  expect(() => createTunSessionConfig(stringify(data), 'rule')).toThrow('domain-to-resolvers mapping')
})

test('closed session schema rejects missing fields and root capabilities at every structured level', () => {
  for (const key of ['version', 'template', 'mode', 'proxies', 'groups', 'rules', 'dns']) {
    const source = session()
    Reflect.deleteProperty(source, key)
    expect(() => validateTunSessionConfig(source)).toThrow(/TUN/)
  }
  for (const key of ['path', 'yaml', 'command', 'url', 'external-controller-unix', 'tun']) {
    const source = session()
    Object.assign(source, { [key]: '/tmp/untrusted' })
    expect(() => buildTunRuntimeCandidate(source)).toThrow('unsupported field')
  }
})

test('bounds collections, names, domains, credentials and exact aggregate UTF-8 bytes', () => {
  for (const key of ['proxies', 'groups', 'rules'] as const) {
    const source = session()
    Object.assign(source, { [key]: Array(TUN_SESSION_LIMITS[key] + 1).fill(source[key][0]) })
    expect(() => validateTunSessionConfig(source)).toThrow('at most')
  }
  for (const change of [{ name: 'a'.repeat(129) }, { server: 'a'.repeat(254) }, { password: 'a'.repeat(1025) }, { port: 0 }, { port: 65536 }, { port: 1.5 }]) {
    const source = session()
    Object.assign(source.proxies[0]!, change)
    expect(() => validateTunSessionConfig(source)).toThrow(/TUN/)
  }
  const source = session()
  source.proxies = Array.from({ length: 50 }, (_, index) => ({ ...source.proxies[0]!, name: `node${index}`, password: '密'.repeat(512) }))
  source.groups = []
  source.rules = [{ type: 'MATCH', value: '', target: 'DIRECT', noResolve: false }]
  expect(JSON.stringify(source).length).toBeLessThan(TUN_SESSION_LIMITS.bytes)
  expect(() => validateTunSessionConfig(source)).toThrow('65536 UTF-8 bytes')
})

test('Override cannot smuggle unsupported root capabilities or remove mandatory DNS', () => {
  const yaml = stringify(profile())
  expect(() => createTunSessionConfig(yaml, 'rule', '"tun!": {enable: true, file-descriptor: 9}')).toThrow('Profile.tun')
  expect(() => createTunSessionConfig(yaml, 'rule', 'dns:\n  default-nameserver: null')).toThrow('dns.bootstrap')
  expect(() => createTunSessionConfig(yaml, 'rule', '"proxies+": [{name: injected, type: ss, server: a, port: 1, cipher: none, password: x, plugin: exec}]')).toThrow('unsupported field')
})
