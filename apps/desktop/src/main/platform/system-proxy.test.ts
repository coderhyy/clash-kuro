import { describe, expect, test, vi } from 'vitest'
import { createSystemProxy, parseWindowsProxyServer, SystemProxyPermissionError, SystemProxyUnknownStateError, type Exec } from './system-proxy'

function fixture() {
  const value = (enabled: boolean, host = '', port = 0, auth = 0) => `Enabled: ${enabled ? 'Yes' : 'No'}\nServer: ${host}\nPort: ${port}\nAuthenticated Proxy Enabled: ${auth}`
  const states = new Map([
    ['Wi-Fi:web', value(false)], ['Wi-Fi:secure', value(true, 'corporate.proxy', 8080)],
    ['USB Ethernet:web', value(false)], ['USB Ethernet:secure', value(false)],
  ])
  const bypass = new Map([['Wi-Fi', ['corp.local']], ['USB Ethernet', [] as string[]]])
  const exec = vi.fn<Exec>(async (_file, args) => {
    let stdout = ''
    const secure = args[0]?.includes('secureweb')
    const key = `${args[1]}:${secure ? 'secure' : 'web'}`
    if (args[0] === '-listallnetworkservices') stdout = 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Disabled VPN\nUSB Ethernet\n'
    if (args[0] === '-getwebproxy' || args[0] === '-getsecurewebproxy') stdout = states.get(key)!
    if (args[0] === '-getproxybypassdomains') stdout = bypass.get(args[1]!)!.join('\n') || "There aren't any bypass domains set on this service."
    if (args[0] === '-setwebproxy' || args[0] === '-setsecurewebproxy') states.set(key, value(true, args[2], Number(args[3])))
    if (args[0] === '-setwebproxystate' || args[0] === '-setsecurewebproxystate') states.set(key, states.get(key)!.replace(/^Enabled: .+$/m, `Enabled: ${args[2] === 'on' ? 'Yes' : 'No'}`))
    if (args[0] === '-setproxybypassdomains') bypass.set(args[1]!, args[2] === 'Empty' ? [] : args.slice(2))
    return { stdout, stderr: '' }
  })
  const writes = () => exec.mock.calls.filter(([, args]) => args[0]?.startsWith('-set')).map(([, args]) => args)
  return { exec, states, bypass, value, writes, proxy: createSystemProxy({ os: 'darwin', exec }) }
}
const settings = { host: '127.0.0.1', port: 17890, bypass: ['localhost', '*.local'] }

test('blank disabled proxies can be enabled and cleared; active non-auth proxy and bypass are restored', async () => {
  const f = fixture()
  await f.proxy.setSystemProxy(settings)
  expect(await f.proxy.getSystemProxy()).toEqual(settings)
  await f.proxy.clearSystemProxy()
  expect(f.states.get('Wi-Fi:web')).toBe(f.value(false, settings.host, settings.port))
  expect(f.states.get('Wi-Fi:secure')).toBe(f.value(true, 'corporate.proxy', 8080))
  expect(f.bypass.get('Wi-Fi')).toEqual(['corp.local'])
  expect(f.bypass.get('USB Ethernet')).toEqual([])
  expect(f.exec.mock.calls.flat(2)).not.toContain('*Disabled VPN')
})

test('clear without this instance writing never mutates third-party or matching loopback proxies', async () => {
  const f = fixture()
  f.states.set('Wi-Fi:web', f.value(true, settings.host, settings.port))
  await f.proxy.clearSystemProxy()
  expect(f.writes()).toEqual([])
  await expect(f.proxy.cleanupStaleSystemProxy(settings.port)).rejects.toThrow('no ownership receipt')
  expect(f.writes()).toEqual([])
})

test('stale inspection accepts confirmed off without writes', async () => {
  const f = fixture()
  f.states.set('Wi-Fi:secure', f.value(false))
  await f.proxy.cleanupStaleSystemProxy(settings.port)
  expect(await f.proxy.getSystemProxy()).toBeNull()
  expect(f.writes()).toEqual([])
})

test.each(['Enabled: Maybe', 'Enabled: No\nEnabled: Yes', 'Enabled: No\nServer: \nPort: 0', 'Enabled: Yes\nServer: x\nPort: 8080\nAuthenticated Proxy Enabled: 2'])('unknown proxy fields reject get and set before mutation: %s', async output => {
  const f = fixture()
  f.states.set('USB Ethernet:secure', output)
  await expect(f.proxy.getSystemProxy()).rejects.toThrow('state unknown')
  await expect(f.proxy.setSystemProxy(settings)).rejects.toThrow('state unknown')
  expect(f.writes()).toEqual([])
})

test('unknown service enumeration and bypass refuse writes; named-service empty bypass is supported', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  f.exec.mockImplementation(async (file, args) => args[0] === '-getproxybypassdomains'
    ? { stdout: `There aren't any bypass domains set on ${args[1]}.`, stderr: '' } : original(file, args))
  expect((await f.proxy.getSystemProxy())?.bypass).toEqual([])
  f.exec.mockImplementation(async (file, args) => args[0] === '-getproxybypassdomains' ? { stdout: '', stderr: '' } : original(file, args))
  await expect(f.proxy.setSystemProxy(settings)).rejects.toThrow('bypass state unknown')
  expect(f.writes()).toEqual([])
  f.exec.mockResolvedValue({ stdout: '', stderr: '' })
  await expect(f.proxy.getSystemProxy()).rejects.toThrow('enumeration unconfirmed')
})

test('HTTP command failure after mutation rolls back confirmed endpoint without touching foreign HTTPS', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  let fail = true
  f.exec.mockImplementation(async (file, args) => {
    const result = await original(file, args)
    if (args[0] === '-setwebproxy' && fail) { fail = false; throw new Error('reply lost') }
    return result
  })
  await expect(f.proxy.setSystemProxy(settings)).rejects.toThrow('reply lost')
  expect(f.states.get('Wi-Fi:web')).toBe(f.value(false, settings.host, settings.port))
  expect(f.states.get('Wi-Fi:secure')).toBe(f.value(true, 'corporate.proxy', 8080))
  expect(f.writes().some(args => args[0]?.includes('secure'))).toBe(false)
})

test('active authenticated proxy rejects set without any changes', async () => {
  const f = fixture()
  f.states.set('Wi-Fi:secure', f.value(true, 'corporate.proxy', 8080, 1))
  await expect(f.proxy.setSystemProxy(settings)).rejects.toThrow('Authenticated')
  expect(f.writes()).toEqual([])
})

test.each(['endpoint', 'auth', 'unknown'])('changed %s is preserved during clear; independent protocols still clean', async change => {
  const f = fixture()
  await f.proxy.setSystemProxy(settings)
  const changed = change === 'endpoint' ? f.value(true, 'new.proxy', 9000) : change === 'auth' ? f.value(true, settings.host, settings.port, 1) : 'unreadable'
  f.states.set('Wi-Fi:web', changed)
  f.exec.mockClear()
  await expect(f.proxy.clearSystemProxy()).rejects.toThrow(/changed|unknown/)
  expect(f.states.get('Wi-Fi:web')).toBe(changed)
  expect(f.states.get('USB Ethernet:web')).toBe(f.value(false, settings.host, settings.port))
  expect(f.bypass.get('Wi-Fi')).toEqual(settings.bypass)
})

test('changed bypass is preserved and reported without altering it', async () => {
  const f = fixture()
  await f.proxy.setSystemProxy(settings)
  f.bypass.set('Wi-Fi', ['third.party'])
  await expect(f.proxy.clearSystemProxy()).rejects.toThrow('bypass changed')
  expect(f.bypass.get('Wi-Fi')).toEqual(['third.party'])
})

test('HTTPS set refusal rolls back only attempted HTTP, never disables preexisting corporate HTTPS', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  f.exec.mockImplementation(async (file, args) => {
    if (args[0] === '-setsecurewebproxy') throw Object.assign(new Error('exit 1'), { stderr: 'Operation not permitted' })
    return original(file, args)
  })
  await expect(f.proxy.setSystemProxy(settings)).rejects.toBeInstanceOf(SystemProxyPermissionError)
  expect(f.states.get('Wi-Fi:web')).toBe(f.value(false, settings.host, settings.port))
  expect(f.states.get('Wi-Fi:secure')).toBe(f.value(true, 'corporate.proxy', 8080))
  expect(f.writes()).not.toContainEqual(['-setsecurewebproxystate', 'Wi-Fi', 'off'])
})

test('command failure after applying bypass is read back and rolled back', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  let fail = true
  f.exec.mockImplementation(async (file, args) => {
    const result = await original(file, args)
    if (args[0] === '-setproxybypassdomains' && fail) { fail = false; throw new Error('write reply lost') }
    return result
  })
  await expect(f.proxy.setSystemProxy(settings)).rejects.toThrow('write reply lost')
  expect(f.bypass.get('Wi-Fi')).toEqual(['corp.local'])
  expect(f.states.get('Wi-Fi:secure')).toBe(f.value(true, 'corporate.proxy', 8080))
})

test('clear readback must independently confirm the disabled state and retry retains ownership', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  await f.proxy.setSystemProxy(settings)
  f.exec.mockImplementation(async (file, args) => {
    if (args[0] === '-setwebproxystate' && args[1] === 'USB Ethernet') return { stdout: '', stderr: '' }
    return original(file, args)
  })
  await expect(f.proxy.clearSystemProxy()).rejects.toThrow('write unconfirmed')
  expect(f.states.get('USB Ethernet:web')).toBe(f.value(true, settings.host, settings.port))
  f.exec.mockImplementation(original)
  await f.proxy.clearSystemProxy()
  expect(f.states.get('USB Ethernet:web')).toBe(f.value(false, settings.host, settings.port))
})

test('clear continues other owned protocols after permission failure', async () => {
  const f = fixture(), original = f.exec.getMockImplementation()!
  await f.proxy.setSystemProxy(settings)
  f.exec.mockImplementation(async (file, args) => {
    if (args[0] === '-setwebproxystate' && args[1] === 'Wi-Fi') throw new Error('Permission denied')
    return original(file, args)
  })
  await expect(f.proxy.clearSystemProxy()).rejects.toBeInstanceOf(SystemProxyPermissionError)
  expect(f.states.get('USB Ethernet:secure')).toBe(f.value(false, settings.host, settings.port))
})

test('reads and clears empty bypass with networksetup Empty', async () => {
  const f = fixture()
  await f.proxy.setSystemProxy({ ...settings, bypass: [] })
  expect(f.writes()).toContainEqual(['-setproxybypassdomains', 'Wi-Fi', 'Empty'])
})

describe('recognizable errors and validation', () => {
  test.each(['Permission denied', 'You must be root to use this command', 'not authorized', 'requires administrator authorization'])('%s', async message => {
    const proxy = createSystemProxy({ os: 'darwin', exec: async () => ({ stdout: message, stderr: '' }) })
    await expect(proxy.getSystemProxy()).rejects.toBeInstanceOf(SystemProxyPermissionError)
  })
  test('rejects invalid settings before exec', async () => {
    const f = fixture()
    await expect(f.proxy.setSystemProxy({ ...settings, port: 0 })).rejects.toThrow('Invalid')
    expect(f.exec).not.toHaveBeenCalled()
  })
  test('Linux fails without invoking commands', async () => {
    const exec = vi.fn<Exec>(), proxy = createSystemProxy({ os: 'linux', exec })
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

  test('ordinary shutdown rejects a set already queued but not started', async () => {
    const exec = vi.fn<Exec>()
    const { proxy } = win(exec)
    const pending = proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })
    if (!('beginShutdown' in proxy)) throw new Error('Expected Windows proxy')
    proxy.beginShutdown()
    await expect(pending).rejects.toThrow(/logoff\/shutdown/)
    expect(exec).not.toHaveBeenCalled()
  })

  test('set passes argv (no shell string), remembers the endpoint first', async () => {
    const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [{ name: null, status: 'set' }, { name: '公司 VPN', status: 'set' }] }))
    const { proxy, saved } = win(exec)
    await proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: ['localhost', '127.0.0.1', '::1'] })
    // Bare ::1 makes WinINet reject the whole list (measured: error 87); it must be bracketed.
    expect(exec).toHaveBeenCalledWith(helperPath, ['set', '--host', '127.0.0.1', '--port', '17890', '--bypass', 'localhost;127.0.0.1;[::1]'])
    expect(saved).toEqual(['127.0.0.1:17890'])
  })

  test('standalone set passes its optional diagnostic log path', async () => {
    const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [{ name: null, status: 'set' }] }))
    const logPath = 'C:\\Users\\A B\\AppData\\Roaming\\Clash Kuro\\data\\sysproxy.log'
    const memory = { load: vi.fn(async () => null), save: vi.fn(async () => {}) }
    const proxy = createSystemProxy({ os: 'win32', exec, helperPath, logPath, mixedPort: () => 7890, memory })
    await proxy.setSystemProxy({ host: '127.0.0.1', port: 7891, bypass: ['localhost'] })
    expect(exec).toHaveBeenCalledWith(helperPath, ['set', '--host', '127.0.0.1', '--port', '7891', '--bypass', 'localhost', '--log', logPath])
    // Clear runs from Clash Kuro itself (stdout is read), so it needs no log file.
    await proxy.clearSystemProxy()
    expect(exec.mock.calls[1]![1]).not.toContain('--log')
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
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow(/logoff\/shutdown/)
    expect(exec).toHaveBeenCalledOnce()
    // A closed write gate must not hide a failed cleanup just because memory started empty.
    exec.mockResolvedValue(ok({ command: 'clear', connections: [{ name: null, status: 'cleared' }] }))
    await proxy.clearSystemProxy()
    expect(exec).toHaveBeenCalledTimes(2)
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow(/logoff\/shutdown/)
  })

  test('rejects bypass entries containing the Windows list separator', async () => {
    const exec = vi.fn<Exec>()
    const { proxy } = win(exec)
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: ['a;b'] })).rejects.toThrow('Invalid')
    expect(exec).not.toHaveBeenCalled()
  })

  test.each(['invalid JSON', '{}', '{"ok":false,"connections":[]}'])('uncertain mutation output closes writes: %s', async (stdout) => {
    const exec = vi.fn<Exec>(async () => ({ stdout, stderr: '' }))
    const { proxy } = win(exec)
    await expect(proxy.clearSystemProxy()).rejects.toThrow()
    exec.mockResolvedValue(ok({ command: 'clear', connections: [] }))
    await proxy.clearSystemProxy()
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow(/uncertain state/)
    expect(exec).toHaveBeenCalledTimes(2)
  })

  test.each(['invalid JSON', '{}'])('unverifiable set closes writes: %s', async (stdout) => {
    const exec = vi.fn<Exec>(async () => ({ stdout, stderr: '' }))
    const { proxy } = win(exec)
    const settings = { host: '127.0.0.1', port: 7890, bypass: [] }
    await expect(proxy.setSystemProxy(settings)).rejects.toThrow()
    await expect(proxy.setSystemProxy(settings)).rejects.toThrow(/uncertain state/)
    expect(exec).toHaveBeenCalledOnce()
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

  test('shutdown during a memory save prevents the queued set from invoking the helper', async () => {
    let finishSave!: () => void
    const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [] }))
    const memory = { load: vi.fn(async () => null), save: vi.fn(() => new Promise<void>((resolve) => { finishSave = resolve })) }
    const proxy = createSystemProxy({ os: 'win32', exec, helperPath, mixedPort: () => 7890, memory })
    const set = proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })
    await vi.waitFor(() => expect(memory.save).toHaveBeenCalled())
    if (!('beginShutdown' in proxy)) throw new Error('Expected Windows proxy')
    proxy.beginShutdown()
    finishSave()
    await expect(set).rejects.toThrow(/logoff\/shutdown/)
    expect(exec).not.toHaveBeenCalled()
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
