import type { CoreConfig, HttpRequest, MihomoClient, Proxy, ProxyGroup, Transport } from './index'

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('Invalid mihomo response: expected object')
  return value as Record<string, unknown>
}

function text(value: unknown): string {
  if (typeof value !== 'string') throw new Error('Invalid mihomo response: expected string')
  return value
}

function number(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) throw new Error('Invalid mihomo response: expected non-negative number')
  return value
}

function logLevel(value: unknown): CoreConfig['logLevel'] {
  if (value !== 'silent' && value !== 'error' && value !== 'warning' && value !== 'info' && value !== 'debug') throw new Error('Invalid mihomo log level')
  return value
}

export function createMihomoClient(transport: Transport): MihomoClient {
  async function request(req: HttpRequest): Promise<unknown> {
    const response = await transport.request(req)
    if (response.status < 200 || response.status >= 300) {
      const body = response.body
      const message = body !== null && typeof body === 'object' && 'message' in body ? body.message : null
      throw new Error(typeof message === 'string' ? message : `mihomo HTTP ${response.status}`)
    }
    return response.body
  }

  return {
    async getConfig() {
      const raw = object(await request({ method: 'GET', path: '/configs' }))
      const mode = raw.mode
      if (mode !== 'rule' && mode !== 'global' && mode !== 'direct') throw new Error('Invalid mihomo mode')
      if (typeof raw['allow-lan'] !== 'boolean') throw new Error('Invalid mihomo allow-lan')
      return { mode, mixedPort: number(raw['mixed-port']), allowLan: raw['allow-lan'], logLevel: logLevel(raw['log-level']) }
    },
    async setMode(mode) {
      await request({ method: 'PATCH', path: '/configs', body: { mode } })
    },
    async getProxyGroups() {
      const raw = object(object(await request({ method: 'GET', path: '/proxies' })).proxies)
      const groups: ProxyGroup[] = []
      const entries: Array<[string, Proxy]> = []
      for (const [name, value] of Object.entries(raw)) {
        const proxy = object(value)
        const type = text(proxy.type)
        if ('all' in proxy && 'now' in proxy) {
          if (!Array.isArray(proxy.all)) throw new Error('Invalid mihomo group members')
          groups.push({ name, type, now: text(proxy.now), all: proxy.all.map(text) })
        }
        if (proxy.history !== undefined && !Array.isArray(proxy.history)) throw new Error('Invalid mihomo delay history')
        const last = (proxy.history as unknown[] | undefined)?.at(-1)
        const delay = last === undefined ? null : number(object(last).delay) || null
        entries.push([name, { name, type, delay }])
      }
      return { groups, proxies: Object.fromEntries(entries) }
    },
    async selectProxy(group, proxy) {
      await request({ method: 'PUT', path: `/proxies/${encodeURIComponent(group)}`, body: { name: proxy } })
    },
    async closeAllConnections() {
      await request({ method: 'DELETE', path: '/connections' })
    },
    traffic(onData, onClose) {
      return transport.stream('/traffic', (data) => {
        const raw = object(data)
        onData({ up: number(raw.up), down: number(raw.down) })
      }, onClose)
    },
    logs(onData, onClose) {
      return transport.stream('/logs', (data) => {
        const raw = object(data)
        onData({ level: logLevel(raw.type), payload: text(raw.payload) })
      }, onClose)
    },
    connections(onData, onClose) {
      return transport.stream('/connections', (data) => {
        const raw = object(data)
        if (!Array.isArray(raw.connections)) throw new Error('Invalid mihomo connections')
        onData({ uploadTotal: number(raw.uploadTotal), downloadTotal: number(raw.downloadTotal), count: raw.connections.length })
      }, onClose)
    }
  }
}
