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
  await writeFile(join(directory, 'library.c'), '#include <stdio.h>\n__attribute__((constructor)) static void injected(void) { fputs("KURO_DYLD_CONSTRUCTOR_MARKER\\n", stderr); }\nint fixture(void) { return 42; }\n')
  await writeFile(join(directory, 'loader.c'), `#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  if (!strcmp(argv[1], "--no-load")) { puts("loader main reached without dlopen"); return 0; }
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
  const entitlement = join(directory, 'disable-library-validation.plist')
  await writeFile(entitlement, '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>')
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--entitlements', entitlement, loader], { stdio: 'pipe' })
  const signedEntitlements = execFileSync('/usr/bin/codesign', ['--display', '--entitlements', '-', loader], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
  assert.match(signedEntitlements, /com\.apple\.security\.cs\.disable-library-validation/)
  assert.doesNotMatch(signedEntitlements, /allow-dyld-environment-variables|get-task-allow/)
  const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('DYLD_') && !name.startsWith('__XPC_DYLD_')))
  const compatible = spawnSync(loader, [library], { encoding: 'utf8', timeout: 5000, env: environment })
  assert.equal(compatible.status, 0, compatible.stderr)
  assert.match(compatible.stderr, /KURO_DYLD_CONSTRUCTOR_MARKER/)
  // No dlopen on this path: a constructor marker would prove pre-main injection.
  const injectedEnvironment = { ...environment, DYLD_INSERT_LIBRARIES: library }
  const protectedLaunch = spawnSync(loader, ['--no-load'], { encoding: 'utf8', timeout: 5000, env: injectedEnvironment })
  assert.equal(protectedLaunch.status, 0, protectedLaunch.stderr)
  assert.match(protectedLaunch.stdout, /loader main reached without dlopen/)
  assert.doesNotMatch(protectedLaunch.stderr, /KURO_DYLD_CONSTRUCTOR_MARKER/, 'runtime without allow-dyld-env must block this injection attempt')
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', '0', loader], { stdio: 'pipe' })
  const ordinary = spawnSync(loader, [library], { encoding: 'utf8', timeout: 5000, env: environment })
  assert.equal(ordinary.status, 0, ordinary.stderr)
  const injectedControl = spawnSync(loader, ['--no-load'], { encoding: 'utf8', timeout: 5000, env: injectedEnvironment })
  assert.equal(injectedControl.status, 0, injectedControl.stderr)
  assert.match(injectedControl.stderr, /KURO_DYLD_CONSTRUCTOR_MARKER/, 'non-runtime control must demonstrate that the injection payload works')
  console.log('Confirmed: strict runtime rejects separate ad-hoc library; runtime+disableLV loads it but no-allowDYLD blocks constructor injection; non-runtime injection control succeeds. C loader only, not Electron attestation; no App/network/service operations')
} finally { await rm(directory, { recursive: true, force: true }) }
