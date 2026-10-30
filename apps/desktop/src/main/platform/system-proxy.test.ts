import { describe, expect, test, vi } from 'vitest'
import { createSystemProxy, parseWindowsProxyServer, SystemProxyPermissionError, SystemProxyUnknownStateError, type Exec } from './system-proxy'

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
  test('Linux deliberately fails without invoking any command', async () => {
    const exec = vi.fn<Exec>()
    const proxy = createSystemProxy({ os: 'linux', exec })
    await expect(proxy.getSystemProxy()).rejects.toThrow('not implemented')
    expect(exec).not.toHaveBeenCalled()
  })
})

describe('Windows helper', () => {
  const helperPath = 'C:\\Kuro\\resources\\bin\\kuro-sysproxy.exe'
  const ok = (body: object) => ({ stdout: JSON.stringify({ ok: true, ...body }), stderr: '' })
  function win(exec: Exec, remembered: string | null = null, port = 7890) {
    const saved: (string | null)[] = []
    const memory = { load: vi.fn(async () => remembered), save: vi.fn(async (server: string | null) => { saved.push(server); remembered = server }) }
    return { proxy: createSystemProxy({ os: 'win32', exec, helperPath, mixedPort: () => port, memory }), saved, memory }
  }

  test('set passes argv (no shell string), remembers the endpoint first', async () => {
    const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [{ name: null, status: 'set' }, { name: '公司 VPN', status: 'set' }] }))
    const { proxy, saved } = win(exec)
    await proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: ['localhost', '127.0.0.1', '::1'] })
    // Bare ::1 makes WinINet reject the whole list (measured: error 87); it must be bracketed.
    expect(exec).toHaveBeenCalledWith(helperPath, ['set', '--host', '127.0.0.1', '--port', '17890', '--bypass', 'localhost;127.0.0.1;[::1]'])
    expect(saved).toEqual(['127.0.0.1:17890'])
  })

  test('get reports the LAN manual proxy and ignores PAC-only or foreign mixed endpoints', async () => {
    const responses = [
      { flags: 3, proxyServer: 'http=127.0.0.1:7890;https=127.0.0.1:7890', bypass: 'localhost;<local>' },
      { flags: 5, proxyServer: null, autoConfigUrl: 'http://wpad/wpad.dat' },
      { flags: 3, proxyServer: 'http=127.0.0.1:7890;https=corp:8080' },
    ]
    const exec = vi.fn<Exec>(async () => ok({ command: 'get', connections: [{ name: null, ...responses.shift() }] }))
    const { proxy } = win(exec)
    expect(await proxy.getSystemProxy()).toEqual({ host: '127.0.0.1', port: 7890, bypass: ['localhost', '<local>'] })
    expect(await proxy.getSystemProxy()).toBeNull()
    expect(await proxy.getSystemProxy()).toBeNull()
    expect(exec).toHaveBeenCalledWith(helperPath, ['get'])
  })

  test('clear asks the helper for the remembered old port and the current port, then forgets', async () => {
    const exec = vi.fn<Exec>(async () => ok({ command: 'clear', connections: [{ name: null, status: 'cleared' }] }))
    const { proxy, saved } = win(exec, '127.0.0.1:7890', 7891)
    await proxy.clearSystemProxy()
    expect(exec).toHaveBeenCalledWith(helperPath, ['clear', '--expected-server', '127.0.0.1:7890', '--expected-server', '127.0.0.1:7891'])
    expect(saved).toEqual([null])
  })

  test('stale cleanup includes the port from settings.json', async () => {
    const exec = vi.fn<Exec>(async () => ok({ command: 'clear', connections: [] }))
    const { proxy } = win(exec, null, 7890)
    await proxy.cleanupStaleSystemProxy(17890)
    expect(exec).toHaveBeenCalledWith(helperPath, ['clear', '--expected-server', '127.0.0.1:17890', '--expected-server', '127.0.0.1:7890'])
  })

  test('partial set failure (exit 2 with JSON) rolls back and reports per connection', async () => {
    const exec = vi.fn<Exec>(async (_file, args) => {
      if (args[0] === 'clear') return ok({ command: 'clear', connections: [] })
      throw Object.assign(new Error('Command failed'), { code: 2, stdout: JSON.stringify({
        ok: false, command: 'set', connections: [{ name: null, status: 'set' }, { name: 'VPN', status: 'error', error: { code: 5, message: 'Access is denied.' } }],
      }) })
    })
    const { proxy } = win(exec)
    const error = await proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] }).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(SystemProxyPermissionError)
    expect((error as Error).message).toMatch(/VPN: Access is denied.*127\.0\.0\.1:7890/s)
    expect(exec).toHaveBeenLastCalledWith(helperPath, ['clear', '--expected-server', '127.0.0.1:7890'])
  })

  test('a helper blocked by security software surfaces a manual-setting hint, not a registry fallback', async () => {
    const exec = vi.fn<Exec>(async () => { throw Object.assign(new Error('spawn EPERM'), { code: 'EPERM' }) })
    const { proxy } = win(exec)
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow(/手动设置 127\.0\.0\.1:7890/)
    await expect(proxy.getSystemProxy()).rejects.toBeInstanceOf(SystemProxyPermissionError)
    expect(exec.mock.calls.every(([file]) => file === helperPath)).toBe(true)
  })

  test('timeout is reported as unknown state, not success', async () => {
    const exec = vi.fn<Exec>(async () => { throw Object.assign(new Error('timed out'), { killed: true, signal: 'SIGTERM' }) })
    const { proxy } = win(exec)
    await expect(proxy.clearSystemProxy()).rejects.toBeInstanceOf(SystemProxyUnknownStateError)
  })

  test('rejects bypass entries containing the Windows list separator', async () => {
    const exec = vi.fn<Exec>()
    const { proxy } = win(exec)
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: ['a;b'] })).rejects.toThrow('Invalid')
    expect(exec).not.toHaveBeenCalled()
  })

  test('helper calls never overlap', async () => {
    let active = 0, peak = 0
    const exec = vi.fn<Exec>(async () => {
      peak = Math.max(peak, ++active)
      await new Promise((resolve) => setTimeout(resolve, 5))
      active--
      return ok({ connections: [{ name: null, flags: 1 }] })
    })
    const { proxy } = win(exec)
    await Promise.all([proxy.getSystemProxy(), proxy.clearSystemProxy(), proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })])
    expect(peak).toBe(1)
  })

  test.each([
    ['127.0.0.1:7890', { host: '127.0.0.1', port: 7890 }],
    ['http=127.0.0.1:7890;https=127.0.0.1:7890', { host: '127.0.0.1', port: 7890 }],
    ['http=127.0.0.1:7890;https=corp:8080', null],
    ['http://127.0.0.1:7890', null],
    ['127.0.0.1:0', null],
    ['', null],
  ])('parseWindowsProxyServer(%j)', (server, expected) => {
    expect(parseWindowsProxyServer(server)).toEqual(expected)
  })
})
