import { createServer, type RequestListener } from 'node:http'
import type { Socket } from 'node:net'
import { afterEach, expect, test } from 'vitest'
import { fetchProfileText } from './fetch'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup() })

async function fixture(handler?: RequestListener) {
  const server = createServer(handler)
  const sockets = new Set<Socket>()
  server.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)) })
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  cleanups.push(async () => {
    for (const socket of sockets) socket.destroy()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  return { server, port: address.port, url: `http://127.0.0.1:${address.port}` }
}

test('direct downloads preserve status and lower-case subscription headers, UA and redirects', async () => {
  const { url } = await fixture((req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { location: '/profile' }).end(); return }
    expect(req.headers['user-agent']).toBe('Kuro-test')
    res.writeHead(200, { 'Subscription-Userinfo': 'upload=1; download=2', 'Profile-Update-Interval': '24' }).end('mode: direct')
  })
  const result = await fetchProfileText(`${url}/redirect`, { viaCore: false, userAgent: 'Kuro-test', mixedPort: 1 })
  expect(result.status).toBe(200)
  expect(result.headers['subscription-userinfo']).toBe('upload=1; download=2')
  expect(result.headers['profile-update-interval']).toBe('24')
  expect(result.body).toBe('mode: direct')
})

test('HTTP viaCore uses absolute-form proxy requests and preserves the origin host', async () => {
  const { port } = await fixture((req, res) => {
    expect(req.url).toBe('http://profile.invalid/sub?token=test')
    expect(req.headers.host).toBe('profile.invalid')
    res.writeHead(503).end('proxy result')
  })
  expect(await fetchProfileText('http://profile.invalid/sub?token=test', { viaCore: true, userAgent: 'Clash Kuro', mixedPort: port }))
    .toMatchObject({ status: 503, body: 'proxy result' })
})

test('HTTPS viaCore uses CONNECT, rejects proxy errors and times out stalled tunnels', async () => {
  const { server, port } = await fixture()
  server.on('connect', (req, socket) => {
    expect(req.url).toBe('profile.invalid:443')
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n')
  })
  await expect(fetchProfileText('https://profile.invalid/sub', { viaCore: true, userAgent: 'Clash Kuro', mixedPort: port }))
    .rejects.toThrow('CONNECT failed: HTTP 403')
  server.removeAllListeners('connect')
  server.on('connect', () => {})
  await expect(fetchProfileText('https://profile.invalid/sub', { viaCore: true, userAgent: 'Clash Kuro', mixedPort: port, timeoutMs: 30 }))
    .rejects.toThrow('CONNECT timed out')
})

test('download timeouts and redirect loops reject, not hang', async () => {
  const { url } = await fixture((req, res) => {
    if (req.url === '/loop') res.writeHead(302, { location: '/loop' }).end()
  })
  await expect(fetchProfileText(`${url}/hang`, { viaCore: false, userAgent: 'Clash Kuro', mixedPort: 1, timeoutMs: 30 })).rejects.toThrow('timed out')
  await expect(fetchProfileText(`${url}/loop`, { viaCore: false, userAgent: 'Clash Kuro', mixedPort: 1 })).rejects.toThrow('Too many')
})

test.each(['file:///etc/passwd', 'ftp://host/profile', 'https://user:password@host/profile'])('rejects unsupported Profile URL %s', async (url) => {
  await expect(fetchProfileText(url, { viaCore: false, userAgent: 'Clash Kuro', mixedPort: 1 })).rejects.toThrow('HTTP(S)')
})
