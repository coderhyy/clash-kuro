import { EventEmitter } from 'node:events'
import { beforeEach, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ lstat: vi.fn(), connect: vi.fn() }))
vi.mock('node:fs/promises', () => ({ lstat: mocks.lstat }))
vi.mock('node:net', () => ({ createConnection: mocks.connect }))
import { AUTH_SOCKET, TUN_CONTROL_SOCKET, TUN_RUN_DIRECTORY, assertTrustedTunEndpoint } from './tun-endpoints'
import { createMacosTun, requestTunHelper } from './platform/macos-tun'

const directories = ['/', '/Library', '/Library/PrivilegedHelperTools', TUN_RUN_DIRECTORY]
function metadata(path: string) {
  return { uid: 0, nlink: 1, mode: directories.includes(path) ? 0o755 : 0o666,
    isDirectory: () => directories.includes(path), isSocket: () => path === AUTH_SOCKET || path === TUN_CONTROL_SOCKET,
    isSymbolicLink: () => false }
}
beforeEach(() => {
  mocks.lstat.mockReset()
  mocks.connect.mockReset()
  mocks.lstat.mockImplementation(async path => {
    if (!directories.includes(path) && path !== AUTH_SOCKET && path !== TUN_CONTROL_SOCKET) throw Object.assign(new Error('missing'), { code: 'ENOENT' })
    return metadata(path)
  })
})

it.each([AUTH_SOCKET, TUN_CONTROL_SOCKET])('ordinary users can traverse root-owned search-only directories and connect to writable sockets: %s', async endpoint => {
  mocks.lstat.mockImplementation(async path => ({ ...metadata(path), mode: directories.includes(path) ? 0o711 : 0o622 }))
  await expect(assertTrustedTunEndpoint(endpoint)).resolves.toBeUndefined()
  expect(mocks.lstat.mock.calls.map(([path]) => path)).toEqual([...directories, endpoint])
})
it.each(directories.flatMap(path => ['writable', 'symlink', 'owner', 'not-directory', 'no-other-search', 'setgid'].map(kind => [path, kind])))('refuses unsafe ancestor %s (%s)', async (target, kind) => {
  mocks.lstat.mockImplementation(async path => path !== target ? metadata(path) : {
    ...metadata(path), uid: kind === 'owner' ? 501 : 0,
    mode: kind === 'writable' ? 0o775 : kind === 'no-other-search' ? 0o750 : kind === 'setgid' ? 0o2755 : 0o755,
    isDirectory: () => kind !== 'not-directory', isSymbolicLink: () => kind === 'symlink'
  })
  await expect(assertTrustedTunEndpoint(AUTH_SOCKET)).rejects.toThrow('Untrusted')
})
it.each(['owner', 'symlink', 'not-socket', 'hardlink', 'owner-only', 'group-only', 'setgid'])('refuses unusable or untrusted socket %s', async kind => {
  mocks.lstat.mockImplementation(async path => path !== AUTH_SOCKET ? metadata(path) : {
    ...metadata(path), uid: kind === 'owner' ? 501 : 0, nlink: kind === 'hardlink' ? 2 : 1,
    mode: kind === 'owner-only' ? 0o600 : kind === 'group-only' ? 0o660 : kind === 'setgid' ? 0o2666 : 0o666,
    isSocket: () => kind !== 'not-socket', isSymbolicLink: () => kind === 'symlink'
  })
  await expect(assertTrustedTunEndpoint(AUTH_SOCKET)).rejects.toThrow('Untrusted')
})
it('refuses alternate endpoints without reading them', async () => {
  await expect(assertTrustedTunEndpoint('/tmp/auth.sock')).rejects.toThrow('Untrusted')
  expect(mocks.lstat).not.toHaveBeenCalled()
})
it('control adapter validates the shared fixed endpoint before its status request', async () => {
  const request = vi.fn(async () => ({ availability: 'ready' as const, state: 'off' as const }))
  await expect(createMacosTun({ request }).inspect()).resolves.toEqual({ availability: 'ready', state: 'off' })
  expect(mocks.lstat).toHaveBeenCalledWith(TUN_CONTROL_SOCKET)
  expect(request).toHaveBeenCalledExactlyOnceWith('status')
})
it('control adapter refuses a writable ancestor without sending a request', async () => {
  const request = vi.fn()
  mocks.lstat.mockImplementation(async path => ({ ...metadata(path), mode: path === '/Library' ? 0o777 : metadata(path).mode }))
  await expect(createMacosTun({ request }).inspect()).resolves.toMatchObject({ availability: 'blocked', state: 'unknown' })
  expect(request).not.toHaveBeenCalled()
})
it('a retained legacy run directory cannot become silently not-installed/off', async () => {
  mocks.lstat.mockImplementation(async path => {
    if (path === '/var/run/dev.kuro.tun') return { ...metadata(path), mode: 0o755, isDirectory: () => true }
    if (path === TUN_RUN_DIRECTORY || path === TUN_CONTROL_SOCKET) throw Object.assign(new Error('new endpoint missing'), { code: 'ENOENT' })
    if (directories.includes(path)) return metadata(path)
    throw Object.assign(new Error('missing'), { code: 'ENOENT' })
  })
  const request = vi.fn()
  await expect(createMacosTun({ request }).inspect()).resolves.toMatchObject({ availability: 'blocked', state: 'unknown' })
  expect(request).not.toHaveBeenCalled()
})
it('default control transport connects only to the migrated fixed socket', async () => {
  const socket = Object.assign(new EventEmitter(), { end: vi.fn(), destroy: vi.fn() })
  mocks.connect.mockReturnValue(socket)
  const result = requestTunHelper('status')
  expect(mocks.connect).toHaveBeenCalledExactlyOnceWith(TUN_CONTROL_SOCKET)
  socket.emit('connect')
  expect(socket.end).toHaveBeenCalledWith('{"version":1,"operation":"status"}\n')
  socket.emit('data', Buffer.from('{"version":1,"ok":true,"status":{"availability":"ready","state":"off"}}\n'))
  socket.emit('end')
  await expect(result).resolves.toEqual({ availability: 'ready', state: 'off' })
})
