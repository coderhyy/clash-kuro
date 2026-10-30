import { readFileSync } from 'node:fs'
import { expect, test } from 'vitest'
// @ts-expect-error -- plain .mjs build script
import { checkLock, sha256, verify } from './fetch-core.mjs'

const lock = JSON.parse(readFileSync(new URL('../core.lock.json', import.meta.url), 'utf8'))

test('the committed lock pins every artifact by tag/commit with a sha256', () => {
  expect(() => checkLock(lock)).not.toThrow()
  expect(Object.keys(lock.mihomo.targets)).toEqual(expect.arrayContaining(['darwin-arm64', 'darwin-x64', 'win32-x64']))
})

test('rejects latest URLs and missing hashes', () => {
  const bad = structuredClone(lock)
  bad.geodata.files['GeoSite.dat'].url = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat'
  expect(() => checkLock(bad)).toThrow(/pinned/)
  const noHash = structuredClone(lock)
  noHash.mihomo.targets['darwin-arm64'].sha256 = ''
  expect(() => checkLock(noHash)).toThrow(/sha256/)
})

test('verify fails on a hash mismatch', () => {
  const data = Buffer.from('kuro')
  expect(verify(data, sha256(data), 'x')).toBe(data)
  expect(() => verify(data, '0'.repeat(64), 'x')).toThrow(/sha256 mismatch for x/)
})
