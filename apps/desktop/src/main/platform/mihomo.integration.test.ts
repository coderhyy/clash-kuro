import { existsSync } from 'node:fs'
import { chmod, copyFile, lstat, mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { createDesktopPlatform, createResumeHandler, createSocketTransport } from './index'

const corePath = '/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo'

test.skipIf(!existsSync(corePath) || process.platform !== 'darwin')('real mihomo validates config, starts on unix socket, streams and stops', async () => {
  const dataDir = await mkdtemp('/tmp/kuro-mihomo-')
  const server = createServer()
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('Missing port')
  const mixedPort = address.port
  await new Promise<void>((resolve) => server.close(() => resolve()))
  let testCorePath = corePath
  if ((await lstat(corePath)).mode & 0o6000) {
    // The development app's setuid Core creates root-owned sockets; never alter that installed binary.
    testCorePath = join(dataDir, 'mihomo')
    await copyFile(corePath, testCorePath)
    await chmod(testCorePath, 0o700)
  }
  const platform = createDesktopPlatform({ dataDir, corePath: testCorePath, mixedPort })
  const channel = platform.controlChannel()
  if (channel.kind !== 'unix') throw new Error('Expected unix socket')
  const yaml = `mixed-port: ${mixedPort}\nmode: direct\nexternal-controller-unix: ${JSON.stringify(channel.path)}\n`
  try {
    expect(await platform.applyRuntimeConfig(yaml)).toEqual({ ok: true })
    expect((await platform.applyRuntimeConfig('mixed-port: [\n')).ok).toBe(false)
    expect(await platform.readFile('runtime.yaml')).toBe(yaml)
    await platform.startCore()
    expect(await platform.isCoreRunning()).toBe(true)
    expect((await lstat(channel.path)).mode & 0o777).toBe(0o600)
    const transport = createSocketTransport(channel)
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
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { handle.close(); reject(new Error('Traffic stream timed out')) }, 5_000)
      const handle = transport.stream('/traffic', (data) => {
        try {
          expect(data).toHaveProperty('up')
          expect(data).toHaveProperty('down')
          clearTimeout(timer)
          handle.close()
          resolve()
        } catch (error) { clearTimeout(timer); handle.close(); reject(error) }
      }, (error) => { if (error) { clearTimeout(timer); reject(error) } })
    })
    await platform.stopCore()
    expect(await platform.isCoreRunning()).toBe(false)
    expect(await platform.readFile('core.pid')).toBeNull()
    await resume()
    expect(await platform.isCoreRunning()).toBe(true)
  } finally {
    await platform.stopCore()
    await rm(dataDir, { force: true, recursive: true })
  }
}, 20_000)
