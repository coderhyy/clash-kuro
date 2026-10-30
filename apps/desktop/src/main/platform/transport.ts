import { createHash, randomBytes } from 'node:crypto'
import { request } from 'node:http'
import type { Socket } from 'node:net'
import type { ControlChannel } from '@tern/core'
import type { HttpResponse, Transport } from '@tern/api'
import { clientFrame, WebSocketReader } from './websocket'

const MAX_RESPONSE_BYTES = 8 * 1024 * 1024

export function createSocketTransport(channel: ControlChannel | (() => ControlChannel), options: { timeoutMs?: number } = {}): Transport {
  // A getter follows Windows pipe rotation without replacing the API client after Core restarts.
  const socketPath = () => {
    const current = typeof channel === 'function' ? channel() : channel
    return current.kind === 'unix' ? current.path : current.name
  }
  const timeoutMs = options.timeoutMs ?? 5_000
  return {
    request(input) {
      return new Promise<HttpResponse>((resolve, reject) => {
        const body = input.body === undefined ? undefined : JSON.stringify(input.body)
        const req = request({
          socketPath: socketPath(), path: input.path, method: input.method,
          headers: body === undefined ? {} : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) },
        })
        const timer = setTimeout(() => req.destroy(new Error('Control Channel request timed out')), timeoutMs)
        req.once('close', () => clearTimeout(timer))
        req.once('error', reject)
        req.once('response', (res) => {
          const chunks: Buffer[] = []
          let size = 0
          res.on('data', (chunk: Buffer) => {
            size += chunk.length
            if (size > MAX_RESPONSE_BYTES) req.destroy(new Error('Control Channel response is too large'))
            else chunks.push(chunk)
          })
          res.once('error', reject)
          res.once('end', () => {
            try {
              const text = Buffer.concat(chunks).toString('utf8')
              resolve({ status: res.statusCode ?? 0, body: text ? JSON.parse(text) : null })
            } catch (error) { reject(error) }
          })
        })
        req.end(body)
      })
    },
    stream(path, onMessage, onClose) {
      const key = randomBytes(16).toString('base64')
      const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
      const req = request({ socketPath: socketPath(), path, headers: {
        connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': key,
      } })
      let socket: Socket | undefined
      let closed = false
      const finish = (error?: Error) => {
        if (closed) return
        closed = true
        clearTimeout(timer)
        req.destroy()
        socket?.destroy()
        onClose?.(error)
      }
      const timer = setTimeout(() => finish(new Error('WebSocket handshake timed out')), timeoutMs)
      req.on('error', finish)
      req.once('response', (res) => {
        res.resume()
        finish(new Error(`WebSocket upgrade failed: HTTP ${res.statusCode}`))
      })
      req.once('upgrade', (res, upgraded, head) => {
        socket = upgraded
        socket.on('error', finish)
        socket.once('close', () => finish())
        if (closed) { socket.destroy(); return }
        if (res.headers['sec-websocket-accept'] !== accept
          || res.headers.upgrade?.toLowerCase() !== 'websocket'
          || !res.headers.connection?.toLowerCase().split(/\s*,\s*/).includes('upgrade')
          || res.headers['sec-websocket-extensions'] || res.headers['sec-websocket-protocol']) {
          finish(new Error('Invalid WebSocket upgrade response'))
          return
        }
        clearTimeout(timer)
        const reader = new WebSocketReader(
          (text) => { if (!closed) onMessage(JSON.parse(text)) },
          (opcode, payload) => {
            if (opcode === 9) socket?.write(clientFrame(10, payload))
            if (opcode === 8) {
              socket?.write(clientFrame(8, payload), () => finish())
            }
          },
        )
        const receive = (chunk: Buffer) => {
          if (closed) return
          try { reader.push(chunk) } catch (error) { finish(error instanceof Error ? error : new Error(String(error))) }
        }
        socket.on('data', receive)
        if (head.length) receive(head)
      })
      req.end()
      return { close() {
        if (closed) return
        if (socket && !socket.destroyed) socket.write(clientFrame(8))
        finish()
      } }
    },
  }
}
