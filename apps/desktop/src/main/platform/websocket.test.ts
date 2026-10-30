import { describe, expect, test } from 'vitest'
import { clientFrame, WebSocketReader } from './websocket'

export function serverFrame(text: string | Buffer, opcode = 1, final = true): Buffer {
  const payload = typeof text === 'string' ? Buffer.from(text) : text
  const size = payload.length < 126 ? 2 : payload.length < 65536 ? 4 : 10
  const header = Buffer.alloc(size)
  header[0] = (final ? 0x80 : 0) | opcode
  header[1] = size === 2 ? payload.length : size === 4 ? 126 : 127
  if (size === 4) header.writeUInt16BE(payload.length, 2)
  if (size === 10) header.writeBigUInt64BE(BigInt(payload.length), 2)
  return Buffer.concat([header, payload])
}

test('parses every TCP split, multiple frames, fragmented UTF-8 and interleaved ping', () => {
  const utf8 = Buffer.from('hello \u4f60\u597d')
  const frames = Buffer.concat([
    serverFrame(utf8.subarray(0, 7), 1, false), serverFrame('ping', 9),
    serverFrame(utf8.subarray(7), 0), serverFrame('second'),
  ])
  for (let split = 0; split <= frames.length; split++) {
    const texts: string[] = []
    const controls: number[] = []
    const reader = new WebSocketReader((text) => texts.push(text), (opcode) => controls.push(opcode))
    reader.push(frames.subarray(0, split))
    reader.push(frames.subarray(split))
    expect(texts).toEqual(['hello \u4f60\u597d', 'second'])
    expect(controls).toEqual([9])
  }
})

test.each([0, 125, 126, 65535, 65536, 70000])('reads extended length %i and partial headers', (size) => {
  const texts: string[] = []
  const reader = new WebSocketReader((text) => texts.push(text), () => {})
  const frame = serverFrame('x'.repeat(size))
  for (const byte of frame.subarray(0, 10)) reader.push(Buffer.from([byte]))
  reader.push(frame.subarray(10))
  expect(texts).toEqual(['x'.repeat(size)])
})

test('client pong/close frames are masked with an unmodified payload', () => {
  for (const opcode of [8, 10]) {
    const payload = Buffer.from('ping')
    const frame = clientFrame(opcode, payload)
    expect(frame[0]).toBe(0x80 | opcode)
    expect(frame[1]).toBe(0x80 | payload.length)
    const decoded = Buffer.from(frame.subarray(6))
    for (let i = 0; i < decoded.length; i++) decoded[i] = decoded[i]! ^ frame[2 + i % 4]!
    expect(decoded).toEqual(payload)
  }
  expect(() => clientFrame(9, Buffer.alloc(126))).toThrow('too large')
})

describe('rejects invalid or unbounded frames', () => {
  test.each([
    Buffer.from([0xc1, 0]), Buffer.from([0x81, 0x80]), Buffer.from([0x82, 0]),
    Buffer.from([0x80, 0]), Buffer.from([0x09, 0]), Buffer.from([0x89, 126]),
    Buffer.from([0x88, 1, 0]), Buffer.from([0x81, 126, 0, 1, 65]),
    Buffer.from([0x81, 127, 0, 0, 0, 0, 0, 0, 1, 0]),
    Buffer.from([0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]),
    serverFrame(Buffer.from([0xff])), serverFrame(Buffer.from([0x03, 0xed]), 8),
  ])('invalid frame %#', (frame) => {
    const reader = new WebSocketReader(() => {}, () => {})
    expect(() => reader.push(frame)).toThrow()
  })
  test('rejects a new text frame during fragmentation and excessive aggregate size', () => {
    const reader = new WebSocketReader(() => {}, () => {})
    reader.push(serverFrame('first', 1, false))
    expect(() => reader.push(serverFrame('second'))).toThrow('continuation')
    const large = new WebSocketReader(() => {}, () => {})
    large.push(serverFrame(Buffer.alloc(8 * 1024 * 1024), 1, false))
    expect(() => large.push(serverFrame('x', 0))).toThrow('too large')
  })
})

test('does not deliver frames after close', () => {
  const texts: string[] = []
  const reader = new WebSocketReader((text) => texts.push(text), () => {})
  reader.push(Buffer.concat([serverFrame('', 8), serverFrame('ignored')]))
  reader.push(serverFrame('also ignored'))
  expect(texts).toEqual([])
})
