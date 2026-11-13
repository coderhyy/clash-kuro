// Build/sign the external native helper and pin the resulting executable for prepare-macos-helper.
// Usage: node scripts/build-macos-helper.mjs [--test] [darwin-arm64|darwin-x64]
import { execFileSync } from 'node:child_process'
import { copyFile, lstat, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sha256 } from './fetch-core.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const known = { 'darwin-arm64': 'arm64', 'darwin-x64': 'x86_64' }
async function directory(path) {
  try { await mkdir(path, { mode: 0o755 }) } catch (error) { if (error.code !== 'EEXIST') throw error }
  const info = await lstat(path)
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o022)) throw new Error(`unsafe build directory: ${path}`)
}
async function replace(path, bytes, mode) {
  try {
    const info = await lstat(path)
    if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || (info.mode & 0o6022)) throw new Error(`unsafe build output: ${path}`)
  } catch (error) { if (error.code !== 'ENOENT') throw error }
  const temporary = await mkdtemp(join(dirname(path), '.helper-build-'))
  try {
    const candidate = join(temporary, 'output')
    await writeFile(candidate, bytes, { mode, flag: 'wx' })
    await rename(candidate, path)
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

// Keep inherited fixture output, but preserve the exit/timeout distinction that
// the CLI's short error.message otherwise loses. This changes no test budget.
export function runNativeCheck(stage, file, args, options) {
  const started = performance.now()
  const log = (event, details = {}) => console.error(`[native-check] ${JSON.stringify({
    stage, event, file, timeoutMs: options.timeout, elapsedMs: Math.round(performance.now() - started), ...details,
  })}`)
  log('started')
  try {
    const result = execFileSync(file, args, options)
    log('passed', { status: 0 })
    return result
  } catch (error) {
    log('failed', { code: error.code ?? null, status: error.status ?? null, signal: error.signal ?? null,
      syscall: error.syscall ?? null, errno: error.errno ?? null })
    throw error
  }
}

export async function buildMacosHelper(target, test = false) {
  if (process.platform !== 'darwin' || !Object.hasOwn(known, target)) throw new Error('build-macos-helper requires macOS and darwin-arm64 or darwin-x64')
  const arch = known[target]
  if (test && target !== `darwin-${process.arch}`) throw new Error('--test must use the host architecture')
  const source = join(root, 'native/mac')
  const temporary = await mkdtemp(join(tmpdir(), 'kuro-helper-build-'))
  const flags = ['-arch', arch, '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-O2', '-framework', 'Foundation', '-framework', 'Security', '-framework', 'SystemConfiguration', '-lbsm']
  try {
    if (test) {
      const binary = join(temporary, 'tests')
      execFileSync('/usr/bin/clang', [...flags, '-Wno-unused-function', join(source, 'kuro-tun-helper.test.m'), '-o', binary], { stdio: 'inherit' })
      // Tests reject root; Unix sockets and installation fixtures stay in private temporary directories.
      // The full install/recovery matrix exceeds 30s on hosted runners; individual waits stay bounded.
      runNativeCheck('native-suite', binary, [], { stdio: 'inherit', timeout: 90_000 })
      runNativeCheck('upgrade-suite', binary, ['--upgrade-tests'], { stdio: 'inherit', timeout: 180_000 })
      // Exercise the production client/store against the signed native fixture before removing it.
      const admissionReport = join(temporary, 'admission.json')
      runNativeCheck('admission-chains', 'node', [join(root, '../../node_modules/vitest/vitest.mjs'), 'run', 'src/main/candidate-startup.test.ts', '-t', 'authenticated native admission', '--maxWorkers=1', '--reporter=default', '--reporter=json', `--outputFile.json=${admissionReport}`], {
        cwd: root, env: { ...process.env, KURO_ADMISSION_FIXTURE: binary }, stdio: 'inherit', timeout: 120_000,
      })
      const admission = JSON.parse(await readFile(admissionReport, 'utf8')).testResults.flatMap(result => result.assertionResults)
        .filter(result => result.fullName.includes('authenticated native admission'))
      if (admission.length !== 10 || admission.some(result => result.status !== 'passed')) throw new Error('All ten production admission chains must execute and pass')
      const outputTests = join(temporary, 'output-tests')
      execFileSync('/usr/bin/clang', [...flags, '-Wno-unused-function', join(source, 'tun-output.test.m'), '-o', outputTests], { stdio: 'inherit' })
      runNativeCheck('output-suite', outputTests, [], { stdio: 'inherit', timeout: 20_000 })
    }
    const binary = join(temporary, 'helper')
    execFileSync('/usr/bin/clang', [...flags, join(source, 'kuro-tun-helper.m'), '-o', binary], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', binary], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--verify', '--strict', binary], { stdio: 'inherit' })
    const bytes = await readFile(binary)
    const { version } = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
    if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('helper version must be an exact semver')
    await directory(join(root, 'resources'))
    await directory(join(root, 'resources/mac'))
    const output = join(root, 'resources/mac', target.slice('darwin-'.length))
    await directory(output)
    await replace(join(output, 'kuro-tun-helper'), bytes, 0o755)
    const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
    const sourceClean = !execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: resolve(root, '../..'), encoding: 'utf8' }).trim()
    await replace(join(output, 'kuro-tun-helper.build.json'), `${JSON.stringify({ sourceCommit, sourceClean, sha256: sha256(bytes), installerProtocol: 2, flags, tests: test, coreSyntaxSkipped: Boolean(process.env.KURO_SKIP_CORE_SYNTAX) }, null, 2)}\n`, 0o644)
    const lock = { format: 1, version, protocol: 1, targets: { [target]: { sha256: sha256(bytes) } } }
    await replace(join(source, 'helper.lock.json'), `${JSON.stringify(lock, null, 2)}\n`, 0o644)
    console.log(`Built ${target} helper ${version}; executable pin written (root activation remains disabled)`)
    return join(output, 'kuro-tun-helper')
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const test = args.includes('--test')
  const targets = args.filter((arg) => arg !== '--test')
  if (targets.length > 1 || args.filter((arg) => arg === '--test').length > 1) {
    console.error('Usage: build-macos-helper.mjs [--test] [darwin-arm64|darwin-x64]')
    process.exitCode = 1
  } else buildMacosHelper(targets[0] || `darwin-${process.arch}`, test).catch((error) => { console.error(error.message); process.exitCode = 1 })
}
