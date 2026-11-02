import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const repo = resolve(root, '../../../..')
const electronDir = join(repo, 'apps/desktop/node_modules/electron')
const version = JSON.parse(readFileSync(join(electronDir, 'package.json'))).version
const expected = JSON.parse(readFileSync(join(repo, 'apps/desktop/package.json'))).devDependencies.electron
if (process.platform !== 'win32' || process.arch !== 'x64' || version !== expected) throw new Error('Require project Windows x64 Electron version')
const out = join(root, 'out')
mkdirSync(out, { recursive: true })
const base = `https://artifacts.electronjs.org/headers/dist/v${version}/`
async function fetchBytes(name) {
  const response = await fetch(base + name, { signal: AbortSignal.timeout(60000) })
  if (!response.ok) throw new Error(`${response.status}: ${base}${name}`)
  return Buffer.from(await response.arrayBuffer())
}
const archiveName = `node-v${version}-headers.tar.gz`
const sums = (await fetchBytes('SHASUMS256.txt')).toString()
const expectedHash = sums.split('\n').map(x => x.trim().split(/\s+/)).find(([, name]) => name === archiveName)?.[0]
if (!expectedHash) throw new Error('Missing official checksum')
const archive = join(out, archiveName)
const bytes = existsSync(archive) ? readFileSync(archive) : await fetchBytes(archiveName)
if (createHash('sha256').update(bytes).digest('hex') !== expectedHash) throw new Error('Header checksum mismatch')
writeFileSync(archive, bytes)
execFileSync('tar', ['-xzf', archive, '-C', out], { timeout: 30000 })
const include = readdirSync(out).map(name => join(out, name, 'include/node')).find(path => existsSync(join(path, 'node_api.h')))
if (!include) throw new Error('Electron headers not found in archive')

// Resolve the small Node-API surface against the host executable. No node.exe import,
// delay-load dependency, C++ ABI or assumption about the packaged executable's name.
const source = readFileSync(join(root, 'native/prototype.c'), 'utf8')
const functions = [...new Set(source.match(/\bnapi_\w+(?=\()/g))].sort()
const declarations = functions.map(name => `static __typeof__(&${name}) api_${name};\n#define ${name} api_${name}`).join('\n')
const loads = functions.map(name => `  api_${name} = (__typeof__(api_${name}))GetProcAddress(host, "${name}"); if (!api_${name}) return 0;`).join('\n')
writeFileSync(join(out, 'bindings.h'), `${declarations}\nstatic int load_bindings(void) {\n  HMODULE host = GetModuleHandleW(NULL);\n${loads}\n  return 1;\n}\n`)
const cc = process.env.CC || 'gcc'
const common = ['-static', '-O2', '-Wall', '-Wextra', '-Werror']
execFileSync(cc, [...common, '-shared', '-DNAPI_VERSION=8', '-DNODE_GYP_MODULE_NAME=electron_deadline',
  '-I', include, '-I', out, join(root, 'native/prototype.c'), '-luser32', '-o', join(out, 'deadline.node')], { stdio: 'inherit', timeout: 60000 })
execFileSync(cc, [...common, '-municode', join(root, 'native/watchdog.c'), '-o', join(out, 'watchdog.exe')], { stdio: 'inherit', timeout: 60000 })
const imports = execFileSync('llvm-objdump', ['-p', join(out, 'deadline.node')], { encoding: 'utf8', timeout: 10000 })
writeFileSync(join(out, 'imports.txt'), imports)
if (/DLL Name: (node\.exe|wininet|rasapi32|libgcc|libwinpthread)/i.test(imports)) throw new Error('Unexpected addon dependency')
writeFileSync(join(out, 'build.json'), JSON.stringify({ version, headerSHA256: expectedHash, include, cc, functions,
  addonSHA256: createHash('sha256').update(readFileSync(join(out, 'deadline.node'))).digest('hex') }, null, 2))
console.log(`Built isolated addon and job watchdog for Electron ${version}`)
