import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = dirname(fileURLToPath(import.meta.url))
const repo = resolve(root, '../../../..')
const actual = JSON.parse(readFileSync(join(repo, 'apps/desktop/node_modules/electron/package.json'))).version
const expected = JSON.parse(readFileSync(join(repo, 'apps/desktop/package.json'))).devDependencies.electron
if (process.platform !== 'win32' || process.arch !== 'x64' || actual !== expected || actual !== '45.1.0') throw new Error('Require project Windows x64 Electron 45.1.0')
mkdirSync(join(root, 'out'), { recursive: true })
const common = ['-static', '-O2', '-Wall', '-Wextra', '-Werror', '-municode']
for (const [source, target] of [['native/helper.c', 'helper'], ['native/watchdog.c', 'watchdog']]) {
  execFileSync('gcc', [...common, join(root, source), '-o', join(root, `out/${target}.exe`)], { stdio: 'inherit', timeout: 60000 })
}
const imports = execFileSync(process.env.OBJDUMP ?? 'llvm-objdump', ['-p', join(root, 'out/helper.exe')], { encoding: 'utf8', timeout: 10000 })
if (/DLL Name: (wininet|rasapi|node\.|libgcc|libwinpthread)/i.test(imports)) throw new Error('Unexpected dependency')
writeFileSync(join(root, 'out/imports.txt'), imports)
console.log(`Built fake helper/Core and existing external Job watchdog; Electron ${actual}`)
