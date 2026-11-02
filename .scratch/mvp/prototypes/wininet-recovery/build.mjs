import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
mkdirSync(join(root, 'out'), { recursive: true })
const flags = ['-static', '-O2', '-Wall', '-Wextra', '-Werror', '-municode', '-mwindows']
execFileSync('gcc', [...flags, join(root, 'probe.c'), '-lwininet', '-lrasapi32', '-ladvapi32',
  '-o', join(root, 'out/probe.exe')], { stdio: 'inherit', timeout: 60000 })
execFileSync('gcc', [...flags, join(root, '../prestarted-helper-deadline/native/watchdog.c'),
  '-o', join(root, 'out/watchdog.exe')], { stdio: 'inherit', timeout: 60000 })
execFileSync(join(root, 'out/probe.exe'), ['self-test'], { timeout: 10000, windowsHide: true })
console.log('Built shared-operation probe; pure restoration guards passed (no proxy writes)')
