// Parser failures use only `verify`; no test invokes a mutating command.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const dir = join(root, 'out', 'invalid-backups')
mkdirSync(dir, { recursive: true })
const exe = join(root, 'out', 'probe.exe')
execFileSync(exe, ['self-test'], { timeout: 2000, windowsHide: true })
const magic = Buffer.from('KSPB0001')
const word = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b }
const wrap = content => Buffer.concat([magic, content, magic])
const cases = [Buffer.alloc(0), Buffer.from('bad header'), wrap(word(0)), wrap(word(257)),
  wrap(Buffer.concat([word(1), word(3), word(0xffffffff), word(32768)])),
  wrap(Buffer.concat([word(1), word(3), word(0xffffffff), word(1), Buffer.from([0, 0])]))]
for (const [index, bytes] of cases.entries()) {
  const file = join(dir, `${index}.bin`)
  writeFileSync(file, bytes)
  let failure
  try { execFileSync(exe, ['verify', file], { timeout: 2000, windowsHide: true, stdio: 'pipe' }) }
  catch (error) { failure = error }
  assert.equal(failure?.status, 1, `invalid snapshot ${index} must fail before preflight`)
  assert.match(String(failure.stdout), /Invalid or incomplete snapshot/)
}
console.log('Restoration-state guards and 6 malformed snapshots rejected; no proxy writes')
