import { expect, test } from 'vitest'
import { residentClose, residentRequest } from './resident-protocol'

test('request encoding matches native LE header and UTF-16 argv, including an empty argument', () => {
  expect([...residentRequest(['get'])]).toEqual([1, 0, 0, 0, 8, 0, 0, 0, 103, 0, 101, 0, 116, 0, 0, 0])
  const args = ['set', '--bypass', '', 'C:\\Clash Kuro\\\u4e2d\u6587']
  const frame = residentRequest(args)
  expect(frame.readUInt32LE(4)).toBe(frame.length - 8)
  expect(frame.subarray(8).toString('utf16le')).toBe(args.join('\0') + '\0')
  expect([...residentClose()]).toEqual([2, 0, 0, 0, 0, 0, 0, 0])
})

test('rejects truncation/injection and bounds allocation before encoding', () => {
  for (const args of [[], [''], ['get\0set'], Array(33).fill('x'), ['x'.repeat(32768)]]) {
    expect(() => residentRequest(args)).toThrow()
  }
  expect(residentRequest(['x'.repeat(32767)]).length).toBe(65544)
  expect(residentRequest(Array(32).fill('x')).readUInt32LE(4)).toBe(128)
})
