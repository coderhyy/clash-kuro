import { expect, test } from 'vitest'
import { createMihomoClient } from './index'
import { FakeTransport } from './fake'

test('maps kebab-case config and PATCHes mode, accepting empty 204 responses', async () => {
  const transport = new FakeTransport()
    .on('GET', '/configs', { status: 200, body: { mode: 'global', 'mixed-port': 7890, 'allow-lan': false, 'log-level': 'info' } })
    .on('PATCH', '/configs', { status: 204, body: null })
  const client = createMihomoClient(transport)
  expect(await client.getConfig()).toEqual({ mode: 'global', mixedPort: 7890, allowLan: false, logLevel: 'info' })
  await client.setMode('direct')
  expect(transport.requests.at(-1)).toEqual({ method: 'PATCH', path: '/configs', body: { mode: 'direct' } })
})

test('detects groups, preserves all proxies, and uses only the latest delay', async () => {
  const transport = new FakeTransport().on('GET', '/proxies', { status: 200, body: { proxies: {
    group: { type: 'Selector', all: ['HK', 'JP'], now: 'HK', history: [] },
    HK: { type: 'Trojan', history: [{ delay: 900 }, { delay: 81 }] },
    JP: { type: 'Vmess', history: [{ delay: 90 }, { delay: 0 }] },
    DIRECT: { type: 'Direct' },
    constructor: { type: 'Direct', history: [] }
  } } })
  const { groups, proxies } = await createMihomoClient(transport).getProxyGroups()
  expect(groups).toEqual([{ name: 'group', type: 'Selector', all: ['HK', 'JP'], now: 'HK' }])
  expect(proxies.HK?.delay).toBe(81)
  expect(proxies.JP?.delay).toBeNull()
  expect(proxies.DIRECT?.delay).toBeNull()
  expect(proxies.group?.delay).toBeNull()
  expect(proxies.constructor).toEqual({ name: 'constructor', type: 'Direct', delay: null })
})

test('encodes Chinese, spaces, slashes and reserved characters in path segments', async () => {
  const group = '节点 / ?#%'
  const path = `/proxies/${encodeURIComponent(group)}`
  const transport = new FakeTransport()
    .on('PUT', path, { status: 204, body: null })
    .on('DELETE', '/connections', { status: 204, body: null })
  const client = createMihomoClient(transport)
  await client.selectProxy(group, '香港 01')
  await client.closeAllConnections()
  expect(transport.requests).toEqual([
    { method: 'PUT', path, body: { name: '香港 01' } },
    { method: 'DELETE', path: '/connections' }
  ])
})

test.each([300, 400, 401, 500])('rejects HTTP %s with the mihomo message', async (status) => {
  const transport = new FakeTransport().on('PATCH', '/configs', { status, body: { message: 'mode rejected' } })
  await expect(createMihomoClient(transport).setMode('rule')).rejects.toThrow('mode rejected')
})

test('reports status when an error response has no message; propagates transport failures', async () => {
  const transport = new FakeTransport().on('GET', '/configs', { status: 503, body: null })
  const client = createMihomoClient(transport)
  await expect(client.getConfig()).rejects.toThrow('mihomo HTTP 503')
  transport.on('GET', '/configs', () => { throw new Error('socket closed') })
  await expect(client.getConfig()).rejects.toThrow('socket closed')
})

test('maps all streams and returns handles that unsubscribe', () => {
  const transport = new FakeTransport()
  const client = createMihomoClient(transport)
  const traffic: unknown[] = [], logs: unknown[] = [], connections: unknown[] = []
  const handles = [client.traffic((t) => traffic.push(t)), client.logs((l) => logs.push(l)), client.connections((c) => connections.push(c))]
  transport.push('/traffic', { up: 100, down: 200 })
  transport.push('/logs', { type: 'warning', payload: 'test' })
  transport.push('/connections', { uploadTotal: 1000, downloadTotal: 2000, connections: [{ id: '1' }, { id: '2' }] })
  transport.push('/connections', { uploadTotal: 1000, downloadTotal: 2000, connections: [] })
  expect(traffic).toEqual([{ up: 100, down: 200 }])
  expect(logs).toEqual([{ level: 'warning', payload: 'test' }])
  expect(connections).toEqual([{ uploadTotal: 1000, downloadTotal: 2000, count: 2 }, { uploadTotal: 1000, downloadTotal: 2000, count: 0 }])
  handles.forEach((h) => h.close())
  for (const path of ['/traffic', '/logs', '/connections']) expect(transport.openStreams(path)).toBe(0)
  transport.push('/traffic', { up: 1, down: 2 })
  expect(traffic).toHaveLength(1)
})

test('rejects malformed data rather than publishing invalid domain values', async () => {
  const transport = new FakeTransport().on('GET', '/configs', { status: 200, body: { mode: 'bad' } })
  const client = createMihomoClient(transport)
  await expect(client.getConfig()).rejects.toThrow('Invalid mihomo mode')
  client.traffic(() => {})
  expect(() => transport.push('/traffic', { up: 'bad', down: 1 })).toThrow('Invalid mihomo response')
  transport.on('GET', '/proxies', { status: 200, body: { proxies: { group: { type: 'Selector', all: null, now: 'DIRECT' } } } })
  await expect(client.getProxyGroups()).rejects.toThrow('Invalid mihomo group members')
})
