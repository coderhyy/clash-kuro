import { EventEmitter } from 'node:events'
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ connect: vi.fn(), lstat: vi.fn() }))
vi.mock('node:net', () => ({ createConnection: mocks.connect }))
vi.mock('node:fs/promises', () => ({ lstat: mocks.lstat }))
import { AUTH_SOCKET, inspectPackagedArguments, parseAuthenticationResponse, requestAuthenticationProbe, runAuthenticationVerification } from './runtime-verification'

class Socket extends EventEmitter {
  end = vi.fn()
  destroy = vi.fn()
}
let socket: Socket
beforeEach(() => {
  vi.useRealTimers()
  socket = new Socket()
  mocks.connect.mockReturnValue(socket)
  mocks.lstat.mockImplementation(async path => ({ uid: 0, mode: 0o755,
    isDirectory: () => path === '/var/run/dev.kuro.tun', isSocket: () => path === AUTH_SOCKET, isSymbolicLink: () => false }))
})
afterEach(() => { vi.clearAllMocks(); vi.useRealTimers() })
async function connected() {
  await vi.waitFor(() => expect(mocks.connect).toHaveBeenCalledOnce())
  socket.emit('connect')
}
it('only accepts one verification mode and retains the existing early argv refusal', () => {
  expect(inspectPackagedArguments(['--kuro-auth-verification=/private/temp'])).toEqual({ directory: '/private/temp', authenticate: true })
  for (const args of [
    ['--kuro-auth-verification='],
    ['--kuro-auth-verification=/a', '--kuro-auth-verification=/b'],
    ['--kuro-auth-verification=/a', '--kuro-runtime-verification=/b'],
    ['--kuro-runtime-verification=/a', '--kuro-auth-verification=/b'],
    ['--kuro-auth-verification=/a', '--remote-debugging-port=0'],
    ['--kuro-auth-verification=/a', '--auth-socket=/tmp/attacker']
  ]) expect(inspectPackagedArguments(args).error).toBeTruthy()
})
it('accepts exactly an authenticated identity envelope with no capability', () => {
  expect(parseAuthenticationResponse('{"version":1,"ok":true,"authenticated":true}\n')).toBe(true)
  expect(parseAuthenticationResponse('{ "authenticated":true, "ok":true, "version":1 }\n')).toBe(true)
  expect(() => parseAuthenticationResponse('{"version":1,"ok":false,"error":"native identity rejected"}\n')).toThrow('native identity rejected')
})
it.each([
  '{"version":1,"ok":true,"authenticated":false}\n',
  '{"version":2,"ok":true,"authenticated":true}\n',
  '{"version":1,"ok":true,"authenticated":true,"token":"bad"}\n',
  '{"version":1,"ok":true,"authenticated":true,"ok":false}\n',
  '{"version":1,"ok":false,"o\\u006b":true,"authenticated":true}\n',
  '{"version":1,"ok":true,"authenticated":true}',
  '{"version":1,\n"ok":true,"authenticated":true}\n',
  '{"version":1,"ok":true,"authenticated":true}\n{}\n'
])('refuses malformed or expanded authentication envelope %s', frame => expect(() => parseAuthenticationResponse(frame)).toThrow())
it('uses only the fixed root endpoint and authenticate operation, even across response chunks', async () => {
  const result = requestAuthenticationProbe()
  await connected()
  expect(mocks.connect).toHaveBeenCalledWith('/var/run/dev.kuro.tun/auth.sock')
  expect(socket.end).toHaveBeenCalledWith('{"version":1,"operation":"authenticate"}\n')
  socket.emit('data', Buffer.from('{"version":1,"ok":true,'))
  socket.emit('data', Buffer.from('"authenticated":true}\n'))
  socket.emit('end')
  await expect(result).resolves.toBe(true)
  expect(socket.destroy).toHaveBeenCalledOnce()
})
it.each(['owner', 'symlink', 'directory-write', 'not-socket'])('rejects untrusted endpoint %s before connecting', async kind => {
  mocks.lstat.mockImplementation(async path => ({ uid: kind === 'owner' ? 501 : 0, mode: kind === 'directory-write' ? 0o777 : 0o755,
    isDirectory: () => path === '/var/run/dev.kuro.tun', isSocket: () => kind !== 'not-socket' && path === AUTH_SOCKET, isSymbolicLink: () => kind === 'symlink' }))
  await expect(requestAuthenticationProbe()).rejects.toThrow('Untrusted')
  expect(mocks.connect).not.toHaveBeenCalled()
})
it.each(['oversize', 'utf8', 'disconnect', 'native-reject', 'socket-error'])('fails closed on %s without retry or other operations', async kind => {
  const result = requestAuthenticationProbe()
  const assertion = expect(result).rejects.toThrow()
  await connected()
  if (kind === 'oversize') socket.emit('data', Buffer.alloc(8193))
  else if (kind === 'disconnect') socket.emit('close')
  else if (kind === 'socket-error') socket.emit('error', new Error('connection refused'))
  else {
    socket.emit('data', kind === 'utf8' ? Buffer.from([0xff]) : Buffer.from('{"version":1,"ok":false,"error":"native refused"}\n'))
    socket.emit('end')
  }
  await assertion
  expect(mocks.connect).toHaveBeenCalledOnce()
  expect(socket.end).toHaveBeenCalledTimes(1)
})
it('bounds an unanswered authentication request', async () => {
  vi.useFakeTimers()
  const result = requestAuthenticationProbe()
  const assertion = expect(result).rejects.toThrow('timed out')
  await vi.advanceTimersByTimeAsync(2000)
  await assertion
  expect(socket.destroy).toHaveBeenCalledOnce()
})
it.each([true, false])('writes only an auth report and exits without constructing UI/Platform (authenticated=%s)', async authenticated => {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-electron-runtime-')))
  chmodSync(directory, 0o700)
  const app = { getPath: vi.fn(name => join(directory, name)), exit: vi.fn() }
  try {
    const result = runAuthenticationVerification({ app, directory })
    await connected()
    socket.emit('data', Buffer.from(authenticated ? '{"version":1,"ok":true,"authenticated":true}\n' : '{"version":1,"ok":false,"error":"native refused"}\n'))
    socket.emit('end')
    await result
    const report = JSON.parse(readFileSync(join(directory, 'result.json'), 'utf8'))
    expect(report).toMatchObject({ mode: 'authenticate-only', authenticated, nativeRejected: !authenticated, ok: authenticated, endpoint: AUTH_SOCKET,
      directory, userData: join(directory, 'userData'), sessionData: join(directory, 'sessionData'),
      realPlatformCreated: false, realCoreStarted: false, systemNetworkWrites: false })
    expect(app.exit).toHaveBeenCalledWith(authenticated ? 0 : 1)
    expect(socket.end).toHaveBeenCalledTimes(1)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

it('distinguishes a missing service from a structured native rejection', async () => {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-electron-runtime-')))
  const app = { getPath: vi.fn(name => join(directory, name)), exit: vi.fn() }
  mocks.lstat.mockRejectedValueOnce(new Error('ENOENT endpoint absent'))
  try {
    await runAuthenticationVerification({ app, directory })
    expect(JSON.parse(readFileSync(join(directory, 'result.json'), 'utf8'))).toMatchObject({ authenticated: false, nativeRejected: false, error: 'ENOENT endpoint absent' })
    expect(mocks.connect).not.toHaveBeenCalled()
    expect(app.exit).toHaveBeenCalledWith(1)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})
