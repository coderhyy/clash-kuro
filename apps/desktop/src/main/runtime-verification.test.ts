import { afterEach, describe, expect, it } from 'vitest'
import { chmodSync, lstatSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { assertObservationCandidateLaunch, inspectPackagedArguments, prepareSessionCandidateDirectory, prepareVerificationDirectory, safeWebPreferences, verificationCapabilities } from './runtime-verification'

const temporary: string[] = []
function directory() { const path = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-electron-runtime-'))); chmodSync(path, 0o700); temporary.push(path); return path }
afterEach(() => { for (const path of temporary.splice(0)) rmSync(path, { recursive: true, force: true }) })
describe('packaged startup boundary', () => {
  it('allows only fixed app actions and the capability-lowering verification entry', () => {
    expect(inspectPackagedArguments([])).toEqual({})
    expect(inspectPackagedArguments(['--hidden', '-psn_0_123'])).toEqual({})
    expect(inspectPackagedArguments(['--kuro-runtime-verification=/private/temp'])).toEqual({ directory: '/private/temp' })
    expect(safeWebPreferences('fixed')).toEqual({ preload: 'fixed', sandbox: true, contextIsolation: true, nodeIntegration: false, devTools: false })
    expect(inspectPackagedArguments(['--kuro-runtime-verification=/a', '--kuro-runtime-verification=/b']).error).toBeTruthy()
  })
  it.each(['--remote-debugging-port=0', '--remote-debugging-pipe', '--inspect=0', '--inspect-brk', '--js-flags=evil', '--renderer-cmd-prefix=evil', '--gpu-launcher=evil', '--no-sandbox', '/tmp/evil.js', '--kuro-runtime-verification='])('rejects unsafe argument %s', arg => {
    expect(inspectPackagedArguments([arg]).error).toBeTruthy()
  })
  it.runIf(typeof process.getuid === 'function')('validates fresh private POSIX canonical directories', () => {
    const path = directory()
    const paths = prepareVerificationDirectory(path)
    for (const child of Object.values(paths)) expect(lstatSync(child).mode & 0o777).toBe(0o700)
    expect(() => prepareVerificationDirectory(path)).toThrow('empty')
    const unsafe = directory(); chmodSync(unsafe, 0o755)
    expect(() => prepareVerificationDirectory(unsafe)).toThrow('Unprotected')
    const occupied = directory(); writeFileSync(join(occupied, 'settings.json'), 'must not read')
    expect(() => prepareVerificationDirectory(occupied)).toThrow('empty')
    const alias = `${directory()}-alias`; temporary.push(alias); symlinkSync(occupied, alias)
    expect(() => prepareVerificationDirectory(alias)).toThrow()
  })
})
it('isolated capabilities cannot reach real files, processes, sockets or OS settings', async () => {
  const { platform, client, files, denied } = verificationCapabilities()
  const realFile = join(directory(), 'real-file')
  writeFileSync(realFile, 'unchanged real bytes')
  expect(await platform.readFile(realFile)).toBeNull()
  await platform.writeFileAtomic(realFile, 'memory only')
  expect(files.get(realFile)).toBe('memory only')
  expect(readFileSync(realFile, 'utf8')).toBe('unchanged real bytes')
  await expect(platform.startCore()).rejects.toThrow('forbids Core')
  await expect(platform.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow('forbids')
  await expect(platform.setLaunchAtLogin(true)).rejects.toThrow('forbids')
  await expect(platform.fetchText('https://invalid.invalid', { viaCore: false, userAgent: 'test' })).rejects.toThrow('forbids')
  await expect(client.getConfig()).rejects.toThrow('forbids')
  expect(() => platform.controlChannel()).toThrow('forbids')
  expect(() => client.logs(() => {})).toThrow('forbids')
  expect(await platform.tun!.inspect()).toMatchObject({ state: 'off', availability: 'blocked' })
  expect(denied).toContain('Core start')
})

it('sealed observation-only candidates reject normal launch and retain only the two isolated modes', () => {
  const sealed = { kuroAuthObservationOnly: true, kuroSourceCommit: 'a'.repeat(40) }
  for (const args of [[], ['--hidden'], ['-psn_0_123']]) {
    const launch = inspectPackagedArguments(args)
    expect(() => assertObservationCandidateLaunch(sealed, launch.directory)).toThrow('candidate cannot start normally')
  }
  for (const flag of ['--kuro-runtime-verification=', '--kuro-auth-verification=']) {
    const launch = inspectPackagedArguments([`${flag}/private/temp`])
    expect(launch.error).toBeUndefined()
    expect(() => assertObservationCandidateLaunch(sealed, launch.directory)).not.toThrow()
  }
  for (const metadata of [{}, { kuroAuthObservationOnly: false }]) {
    expect(() => assertObservationCandidateLaunch(metadata)).not.toThrow()
  }
})

it.runIf(typeof process.getuid === 'function')('finite-session candidates isolate persistent data across builds without accepting a caller path', () => {
  const parent = directory()
  const sealed = { kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false, kuroSourceCommit: 'a'.repeat(40) }
  expect(prepareSessionCandidateDirectory({}, parent)).toBeUndefined()
  expect(() => prepareSessionCandidateDirectory({ ...sealed, kuroAuthObservationOnly: true }, parent)).toThrow('sealed')
  const paths = prepareSessionCandidateDirectory(sealed, parent)!
  expect(paths.userData).toBe(join(parent, 'Clash Kuro TUN Candidate', 'userData'))
  writeFileSync(join(paths.userData, 'profile.json'), 'keep this candidate data')
  expect(prepareSessionCandidateDirectory({ ...sealed, kuroSourceCommit: 'b'.repeat(40) }, parent)).toEqual(paths)
  expect(readFileSync(join(paths.userData, 'profile.json'), 'utf8')).toBe('keep this candidate data')
  expect(inspectPackagedArguments(['--user-data-dir=/tmp/other']).error).toBeTruthy()
  chmodSync(paths.userData, 0o755)
  expect(() => prepareSessionCandidateDirectory(sealed, parent)).toThrow('Unprotected')
})

it.runIf(typeof process.getuid === 'function')('finite-session candidate startup preserves unknown markers and refuses linked data directories', () => {
  const parent = directory(), sealed = { kuroCandidateMode: 'finite-session', kuroAuthObservationOnly: false, kuroSourceCommit: 'a'.repeat(40) }
  const paths = prepareSessionCandidateDirectory(sealed, parent)!
  rmSync(paths.sessionData, { recursive: true })
  symlinkSync(paths.userData, paths.sessionData)
  expect(() => prepareSessionCandidateDirectory(sealed, parent)).toThrow('Unprotected')
  const marker = join(parent, 'Clash Kuro TUN Candidate', 'candidate-data.txt')
  writeFileSync(marker, 'unknown')
  expect(() => prepareSessionCandidateDirectory(sealed, parent)).toThrow('Unknown')
  expect(readFileSync(marker, 'utf8')).toBe('unknown')
})

it.runIf(typeof process.getuid !== 'function')('refuses POSIX verification and finite-session data entry on hosts without UID checks', () => {
  const parent = directory()
  expect(() => prepareVerificationDirectory(parent)).toThrow('POSIX ownership')
  expect(() => prepareSessionCandidateDirectory({ kuroCandidateMode: 'finite-session' }, parent)).toThrow('POSIX ownership')
  expect(prepareSessionCandidateDirectory({}, parent)).toBeUndefined()
})
