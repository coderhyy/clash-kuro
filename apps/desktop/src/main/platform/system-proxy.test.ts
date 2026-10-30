import { describe, expect, test, vi } from 'vitest'
import { createSystemProxy, SystemProxyPermissionError, type Exec } from './system-proxy'

function fixture() {
  const states = new Map([
    ['Wi-Fi:web', 'Enabled: Yes\nServer: 127.0.0.1\nPort: 17890\nAuthenticated Proxy Enabled: 0'],
    ['Wi-Fi:secure', 'Enabled: Yes\nServer: corporate.proxy\nPort: 8080'],
    ['USB Ethernet:web', 'Enabled: No\nServer: 127.0.0.1\nPort: 17890'],
    ['USB Ethernet:secure', 'Enabled: Yes\nServer: 127.0.0.1\nPort: 17890'],
  ])
  const exec = vi.fn<Exec>(async (_file, args) => {
    let stdout = ''
    if (args[0] === '-listallnetworkservices') stdout = 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Disabled VPN\nUSB Ethernet\n'
    if (args[0] === '-getwebproxy') stdout = states.get(`${args[1]}:web`)!
    if (args[0] === '-getsecurewebproxy') stdout = states.get(`${args[1]}:secure`)!
    if (args[0] === '-getproxybypassdomains') stdout = 'localhost\n*.local\n'
    return { stdout, stderr: '' }
  })
  return { exec, proxy: createSystemProxy({ os: 'darwin', exec }) }
}

test('sets HTTP, HTTPS and bypass on every enabled service without shell interpolation', async () => {
  const { exec, proxy } = fixture()
  await proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: ['localhost', '*.local'] })
  for (const service of ['Wi-Fi', 'USB Ethernet']) {
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setwebproxy', service, '127.0.0.1', '17890'])
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setsecurewebproxy', service, '127.0.0.1', '17890'])
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setproxybypassdomains', service, 'localhost', '*.local'])
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setwebproxystate', service, 'on'])
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setsecurewebproxystate', service, 'on'])
  }
  expect(exec.mock.calls.flat(2)).not.toContain('*Disabled VPN')
})

test('reads current proxy and clears empty bypass with networksetup Empty', async () => {
  const { exec, proxy } = fixture()
  expect(await proxy.getSystemProxy()).toEqual({ host: '127.0.0.1', port: 17890, bypass: ['localhost', '*.local'] })
  await proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: [] })
  expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setproxybypassdomains', 'Wi-Fi', 'Empty'])
})

test('stale cleanup disables only the matching protocol, host and port', async () => {
  const { exec, proxy } = fixture()
  await proxy.cleanupStaleSystemProxy(17890)
  expect(exec.mock.calls.filter(([, args]) => args[0]?.startsWith('-set')).map(([, args]) => args)).toEqual([
    ['-setwebproxystate', 'Wi-Fi', 'off'], ['-setsecurewebproxystate', 'USB Ethernet', 'off'],
  ])
  exec.mockClear()
  await proxy.cleanupStaleSystemProxy(17891)
  expect(exec.mock.calls.filter(([, args]) => args[0]?.startsWith('-set'))).toEqual([])
})

test('clear disables both protocols on all enabled services', async () => {
  const { exec, proxy } = fixture()
  await proxy.clearSystemProxy()
  expect(exec.mock.calls.filter(([, args]) => args[0]?.startsWith('-set'))).toHaveLength(4)
})

test('returns null when no proxy is enabled', async () => {
  const proxy = createSystemProxy({ os: 'darwin', exec: async (_file, args) => ({
    stdout: args[0] === '-listallnetworkservices' ? 'Wi-Fi' : 'Enabled: No\nServer: 127.0.0.1\nPort: 7890', stderr: '',
  }) })
  expect(await proxy.getSystemProxy()).toBeNull()
})

test('network service and proxy host names are not mistaken for permission/error messages', async () => {
  const proxy = createSystemProxy({ os: 'darwin', exec: async (_file, args) => ({
    stdout: args[0] === '-listallnetworkservices' ? 'Administrator Permission Wi-Fi'
      : args[0] === '-getproxybypassdomains' ? "There aren't any bypass domains set on this service."
        : 'Enabled: Yes\nServer: error.proxy.test\nPort: 8080',
    stderr: '',
  }) })
  expect(await proxy.getSystemProxy()).toEqual({ host: 'error.proxy.test', port: 8080, bypass: [] })
})

test('clear continues through every service after a permission failure', async () => {
  const { exec, proxy } = fixture()
  const original = exec.getMockImplementation()!
  exec.mockImplementation(async (file, args) => {
    if (args[0] === '-setwebproxystate' && args[1] === 'Wi-Fi') throw new Error('Permission denied')
    return original(file, args)
  })
  await expect(proxy.clearSystemProxy()).rejects.toBeInstanceOf(SystemProxyPermissionError)
  expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setsecurewebproxystate', 'USB Ethernet', 'off'])
})

describe('recognizable errors and validation', () => {
  test.each(['Permission denied', 'You must be root to use this command', 'not authorized', 'requires administrator authorization'])('%s', async (message) => {
    const proxy = createSystemProxy({ os: 'darwin', exec: async () => ({ stdout: message, stderr: '' }) })
    await expect(proxy.getSystemProxy()).rejects.toBeInstanceOf(SystemProxyPermissionError)
  })
  test('recognizes stderr on rejected exec calls and rolls back partial writes', async () => {
    const { exec, proxy } = fixture()
    const original = exec.getMockImplementation()!
    exec.mockImplementation(async (file, args) => {
      if (args[0] === '-setsecurewebproxy') throw Object.assign(new Error('exit 1'), { stderr: 'Operation not permitted' })
      return original(file, args)
    })
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: [] })).rejects.toBeInstanceOf(SystemProxyPermissionError)
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setwebproxystate', 'Wi-Fi', 'off'])
    expect(exec).toHaveBeenCalledWith('/usr/sbin/networksetup', ['-setsecurewebproxystate', 'Wi-Fi', 'off'])
  })
  test('rejects invalid settings before invoking exec', async () => {
    const { exec, proxy } = fixture()
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 0, bypass: [] })).rejects.toThrow('Invalid')
    expect(exec).not.toHaveBeenCalled()
  })
  test('Windows deliberately fails without invoking any command', async () => {
    const exec = vi.fn<Exec>()
    const proxy = createSystemProxy({ os: 'win32', exec })
    await expect(proxy.getSystemProxy()).rejects.toThrow('not implemented')
    await expect(proxy.clearSystemProxy()).rejects.toThrow('not implemented')
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow('not implemented')
    await expect(proxy.cleanupStaleSystemProxy(7890)).rejects.toThrow('not implemented')
    expect(exec).not.toHaveBeenCalled()
  })
})
