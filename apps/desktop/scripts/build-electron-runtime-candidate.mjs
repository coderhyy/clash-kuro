// Rebuild from committed source; never mutates/reseals an existing App or launches it.
import { execFileSync } from 'node:child_process'
import { lstat, mkdir, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertMacosCandidateMode, macosCandidateMetadata, macosClientPin } from './macos-client-pin.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export function candidateBuildPlan(target, mode, sourceCommit) {
  if (!['darwin-arm64', 'darwin-x64'].includes(target) || !['auth-only', 'finite-session'].includes(mode) || !/^[a-f0-9]{40}$/.test(sourceCommit)) throw new Error('Expected a fixed macOS target, candidate mode and full source commit')
  const arch = target.slice(7)
  const output = join(root, 'dist', mode === 'finite-session' ? `electron-finite-session-candidate-${sourceCommit.slice(0, 12)}` : 'electron-runtime-candidate')
  return { output, bundle: join(output, arch === 'arm64' ? 'mac-arm64' : 'mac', 'Clash Kuro.app'), commands: [
    [join(root, 'node_modules/.bin/electron-vite'), ['build']],
    [join(root, 'node_modules/.bin/electron-builder'), ['--mac', '--dir', `--${arch}`, `-c.directories.output=${output}`,
      `-c.extraMetadata.kuroSourceCommit=${sourceCommit}`, `-c.extraMetadata.kuroCandidateMode=${mode}`,
      `-c.extraMetadata.kuroAuthObservationOnly=${mode === 'auth-only'}`]],
  ] }
}

export async function buildElectronRuntimeCandidate(target, mode) {
  if (process.platform !== 'darwin' || process.getuid() === 0) throw new Error('Ordinary macOS build user required')
  const commit = () => execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
  const clean = () => !execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'apps/desktop', 'packages'], { cwd: resolve(root, '../..'), encoding: 'utf8' }).trim()
  const sourceCommit = commit()
  const plan = candidateBuildPlan(target, mode, sourceCommit)
  if (!clean()) throw new Error('Commit candidate implementation before rebuilding the App')
  // Existing candidates stay immutable. A failed output must be inspected explicitly.
  try { await lstat(plan.output); throw new Error('Candidate output exists; do not reuse or reseal an old App') } catch (error) { if (error.code !== 'ENOENT') throw error }
  const dist = join(root, 'dist')
  await mkdir(dist, { recursive: true })
  const info = await lstat(dist)
  if (!info.isDirectory() || info.isSymbolicLink() || info.mode & 0o022) throw new Error('Unsafe candidate output directory')
  for (const [command, args] of plan.commands) execFileSync(command, args, { cwd: root, stdio: 'inherit' })
  const client = await macosClientPin(plan.bundle) // Existing seal/hardened runtime/fuse verifier.
  assertMacosCandidateMode(await macosCandidateMetadata(plan.bundle), mode, sourceCommit)
  if (commit() !== sourceCommit || !clean()) throw new Error('Candidate source changed during the fresh build')
  const record = { format: 1, mode, sourceCommit, sourceClean: true, fromSource: true, client, commands: plan.commands,
    realTunAccepted: false, limitation: 'Build and offline identity only; App/Core not launched. Sealed finite-session startup uses fixed appData/Clash Kuro TUN Candidate private data, retained across candidates and separate from normal product profiles. No arbitrary user-data-dir argument is enabled.' }
  await writeFile(join(plan.output, 'build.json'), `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600, flag: 'wx' })
  console.log(`Fresh ${mode} candidate: ${plan.bundle} (not launched or installed)`)
  return plan.bundle
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  if (args.length !== 2) { console.error('Usage: build-electron-runtime-candidate.mjs <darwin-arm64|darwin-x64> <auth-only|finite-session>'); process.exitCode = 1 }
  else buildElectronRuntimeCandidate(args[0], args[1]).catch(error => { console.error(error.message); process.exitCode = 1 })
}
