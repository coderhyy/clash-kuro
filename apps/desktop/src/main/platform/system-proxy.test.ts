import { describe, expect, test, vi } from 'vitest'
import { createSystemProxy, execCommandSync, parseWindowsProxyServer, SystemProxyPermissionError, SystemProxyUnknownStateError, type Exec, type ExecSync } from './system-proxy'

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
  function win(exec: Exec, remembered: string | null = null, port = 7890, execSync?: ExecSync) {
    const saved: (string | null)[] = []
    const memory = { load: vi.fn(async () => remembered), save: vi.fn(async (server: string | null) => { saved.push(server); remembered = server }) }
    return { proxy: createSystemProxy({ os: 'win32', exec, execSync, helperPath, mixedPort: () => port, memory }), saved, memory }
  }
  const tick = () => new Promise((resolve) => setTimeout(resolve, 0))
  const cleared = JSON.stringify({ ok: true, command: 'clear', connections: [{ name: null, status: 'cleared' }] })

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

  test('a set whose logon fallback entry could not be written still succeeds, with a warning', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [{ name: null, status: 'set' }], runOnceError: { code: 5, message: 'Access is denied.' } }))
    const { proxy } = win(exec)
    await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).resolves.toBeUndefined()
    expect(warn).toHaveBeenCalledWith('System Proxy logon cleanup entry not written:', 'Access is denied.')
    warn.mockRestore()
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

  describe('synchronous clear at session end', () => {
    test('uses the in-memory old and current endpoints, with a hard timeout, and reads no file', async () => {
      const execSync = vi.fn<ExecSync>(() => cleared)
      const { proxy, memory, saved } = win(vi.fn<Exec>(), '127.0.0.1:7890', 7891, execSync)
      await tick()
      memory.load.mockClear()
      const report = proxy.clearSystemProxySync({ timeoutMs: 1500 })
      expect(execSync).toHaveBeenCalledWith(helperPath, ['clear', '--expected-server', '127.0.0.1:7890', '--expected-server', '127.0.0.1:7891'], { timeoutMs: 1500 })
      expect(memory.load).not.toHaveBeenCalled()
      expect(report).toMatchObject({ ran: true, ok: true, exitCode: 0, timedOut: false, servers: ['127.0.0.1:7890', '127.0.0.1:7891'], detail: 'LAN=cleared' })
      expect(saved).toEqual([null])
    })

    test('follows a set made in this run without waiting for the memory file', async () => {
      const execSync = vi.fn<ExecSync>(() => cleared)
      const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [{ name: null, status: 'set' }] }))
      const { proxy } = win(exec, null, 7890, execSync)
      await proxy.setSystemProxy({ host: '127.0.0.1', port: 17890, bypass: [] })
      proxy.clearSystemProxySync({ timeoutMs: 1500 })
      expect(execSync.mock.calls[0]![1]).toEqual(['clear', '--expected-server', '127.0.0.1:17890', '--expected-server', '127.0.0.1:7890'])
    })

    test('starts no helper when nothing of ours is outstanding', async () => {
      const execSync = vi.fn<ExecSync>(() => cleared)
      const { proxy } = win(vi.fn<Exec>(), null, 7890, execSync)
      await tick()
      expect(proxy.clearSystemProxySync({ timeoutMs: 1500 })).toMatchObject({ ran: false, ok: true })
      expect(execSync).not.toHaveBeenCalled()
    })

    test('still clears the current port when the memory file was not loaded yet', () => {
      const execSync = vi.fn<ExecSync>(() => cleared)
      const { proxy } = win(vi.fn<Exec>(), null, 7891, execSync)
      proxy.clearSystemProxySync({ timeoutMs: 1500 })
      expect(execSync.mock.calls[0]![1]).toEqual(['clear', '--expected-server', '127.0.0.1:7891'])
    })

    test('reports a timeout and a helper that failed to initialize', async () => {
      const timedOut = vi.fn<ExecSync>(() => { throw Object.assign(new Error('spawnSync ETIMEDOUT'), { code: 'ETIMEDOUT', status: null, stdout: '' }) })
      const a = win(vi.fn<Exec>(), '127.0.0.1:7890', 7890, timedOut)
      await tick()
      expect(a.proxy.clearSystemProxySync({ timeoutMs: 1500 })).toMatchObject({ ran: true, ok: false, timedOut: true, exitCode: null })
      expect(a.saved).toEqual([])

      const dllInit = vi.fn<ExecSync>(() => { throw Object.assign(new Error('Command failed'), { status: 3221225794, stdout: '' }) })
      const b = win(vi.fn<Exec>(), '127.0.0.1:7890', 7890, dllInit)
      await tick()
      expect(b.proxy.clearSystemProxySync({ timeoutMs: 1500 })).toMatchObject({ ran: true, ok: false, timedOut: false, exitCode: 3221225794 })
    })

    test('a partial failure (exit 2) is not ok, so session-end retries', async () => {
      const execSync = vi.fn<ExecSync>(() => { throw Object.assign(new Error('Command failed'), { status: 2, stdout: JSON.stringify({
        ok: false, command: 'clear', connections: [{ name: null, status: 'cleared' }, { name: 'VPN', status: 'error', error: { code: 5, message: 'denied' } }],
      }) }) })
      const { proxy } = win(vi.fn<Exec>(), '127.0.0.1:7890', 7890, execSync)
      await tick()
      expect(proxy.clearSystemProxySync({ timeoutMs: 1500 })).toMatchObject({ ok: false, exitCode: 2, detail: 'LAN=cleared,VPN=error' })
      expect(proxy.clearSystemProxySync({ timeoutMs: 1500 }).ran).toBe(true)
    })

    test('after a session-end clear, set is refused and the async clear starts no second helper', async () => {
      const exec = vi.fn<Exec>(async () => ok({ command: 'clear', connections: [] }))
      const { proxy } = win(exec, '127.0.0.1:7890', 7890, vi.fn<ExecSync>(() => cleared))
      await tick()
      proxy.clearSystemProxySync({ timeoutMs: 1500 })
      await proxy.clearSystemProxy()
      await expect(proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })).rejects.toThrow(/logoff\/shutdown/)
      expect(exec).not.toHaveBeenCalled()
    })

    test('a set still running at session end makes the clear not ok, so session-end retries', async () => {
      let finishSet!: () => void
      const exec = vi.fn<Exec>(() => new Promise((resolve) => { finishSet = () => resolve(ok({ command: 'set', connections: [] })) }))
      const { proxy } = win(exec, null, 7890, vi.fn<ExecSync>(() => cleared))
      const set = proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })
      await vi.waitFor(() => expect(exec).toHaveBeenCalled())
      expect(proxy.clearSystemProxySync({ timeoutMs: 1500 })).toMatchObject({ ran: true, ok: false, detail: 'LAN=cleared set in flight' })
      finishSet()
      await set
    })

    test('the log detail shows whether the logon fallback entry was deleted', async () => {
      const deleted = JSON.stringify({ ok: true, command: 'clear', connections: [{ name: null, status: 'cleared' }], runOnce: 'deleted' })
      const a = win(vi.fn<Exec>(), '127.0.0.1:7891', 7891, vi.fn<ExecSync>(() => deleted))
      await tick()
      expect(a.proxy.clearSystemProxySync({ timeoutMs: 1500 }).detail).toBe('LAN=cleared runOnce=deleted')
      const failed = JSON.stringify({ ok: true, command: 'clear', connections: [{ name: null, status: 'cleared' }], runOnceError: { code: 5, message: 'Access is denied.' } })
      const b = win(vi.fn<Exec>(), '127.0.0.1:7891', 7891, vi.fn<ExecSync>(() => failed))
      await tick()
      expect(b.proxy.clearSystemProxySync({ timeoutMs: 1500 }).detail).toBe('LAN=cleared runOnce error 5')
    })
    test('a set waiting on the memory file when the session ends never starts the helper', async () => {
      const pendingSaves: Array<() => void> = []
      const exec = vi.fn<Exec>(async () => ok({ command: 'set', connections: [] }))
      const memory = { load: vi.fn(async () => null), save: vi.fn(() => new Promise<void>((resolve) => { pendingSaves.push(resolve) })) }
      const proxy = createSystemProxy({ os: 'win32', exec, execSync: vi.fn<ExecSync>(() => cleared), helperPath, mixedPort: () => 7890, memory })
      const set = proxy.setSystemProxy({ host: '127.0.0.1', port: 7890, bypass: [] })
      await vi.waitFor(() => expect(memory.save).toHaveBeenCalled())
      proxy.clearSystemProxySync({ timeoutMs: 1500 })
      for (const finish of pendingSaves) finish()
      await expect(set).rejects.toThrow(/logoff\/shutdown/)
      expect(exec).not.toHaveBeenCalled()
    })
  })

  test('execCommandSync kills a hung process at the timeout and reports the exit code', () => {
    const started = Date.now()
    const hung = (() => { try { execCommandSync(process.execPath, ['-e', 'setTimeout(() => {}, 10000)'], { timeoutMs: 200 }) } catch (error) { return error } })()
    expect(hung).toMatchObject({ code: 'ETIMEDOUT' })
    expect(Date.now() - started).toBeLessThan(5000)
    const failed = (() => { try { execCommandSync(process.execPath, ['-e', 'process.stdout.write("{}"); process.exit(2)'], { timeoutMs: 5000 }) } catch (error) { return error } })()
    expect(failed).toMatchObject({ status: 2, stdout: '{}' })
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
