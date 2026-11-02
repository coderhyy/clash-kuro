// Standalone experiment: downloads verified Node build inputs, changes no dependencies.
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

if (process.platform !== 'win32' || process.arch !== 'x64') throw new Error('Windows x64 Node required')
const root = dirname(fileURLToPath(import.meta.url))
const out = join(root, 'out')
mkdirSync(out, { recursive: true })
const base = `https://nodejs.org/download/release/${process.version}/`
async function fetchBytes(path) {
  const response = await fetch(base + path, { signal: AbortSignal.timeout(60000) })
  if (!response.ok) throw new Error(`${response.status} ${base}${path}`)
  return Buffer.from(await response.arrayBuffer())
}
const sums = (await fetchBytes('SHASUMS256.txt')).toString()
for (const name of [`node-${process.version}-headers.tar.gz`, 'win-x64/node.lib']) {
  const expected = sums.split('\n').map(line => line.trim().split(/\s+/)).find(([, path]) => path === name)?.[0]
  if (!expected) throw new Error(`No official checksum: ${name}`)
  const file = join(out, name.split('/').at(-1))
  const data = existsSync(file) ? readFileSync(file) : await fetchBytes(name)
  if (createHash('sha256').update(data).digest('hex') !== expected) throw new Error(`Checksum mismatch: ${file}`)
  writeFileSync(file, data)
}
execFileSync('tar', ['-xzf', join(out, `node-${process.version}-headers.tar.gz`), '-C', out], { timeout: 30000 })
const cc = process.env.CC || 'gcc'
const args = ['-shared', '-static', '-O2', '-Wall', '-Wextra', '-Werror', '-DNAPI_VERSION=8',
  '-DNODE_GYP_MODULE_NAME=deadline_prototype', '-I', join(out, `node-${process.version}`, 'include', 'node'),
  join(root, 'prototype.c'), join(out, 'node.lib'), '-o', join(out, 'deadline.node')]
execFileSync(cc, args, { stdio: 'inherit', timeout: 60000 })
writeFileSync(join(out, 'build.json'), JSON.stringify({ node: process.version, cc, args }, null, 2))
console.log(`Built ${join(out, 'deadline.node')}`)
