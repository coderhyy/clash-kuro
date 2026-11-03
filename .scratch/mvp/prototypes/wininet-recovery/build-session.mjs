// No launch or proxy access. Produce one self-contained, unsigned experiment folder.
import { execFileSync } from 'node:child_process'
import { cpSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url)), repo = resolve(root, '../../../..')
const out = join(root, 'out/session-package')
const electron = join(repo, 'apps/desktop/node_modules/electron')
if (JSON.parse(readFileSync(join(electron, 'package.json'))).version !== '45.1.0') throw new Error('Wrong Electron')
mkdirSync(join(out, 'bin'), { recursive: true })
const flags = ['-D_WIN32_WINNT=0x0A00', '-static', '-O2', '-Wall', '-Wextra', '-Werror', '-municode', '-mwindows']
const libs = ['-lwininet', '-lrasapi32', '-ladvapi32', '-lshell32', '-lole32', '-luuid', '-lws2_32']
for (const [name, source, extra] of [['probe', 'probe.c', []], ['session', 'session.c', []],
  ['session-fake', 'session.c', ['-DKURO_SESSION_FAKE']]]) {
  execFileSync('gcc', [...flags, ...extra, join(root, source), ...libs, '-o', join(out, `bin/${name}.exe`)],
    { stdio: 'inherit', timeout: 60000 })
}
cpSync(join(electron, 'dist'), join(out, 'runtime'), { recursive: true })
cpSync(join(repo, 'apps/desktop/resources/core/win32-x64/mihomo.exe'), join(out, 'bin/mihomo.exe'))
for (const file of ['session-main.cjs', 'session-check.ps1', 'SESSION-EXPERIMENT.md']) {
  if (!existsSync(join(root, file))) throw new Error(`Missing ${file}`)
  cpSync(join(root, file), join(out, file))
}
const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex')
const files = ['bin/session.exe', 'bin/session-fake.exe', 'bin/probe.exe', 'bin/mihomo.exe',
  'session-main.cjs', 'session-check.ps1', 'runtime/electron.exe']
writeFileSync(join(out, 'manifest.json'), JSON.stringify({ experimentOnly: true, realSessionTested: false,
  builtAt: new Date().toISOString(), sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim(),
  sourceDirty: !!execFileSync('git', ['status', '--porcelain'], { cwd: repo, encoding: 'utf8' }).trim(),
  files: Object.fromEntries(files.map(file => [file, hash(join(out, file))])) }, null, 2))
execFileSync(join(out, 'bin/probe.exe'), ['self-test'], { windowsHide: true, timeout: 10000, stdio: 'inherit' })
console.log(out)
