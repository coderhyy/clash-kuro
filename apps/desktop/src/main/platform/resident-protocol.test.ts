import { expect, test } from 'vitest'
import { residentAdmission, residentClose, residentRequest } from './resident-protocol'

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

test('admission commits four exact digests without text or shell interpretation', () => {
  const fields = ['ab', 'cd', '12', 'ef'].map(value => value.repeat(32)) as [string, string, string, string]
  const frame = residentAdmission(...fields)
  expect(frame.length).toBe(136)
  expect(frame.readUInt32LE(0)).toBe(3)
  expect(frame.readUInt32LE(4)).toBe(128)
  fields.forEach((value, index) => expect(frame.subarray(8 + index * 32, 40 + index * 32).toString('hex')).toBe(value))
  for (const invalid of ['', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), 'x'.repeat(64), 'a'.repeat(64) + '\0']) {
    for (let index = 0; index < 4; index++) {
      const bad = [...fields] as [string, string, string, string]
      bad[index] = invalid
      expect(() => residentAdmission(...bad)).toThrow('Invalid resident admission')
    }
  }
})
