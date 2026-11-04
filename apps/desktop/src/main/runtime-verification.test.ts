import { afterEach, describe, expect, it } from 'vitest'
import { chmodSync, lstatSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { assertObservationCandidateLaunch, inspectPackagedArguments, prepareVerificationDirectory, safeWebPreferences, verificationCapabilities } from './runtime-verification'

const temporary: string[] = []
function directory() { const path = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-electron-runtime-'))); chmodSync(path, 0o700); temporary.push(path); return path }
afterEach(() => { for (const path of temporary.splice(0)) rmSync(path, { recursive: true, force: true }) })
describe('packaged startup boundary', () => {
  it('allows only fixed app actions and the capability-lowering verification entry', () => {
    expect(inspectPackagedArguments([])).toEqual({})
    expect(inspectPackagedArguments(['--hidden', '-psn_0_123'])).toEqual({})
    expect(inspectPackagedArguments(['--kuro-runtime-verification=/private/temp'])).toEqual({ directory: '/private/temp' })
    expect(safeWebPreferences('fixed')).toEqual({ preload: 'fixed', sandbox: true, contextIsolation: true, nodeIntegration: false, devTools: false })
  })
  it.each(['--remote-debugging-port=0', '--remote-debugging-pipe', '--inspect=0', '--inspect-brk', '--js-flags=evil', '--renderer-cmd-prefix=evil', '--gpu-launcher=evil', '--no-sandbox', '/tmp/evil.js', '--kuro-runtime-verification='])('rejects unsafe argument %s', arg => {
    expect(inspectPackagedArguments([arg]).error).toBeTruthy()
  })
  it('rejects duplicate verification and validates fresh private canonical directories', () => {
    expect(inspectPackagedArguments(['--kuro-runtime-verification=/a', '--kuro-runtime-verification=/b']).error).toBeTruthy()
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
  expect(await platform.readFile('/etc/passwd')).toBeNull()
  await platform.writeFileAtomic('/etc/passwd', 'memory only')
  expect(files.get('/etc/passwd')).toBe('memory only')
  expect(readFileSync('/etc/passwd', 'utf8')).not.toBe('memory only')
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
