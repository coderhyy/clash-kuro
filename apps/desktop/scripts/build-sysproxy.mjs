// Build the Windows System Proxy helper (issue 08) into resources/win/<arch>/kuro-sysproxy.exe.
// Usage: node scripts/build-sysproxy.mjs [--test]
// Compiler: $CC if set, else the first of x86_64-w64-mingw32-clang/-gcc, gcc, clang on PATH (mingw-w64).
// --test also builds and runs the endpoint parser unit test.
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const src = join(root, 'native', 'win')
const arch = 'x64'
const outDir = join(root, 'resources', 'win', arch)

function works(cmd) {
  try { execFileSync(cmd, ['--version'], { stdio: 'ignore' }); return true } catch { return false }
}

const cc = process.env.CC || ['x86_64-w64-mingw32-clang', 'x86_64-w64-mingw32-gcc', 'gcc', 'clang'].find(works)
if (!cc) throw new Error('No mingw-w64 C compiler found; install LLVM-MinGW or mingw-w64, or set CC')
// windres ships next to the compiler in mingw-w64 toolchains.
const windres = process.env.WINDRES || [cc.replace(/(clang|gcc)(\.exe)?$/, 'windres'), 'x86_64-w64-mingw32-windres', 'windres'].find(works)
if (!windres) throw new Error('windres not found next to the compiler; set WINDRES')

const run = (file, args) => execFileSync(file, args, { stdio: 'inherit' })
const warnings = ['-Wall', '-Wextra', '-Werror']
const tmp = mkdtempSync(join(tmpdir(), 'kuro-sysproxy-'))
try {
  if (process.argv.includes('--test')) {
    const test = join(tmp, 'endpoint_test.exe')
    run(cc, [...warnings, '-mconsole', '-O2', join(src, 'endpoint_test.c'), '-o', test])
    run(test, [])
  }
  const res = join(tmp, 'kuro-sysproxy.res.o')
  run(windres, ['-I', src, '-O', 'coff', join(src, 'kuro-sysproxy.rc'), '-o', res])
  mkdirSync(outDir, { recursive: true })
  const exe = join(outDir, 'kuro-sysproxy.exe')
  // -static avoids shipping libgcc/libwinpthread DLLs; WinINet, RAS and Advapi32 are system DLLs.
  // -mwindows: GUI subsystem, so Windows creates no console for it (stdout pipes still work).
  run(cc, [...warnings, '-mwindows', '-municode', '-O2', '-s', '-static', join(src, 'kuro-sysproxy.c'), res, '-lwininet', '-lrasapi32', '-ladvapi32', '-o', exe])
  console.log(`built ${exe} with ${cc}`)
} finally { rmSync(tmp, { recursive: true, force: true }) }
