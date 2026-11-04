// Ordinary-user compatibility probe only: no Electron/App launch, services or network.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

if (process.platform !== 'darwin' || process.getuid() === 0) throw new Error('Run as an ordinary macOS user')
const directory = await mkdtemp(join(tmpdir(), 'kuro-library-validation-'))
try {
  const library = join(directory, 'fixture.dylib')
  const loader = join(directory, 'loader')
  await writeFile(join(directory, 'library.c'), 'int fixture(void) { return 42; }\n')
  await writeFile(join(directory, 'loader.c'), `#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  void *handle = dlopen(argv[1], RTLD_NOW);
  if (!handle) { fprintf(stderr, "%s\\n", dlerror()); return 1; }
  int (*fixture)(void) = dlsym(handle, "fixture");
  int ok = fixture && fixture() == 42;
  dlclose(handle);
  return ok ? 0 : 3;
}
`)
  execFileSync('/usr/bin/clang', ['-Wall', '-Wextra', '-Werror', '-dynamiclib', join(directory, 'library.c'), '-o', library])
  execFileSync('/usr/bin/clang', ['-Wall', '-Wextra', '-Werror', join(directory, 'loader.c'), '-o', loader])
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', library], { stdio: 'pipe' })
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', loader], { stdio: 'pipe' })
  const hardened = spawnSync(loader, [library], { encoding: 'utf8', timeout: 5000 })
  assert.equal(hardened.status, 1, 'expected hardened ad-hoc loader to refuse the separate ad-hoc library')
  assert.match(hardened.stderr, /different Team IDs/)
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', '0', loader], { stdio: 'pipe' })
  const ordinary = spawnSync(loader, [library], { encoding: 'utf8', timeout: 5000 })
  assert.equal(ordinary.status, 0, ordinary.stderr)
  console.log('Confirmed: separate ad-hoc library loads normally but hardened runtime rejects its Team ID; no App/system operations')
} finally { await rm(directory, { recursive: true, force: true }) }
