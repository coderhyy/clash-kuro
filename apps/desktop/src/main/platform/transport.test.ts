import { createHash } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type RequestListener, type Server } from 'node:http'
import { join } from 'node:path'
import type { Socket } from 'node:net'
import { afterEach, expect, test, vi } from 'vitest'
import { createSocketTransport } from './transport'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup() })

async function fixture(handler?: RequestListener) {
  const dir = await mkdtemp('/tmp/kuro-transport-')
  const path = join(dir, 'api.sock')
  const server = createServer(handler)
  const sockets = new Set<Socket>()
  server.on('connection', (socket) => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)) })
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(path, resolve))
  cleanups.push(async () => {
    for (const socket of sockets) socket.destroy()
    await new Promise<void>((resolve) => server.close(() => resolve()))
    await rm(dir, { recursive: true, force: true })
  })
  return { server, transport: createSocketTransport({ kind: 'unix', path }, { timeoutMs: 150 }) }
}

function upgrade(server: Server, payload: Buffer, onData?: (data: Buffer, socket: Socket) => void, invalidAccept = false) {
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
    socket.write(Buffer.concat([
      Buffer.from('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
        + `Sec-WebSocket-Accept: ${invalidAccept ? 'invalid' : accept}\r\n\r\n`), payload,
    ]))
    if (onData) socket.on('data', (data: Buffer) => onData(data, socket as Socket))
  })
}

test('HTTP request serializes JSON, preserves status and handles empty responses', async () => {
  const { transport } = await fixture((req, res) => {
    if (req.url === '/connections') { res.writeHead(204).end(); return }
    let body = ''
    req.on('data', (chunk) => { body += chunk })
    req.on('end', () => {
      res.writeHead(400).end(JSON.stringify({ method: req.method, path: req.url, body: JSON.parse(body), type: req.headers['content-type'] }))
    })
  })
  expect(await transport.request({ method: 'PATCH', path: '/configs?test=1', body: { mode: 'direct' } })).toEqual({
    status: 400, body: { method: 'PATCH', path: '/configs?test=1', body: { mode: 'direct' }, type: 'application/json' },
  })
  expect(await transport.request({ method: 'DELETE', path: '/connections' })).toEqual({ status: 204, body: null })
})

test('rejects malformed JSON and request timeouts', async () => {
  const { transport } = await fixture((req, res) => { if (req.url === '/bad') res.end('not json') })
  await expect(transport.request({ method: 'GET', path: '/bad' })).rejects.toThrow()
  await expect(transport.request({ method: 'GET', path: '/hang' })).rejects.toThrow('timed out')
})

test('named pipe channels use socketPath too', async () => {
  // A unix socket stands in for a pipe in this host-independent routing test.
  const { server } = await fixture((_req, res) => res.end('{"version":"test"}'))
  const name = server.address() as string
  expect(await createSocketTransport({ kind: 'pipe', name }).request({ method: 'GET', path: '/version' }))
    .toEqual({ status: 200, body: { version: 'test' } })
})

test('channel getters follow pipe rotation without replacing the transport/client', async () => {
  const first = await fixture((_req, res) => res.end('{"version":"first"}'))
  const second = await fixture((_req, res) => res.end('{"version":"second"}'))
  let name = first.server.address() as string
  const transport = createSocketTransport(() => ({ kind: 'pipe', name }))
  expect((await transport.request({ method: 'GET', path: '/version' })).body).toEqual({ version: 'first' })
  name = second.server.address() as string
  expect((await transport.request({ method: 'GET', path: '/version' })).body).toEqual({ version: 'second' })
})

test('WebSocket consumes upgrade head, emits JSON, sends masked pong and answers close', async () => {
  const { server, transport } = await fixture()
  const controls: number[] = []
  upgrade(server, Buffer.concat([
    Buffer.from([0x81, 7]), Buffer.from('{"n":1}'), Buffer.from([0x89, 2]), Buffer.from('hi'),
  ]), (frame, socket) => {
    controls.push(frame[0]! & 0x0f)
    expect(frame[1]! & 0x80).toBe(0x80)
    if ((frame[0]! & 0x0f) === 10) {
      const payload = Buffer.from(frame.subarray(6))
      for (let i = 0; i < payload.length; i++) payload[i] = payload[i]! ^ frame[2 + i % 4]!
      expect(payload.toString()).toBe('hi')
      socket.write(Buffer.from([0x88, 0]))
    }
  })
  const messages: unknown[] = []
  await new Promise<void>((resolve, reject) => {
    transport.stream('/traffic', (data) => messages.push(data), (error) => error ? reject(error) : resolve())
  })
  expect(messages).toEqual([{ n: 1 }])
  await vi.waitFor(() => expect(controls).toContain(8))
  expect(controls).toEqual([10, 8])
})

test.each(['accept', 'json', 'http', 'timeout'])('stream fails exactly once for %s error', async (kind) => {
  const { server, transport } = await fixture((_req, res) => { if (kind === 'http') res.writeHead(403).end() })
  if (kind === 'accept') upgrade(server, Buffer.alloc(0), undefined, true)
  if (kind === 'json') upgrade(server, Buffer.from([0x81, 1, 0x78]))
  const onMessage = vi.fn()
  const onClose = vi.fn()
  await new Promise<void>((resolve) => {
    transport.stream('/logs', onMessage, (error) => { onClose(error); resolve() })
  })
  expect(onClose).toHaveBeenCalledOnce()
  expect(onClose.mock.calls[0]![0]).toBeInstanceOf(Error)
  expect(onMessage).not.toHaveBeenCalled()
})

test('closing before upgrade cancels the request without duplicate callbacks', async () => {
  const { transport } = await fixture()
  const onClose = vi.fn()
  const handle = transport.stream('/traffic', vi.fn(), onClose)
  handle.close()
  handle.close()
  await new Promise((resolve) => setTimeout(resolve, 10))
  expect(onClose).toHaveBeenCalledExactlyOnceWith(undefined)
})

test('closing an established stream sends a masked close frame and is idempotent', async () => {
  const { server, transport } = await fixture()
  const closeReceived = new Promise<void>((resolve) => {
    upgrade(server, Buffer.from([0x81, 2, 0x7b, 0x7d]), (frame) => {
      expect(frame[0]).toBe(0x88)
      expect(frame[1]).toBe(0x80)
      resolve()
    })
  })
  const onClose = vi.fn()
  const handle = transport.stream('/traffic', () => { handle.close(); handle.close() }, onClose)
  await closeReceived
  expect(onClose).toHaveBeenCalledExactlyOnceWith(undefined)
})
