import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, copyFile, lstat, mkdtemp, readFile, realpath, rm } from 'node:fs/promises'
import { createServer as createHttpServer, request } from 'node:http'
import { tmpdir } from 'node:os'
import { isAbsolute, join, relative, sep } from 'node:path'
import { expect, test } from 'vitest'
import { createDesktopPlatform, createResumeHandler, createSocketTransport } from './index'
import { startResidentSession } from './resident-session'
import { reserveTestPort } from './test-ports'
import { execCommand } from './system-proxy'

const corePath = join(import.meta.dirname, '../../../resources/core', `${process.platform}-${process.arch}`, process.platform === 'win32' ? 'mihomo.exe' : 'mihomo')

test.skipIf(!existsSync(corePath) && process.env.KURO_REQUIRE_CORE !== '1')('bundled mihomo validates config, streams traffic/logs and reconnects after channel rotation', async ({ onTestFinished }) => {
  expect(existsSync(corePath), 'Run scripts/fetch-core.mjs for this host before integration tests').toBe(true)
  const reservation = await reserveTestPort()
  const mixedPort = reservation.port
  const releasePort = reservation.release
  onTestFinished(releasePort)
  const dataDir = await realpath(await mkdtemp(join(process.platform === 'win32' ? tmpdir() : '/tmp', 'kuro-mihomo-')))
  let testCorePath = corePath
  if (process.platform !== 'win32' && (await lstat(corePath)).mode & 0o6000) {
    // The development app's setuid Core creates root-owned sockets; never alter that installed binary.
    testCorePath = join(dataDir, 'mihomo')
    await copyFile(corePath, testCorePath)
    await chmod(testCorePath, 0o700)
  }
  const fakeResident = process.env.KURO_RESIDENT_FAKE
  let nativeOwner: Awaited<ReturnType<typeof startResidentSession>> | undefined
  let recoveryDirectory: string | undefined
  let nativeStarts = 0
  const receiptDigest = '1'.repeat(64), evidenceDigest = '2'.repeat(64)
  if (fakeResident) {
    expect(process.platform).toBe('win32')
    expect(fakeResident).toBe(join(import.meta.dirname, '../../../../../.scratch/mvp/prototypes/prestarted-helper-deadline/out/admission-fake.exe'))
    expect(existsSync(fakeResident)).toBe(true)
    const root = process.env.KURO_ADMISSION_TEST_ROOT
    if (!root || !isAbsolute(root)) throw new Error('Native owner fixture requires a private absolute temp recovery root')
    recoveryDirectory = await realpath(root)
    expect(recoveryDirectory.toLowerCase()).toBe(root.toLowerCase())
    const child = relative(await realpath(tmpdir()), recoveryDirectory)
    expect(child).toContain('kuro-admission-')
    expect(child && child !== '..' && !child.startsWith(`..${sep}`) && !isAbsolute(child)).toBeTruthy()
    expect(process.env.KURO_ADMISSION_TEST_NAMESPACE).toMatch(/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/)
    expect(process.env.KURO_ADMISSION_TEST_MODE ?? '').toBe('')
  }
  let coreOutput = ''
  const platform = createDesktopPlatform({ dataDir, corePath: testCorePath, mixedPort,
    sysproxyHelperPath: join(dataDir, 'fake-sysproxy.exe'),
    exec: async (file, args) => {
      if (file === testCorePath) return execCommand(file, args)
      // Real Core/transport test, never a real system-proxy test on the developer's machine.
      expect([join(dataDir, 'fake-sysproxy.exe'), '/usr/sbin/networksetup']).toContain(file)
      return { stdout: args[0] === 'clear' ? JSON.stringify({ command: 'clear', ok: true, connections: [] }) : '', stderr: '' }
    },
    spawn: (file, args, options) => {
      const child = spawn(file, args, options)
      const recordOutput = (chunk: Buffer) => { coreOutput = (coreOutput + chunk.toString()).slice(-8192) }
      child.stdout?.on('data', recordOutput)
      child.stderr?.on('data', recordOutput)
      return child
    },
    ...(fakeResident ? { sysproxyHelperPath: fakeResident, startResident: async (options: Parameters<typeof startResidentSession>[0]) => {
      nativeOwner = await startResidentSession({ ...options, recoveryDirectory: recoveryDirectory! })
      expect(createHash('sha256').update(await readFile(nativeOwner.helper)).digest('hex')).toBe(createHash('sha256').update(await readFile(fakeResident)).digest('hex'))
      nativeStarts++
      return nativeOwner
    } } : {}),
  })
  const channel = platform.controlChannel()
  const directive = channel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe'
  const endpoint = channel.kind === 'unix' ? channel.path : channel.name
  const yaml = `mixed-port: ${mixedPort}\nallow-lan: false\nmode: direct\nlog-level: info\n${directive}: ${JSON.stringify(endpoint)}\n`
  let originHits = 0
  const origin = createHttpServer((_req, res) => { originHits++; res.end('local test origin') })
  await new Promise<void>((resolve, reject) => origin.once('error', reject).listen(0, '127.0.0.1', resolve))
  const originAddress = origin.address()
  if (!originAddress || typeof originAddress === 'string') throw new Error('Missing origin port')
  // Generate only loopback traffic; do not depend on external connectivity or the user's System Proxy.
  const trafficEvidence: string[] = []
  const record = (value: string) => { trafficEvidence.push(value); if (trafficEvidence.length > 5) trafficEvidence.shift() }
  let originResponses = 0
  const originChecks = new Set<() => void>()
  const stimulate = () => {
    // Core routes by Host, which must name the origin even when connecting to the proxy.
    const req = request({ host: '127.0.0.1', port: mixedPort, path: `http://127.0.0.1:${originAddress.port}/`, headers: { host: `127.0.0.1:${originAddress.port}` }, agent: false }, res => {
      let body = ''
      res.on('data', chunk => { body = (body + String(chunk)).slice(0, 256) })
      res.once('end', () => {
        record(`HTTP ${res.statusCode}: ${body}`)
        if (res.statusCode === 200 && body === 'local test origin') {
          originResponses++
          for (const check of [...originChecks]) check()
        }
      })
    })
    req.setTimeout(500, () => req.destroy())
    req.on('error', error => record(error.message))
    req.end()
  }
  const transport = createSocketTransport(() => platform.controlChannel())
  const stream = async (path: string, keys: string[]) => new Promise<void>((resolve, reject) => {
    const previousResponses = originResponses
    let frameReceived = false
    const clear = () => { clearTimeout(timer); clearInterval(traffic); handle.close(); originChecks.delete(checkOrigin) }
    const checkOrigin = () => { if (frameReceived && originResponses > previousResponses) { clear(); resolve() } }
    const timer = setTimeout(() => { clear(); reject(new Error(`${path} stream timed out; originHits=${originHits}; traffic=${trafficEvidence.join(', ')}`)) }, 5_000)
    const traffic = setInterval(stimulate, 100)
    const handle = transport.stream(path, (data) => {
      try { for (const key of keys) expect(data).toHaveProperty(key); frameReceived = true; checkOrigin() }
      catch (error) { clear(); reject(error) }
    }, (error) => { if (error) { clear(); reject(error) } })
    originChecks.add(checkOrigin)
  })
  let failure: unknown
  let phase = 'config'
  try {
    expect(originAddress.port, 'Origin must use a different port from Core').not.toBe(mixedPort)
    expect(await platform.applyRuntimeConfig(yaml)).toEqual({ ok: true })
    expect((await platform.applyRuntimeConfig('mixed-port: [\n')).ok).toBe(false)
    expect(await platform.readFile('runtime.yaml')).toBe(yaml)
    phase = 'initial-start'
    await releasePort()
    await platform.startCore()
    if (fakeResident) await platform.setSystemProxy({ host: '127.0.0.1', port: mixedPort, bypass: [] })
    expect(await platform.isCoreRunning()).toBe(true)
    if (channel.kind === 'unix') expect((await lstat(channel.path)).mode & 0o777).toBe(0o600)
    const version = await transport.request({ method: 'GET', path: '/version' })
    expect(version.status).toBe(200)
    expect(version.body).toHaveProperty('version')
    const resume = createResumeHandler({
      platform,
      closeAllConnections: async () => {
        expect((await transport.request({ method: 'DELETE', path: '/connections' })).status).toBe(204)
      },
      reapplySystemProxy: async () => {},
    })
    phase = 'live-resume'
    await resume()
    phase = 'first-streams'
    await Promise.all([stream('/traffic', ['up', 'down']), stream('/logs?level=info', ['type', 'payload'])])
    expect(originResponses, 'Traffic must return the local origin response through Core').toBeGreaterThan(0)
    phase = 'stop-before-restart'
    await platform.stopCore()
    expect(await platform.isCoreRunning()).toBe(false)
    expect(await platform.readFile('core.pid')).toBeNull()
    phase = 'restart'
    await resume()
    expect(await platform.isCoreRunning()).toBe(true)
    if (fakeResident) await platform.setSystemProxy({ host: '127.0.0.1', port: mixedPort, bypass: [] })
    if (channel.kind === 'pipe') expect(platform.controlChannel()).not.toEqual(channel)
    expect((await transport.request({ method: 'GET', path: '/version' })).status).toBe(200)
    phase = 'second-streams'
    const previousResponses = originResponses
    await Promise.all([stream('/traffic', ['up', 'down']), stream('/logs?level=info', ['type', 'payload'])])
    expect(originResponses, 'Restarted Core must return a new local origin response').toBeGreaterThan(previousResponses)
    if (fakeResident) {
      expect(nativeStarts).toBe(2)
      // Test-entry trigger only: model native completion preceding Electron's shutdown callback.
      await nativeOwner!.close()
      expect(await platform.isCoreRunning()).toBe(false)
      const closing = platform.shutdown({ timeoutMs: 2500 })
      expect(platform.shutdown({ timeoutMs: 9000 })).toBe(closing)
      await closing
      await expect(platform.setSystemProxy({ host: '127.0.0.1', port: mixedPort, bypass: [] })).rejects.toThrow()
    }
  } catch (error) {
    failure = new Error(`Core integration failed at ${phase}; mixedPort=${mixedPort}; originPort=${originAddress.port}; originHits=${originHits}; originResponses=${originResponses}; traffic=${trafficEvidence.join(', ')}; coreOutput=${coreOutput}${nativeOwner?.diagnostics() ?? ''}`, { cause: error })
    throw failure
  } finally {
    let stopError: unknown
    try { await platform.stopCore() } catch (error) { stopError = error }
    origin.closeAllConnections()
    await new Promise<void>((resolve) => origin.close(() => resolve()))
    if (stopError) throw new AggregateError(failure ? [failure, stopError] : [stopError], `Core stop unverified; retained fixture ${dataDir}`)
    await rm(dataDir, { force: true, recursive: true, maxRetries: 10, retryDelay: 20 })
  }
}, 20_000)
