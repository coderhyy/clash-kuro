import { request as httpRequest } from 'node:http'
import { Agent, request as httpsRequest } from 'node:https'
import { connect } from 'node:tls'
import type { FetchResult } from '@tern/core'

/** Profile downloads use a separate HTTP proxy connection, never a global proxy setting. */
export async function fetchProfileText(
  url: string,
  options: { viaCore: boolean; userAgent: string; mixedPort: number; timeoutMs?: number },
  redirects = 0,
): Promise<FetchResult> {
  const target = new URL(url)
  if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) {
    throw new Error('Profile URL must be HTTP(S) without embedded credentials')
  }
  const secure = target.protocol === 'https:'
  const timeoutMs = options.timeoutMs ?? 30_000
  let agent: Agent | undefined
  try {
    if (options.viaCore && secure) {
      const socket = await new Promise<import('node:net').Socket>((resolve, reject) => {
        const req = httpRequest({
          host: '127.0.0.1', port: options.mixedPort, method: 'CONNECT',
          path: `${target.hostname}:${target.port || 443}`,
          headers: { host: target.host, 'user-agent': options.userAgent },
        })
        const timer = setTimeout(() => req.destroy(new Error('Profile proxy CONNECT timed out')), timeoutMs)
        req.once('error', reject)
        req.once('close', () => clearTimeout(timer))
        req.once('connect', (res, tunnel, head) => {
          clearTimeout(timer)
          if (res.statusCode !== 200) {
            tunnel.destroy()
            reject(new Error(`Profile proxy CONNECT failed: HTTP ${res.statusCode}`))
          } else {
            if (head.length) tunnel.unshift(head)
            resolve(tunnel)
          }
        })
        req.end()
      })
      agent = new Agent({ keepAlive: false })
      agent.createConnection = () => connect({ socket, servername: target.hostname })
    }
    const result = await new Promise<FetchResult>((resolve, reject) => {
      const throughHttpProxy = options.viaCore && !secure
      const req = (secure ? httpsRequest : httpRequest)({
        hostname: throughHttpProxy ? '127.0.0.1' : target.hostname,
        port: throughHttpProxy ? options.mixedPort : target.port || (secure ? 443 : 80),
        path: throughHttpProxy ? target.href : target.pathname + target.search,
        headers: { host: target.host, 'user-agent': options.userAgent, 'accept-encoding': 'identity' },
        agent: agent ?? false,
      })
      const timer = setTimeout(() => req.destroy(new Error('Profile download timed out')), timeoutMs)
      req.once('close', () => clearTimeout(timer))
      req.once('error', reject)
      req.once('response', (res) => {
        const chunks: Buffer[] = []
        let size = 0
        res.on('data', (chunk: Buffer) => {
          size += chunk.length
          if (size > 32 * 1024 * 1024) req.destroy(new Error('Profile exceeds 32 MiB'))
          else chunks.push(chunk)
        })
        res.once('error', reject)
        res.once('end', () => resolve({
          status: res.statusCode ?? 0,
          headers: Object.fromEntries(Object.entries(res.headers).filter((entry) => entry[1] !== undefined)
            .map(([key, value]) => [key, Array.isArray(value) ? value.join(', ') : value!])),
          body: Buffer.concat(chunks).toString('utf8'),
        }))
      })
      req.end()
    })
    if ([301, 302, 303, 307, 308].includes(result.status) && result.headers.location) {
      if (redirects >= 5) throw new Error('Too many Profile redirects')
      return await fetchProfileText(new URL(result.headers.location, target).href, options, redirects + 1)
    }
    return result
  } finally { agent?.destroy() }
}
