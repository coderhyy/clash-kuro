// Read-only, isolated feasibility probe; timeout is failure, not identity evidence.
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
if (process.platform !== 'win32') throw new Error('Windows only')
const out = join(root, 'out', `logon-probe-${Date.now()}`)
mkdirSync(out, { recursive: true })
const exe = join(out, 'logon-probe.exe')
execFileSync('gcc', ['-D_WIN32_WINNT=0x0A00', '-static', '-O2', '-Wall', '-Wextra', '-Werror',
  join(root, 'native/logon_probe.c'), '-lsecur32', '-ladvapi32', '-o', exe], { timeout: 60000, stdio: 'inherit' })
const text = execFileSync(exe, [], { timeout: 5000, encoding: 'utf8', windowsHide: true })
const rows = text.trim().split(/\r?\n/).map(line => JSON.parse(line))
if (rows.length !== 2 || !rows[0].validIdentity) throw new Error('Invalid identity evidence')
writeFileSync(join(out, 'result.json'), JSON.stringify({ readOnly: true, rows }, null, 2) + '\n')
console.log(text + out)
