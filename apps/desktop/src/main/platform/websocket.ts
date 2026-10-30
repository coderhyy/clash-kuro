import { randomBytes } from 'node:crypto'
import { TextDecoder } from 'node:util'

const MAX_MESSAGE_BYTES = 8 * 1024 * 1024

/** Client control frames must be masked, including pong and close. */
export function clientFrame(opcode: number, payload: Buffer = Buffer.alloc(0)): Buffer {
  if (payload.length > 125) throw new Error('WebSocket control frame is too large')
  const mask = randomBytes(4)
  const frame = Buffer.alloc(6 + payload.length)
  frame[0] = 0x80 | opcode
  frame[1] = 0x80 | payload.length
  mask.copy(frame, 2)
  for (let i = 0; i < payload.length; i++) frame[i + 6] = payload[i]! ^ mask[i % 4]!
  return frame
}

/** Incremental RFC 6455 reader; text messages may span frames and TCP chunks. */
export class WebSocketReader {
  private pending = Buffer.alloc(0)
  private fragments: Buffer[] = []
  private messageBytes = 0
  private closed = false

  constructor(
    private readonly onText: (text: string) => void,
    private readonly onControl: (opcode: number, payload: Buffer) => void,
  ) {}

  push(chunk: Buffer): void {
    if (this.closed) return
    this.pending = Buffer.concat([this.pending, chunk])
    while (this.pending.length >= 2) {
      const first = this.pending[0]!
      const second = this.pending[1]!
      const final = (first & 0x80) !== 0
      const opcode = first & 0x0f
      const control = opcode >= 8
      if ((first & 0x70) || (second & 0x80)) throw new Error('Invalid WebSocket flags')
      if (![0, 1, 8, 9, 10].includes(opcode)) throw new Error('Unsupported WebSocket opcode')
      let length = second & 0x7f
      let offset = 2
      if (control && (!final || length > 125)) throw new Error('Invalid WebSocket control frame')
      if (length === 126) {
        if (this.pending.length < 4) return
        length = this.pending.readUInt16BE(2)
        if (length < 126) throw new Error('Non-minimal WebSocket length')
        offset = 4
      } else if (length === 127) {
        if (this.pending.length < 10) return
        const wideLength = this.pending.readBigUInt64BE(2)
        if (wideLength > BigInt(MAX_MESSAGE_BYTES)) throw new Error('WebSocket message is too large')
        length = Number(wideLength)
        if (length < 65536) throw new Error('Non-minimal WebSocket length')
        offset = 10
      }
      if (length > MAX_MESSAGE_BYTES || (!control && this.messageBytes + length > MAX_MESSAGE_BYTES)) {
        throw new Error('WebSocket message is too large')
      }
      if (this.pending.length < offset + length) return
      const payload = this.pending.subarray(offset, offset + length)
      this.pending = this.pending.subarray(offset + length)
      if (control) {
        if (opcode === 8) {
          if (length === 1) throw new Error('Invalid WebSocket close frame')
          if (length >= 2) {
            const code = payload.readUInt16BE(0)
            if (code < 1000 || code >= 5000 || [1004, 1005, 1006, 1015].includes(code)
              || (code >= 1016 && code < 3000)) throw new Error('Invalid WebSocket close code')
            new TextDecoder('utf-8', { fatal: true }).decode(payload.subarray(2))
          }
          this.closed = true
        }
        this.onControl(opcode, payload)
        if (this.closed) return
        continue
      }
      if ((opcode === 0) !== (this.fragments.length > 0)) throw new Error('Invalid WebSocket continuation')
      this.fragments.push(payload)
      this.messageBytes += length
      if (final) {
        const text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(this.fragments))
        this.fragments = []
        this.messageBytes = 0
        this.onText(text)
      }
    }
  }
}
