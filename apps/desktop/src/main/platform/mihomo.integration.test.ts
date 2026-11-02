import { existsSync } from 'node:fs'
import { chmod, copyFile, lstat, mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { createServer as createHttpServer, request } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { createDesktopPlatform, createResumeHandler, createSocketTransport } from './index'

const corePath = join(import.meta.dirname, '../../../resources/core', `${process.platform}-${process.arch}`, process.platform === 'win32' ? 'mihomo.exe' : 'mihomo')

test.skipIf(!existsSync(corePath) && process.env.KURO_REQUIRE_CORE !== '1')('bundled mihomo validates config, streams traffic/logs and reconnects after channel rotation', async () => {
  expect(existsSync(corePath), 'Run scripts/fetch-core.mjs for this host before integration tests').toBe(true)
  const dataDir = await mkdtemp(join(process.platform === 'win32' ? tmpdir() : '/tmp', 'kuro-mihomo-'))
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  const mixedPort = address.port
  await new Promise<void>((resolve) => server.close(() => resolve()))
  let testCorePath = corePath
  if (process.platform !== 'win32' && (await lstat(corePath)).mode & 0o6000) {
    // The development app's setuid Core creates root-owned sockets; never alter that installed binary.
    testCorePath = join(dataDir, 'mihomo')
    await copyFile(corePath, testCorePath)
    await chmod(testCorePath, 0o700)
  }
  const platform = createDesktopPlatform({ dataDir, corePath: testCorePath, mixedPort })
  const channel = platform.controlChannel()
  const directive = channel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe'
  const endpoint = channel.kind === 'unix' ? channel.path : channel.name
  const yaml = `mixed-port: ${mixedPort}\nallow-lan: false\nmode: direct\nlog-level: info\n${directive}: ${JSON.stringify(endpoint)}\n`
  const origin = createHttpServer((_req, res) => res.end('local test origin'))
  await new Promise<void>((resolve, reject) => origin.once('error', reject).listen(0, '127.0.0.1', resolve))
  const originAddress = origin.address()
  if (!originAddress || typeof originAddress === 'string') throw new Error('Missing origin port')
  // Generate only loopback traffic; do not depend on external connectivity or the user's System Proxy.
  const stimulate = () => {
    const req = request({ host: '127.0.0.1', port: mixedPort, path: `http://127.0.0.1:${originAddress.port}/`, agent: false }, res => res.resume())
    req.setTimeout(500, () => req.destroy())
    req.on('error', () => {})
    req.end()
  }
  const transport = createSocketTransport(() => platform.controlChannel())
  const stream = async (path: string, keys: string[]) => new Promise<void>((resolve, reject) => {
    const clear = () => { clearTimeout(timer); clearInterval(traffic); handle.close() }
    const timer = setTimeout(() => { clear(); reject(new Error(`${path} stream timed out`)) }, 5_000)
    const traffic = setInterval(stimulate, 100)
    const handle = transport.stream(path, (data) => {
      try { for (const key of keys) expect(data).toHaveProperty(key); clear(); resolve() }
      catch (error) { clear(); reject(error) }
    }, (error) => { if (error) { clear(); reject(error) } })
  })
  try {
    expect(await platform.applyRuntimeConfig(yaml)).toEqual({ ok: true })
    expect((await platform.applyRuntimeConfig('mixed-port: [\n')).ok).toBe(false)
    expect(await platform.readFile('runtime.yaml')).toBe(yaml)
    await platform.startCore()
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
    await resume()
    await Promise.all([stream('/traffic', ['up', 'down']), stream('/logs?level=info', ['type', 'payload'])])
    await platform.stopCore()
    expect(await platform.isCoreRunning()).toBe(false)
    expect(await platform.readFile('core.pid')).toBeNull()
    await resume()
    expect(await platform.isCoreRunning()).toBe(true)
    if (channel.kind === 'pipe') expect(platform.controlChannel()).not.toEqual(channel)
    expect((await transport.request({ method: 'GET', path: '/version' })).status).toBe(200)
    await Promise.all([stream('/traffic', ['up', 'down']), stream('/logs?level=info', ['type', 'payload'])])
  } finally {
    await platform.stopCore()
    origin.closeAllConnections()
    await new Promise<void>((resolve) => origin.close(() => resolve()))
    await rm(dataDir, { force: true, recursive: true, maxRetries: 10, retryDelay: 20 })
  }
}, 20_000)
