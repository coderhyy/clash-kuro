// Real helper: read-only diagnostics and invalid-input rejection; never valid proxy writes.
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { expect, test } from 'vitest'

const helper = join(__dirname, '..', '..', '..', 'resources', 'win', 'x64', 'kuro-sysproxy.exe')
const run = async (args: string[]) => {
  try {
    const { stdout } = await promisify(execFile)(helper, args, { windowsHide: true, timeout: 10_000 })
    return { code: 0, json: JSON.parse(stdout) }
  } catch (error) {
    const e = error as { code: number; stdout: string }
    return { code: e.code, json: JSON.parse(e.stdout) }
  }
}

test.skipIf(process.platform !== 'win32' || !existsSync(helper))('helper get returns LAN first with raw flags', async () => {
  const { code, json } = await run(['get'])
  expect(code).toBe(0)
  expect(json.ok).toBe(true)
  expect(json.connections[0]).toMatchObject({ name: null, flags: expect.any(Number) })
})

test.skipIf(process.platform !== 'win32')('native boot clock returns decimal uint64 without runtime compilation', async () => {
  const first = await run(['boot-clock'])
  const second = await run(['boot-clock'])
  expect(first.code).toBe(0)
  expect(first.json).toMatchObject({ command: 'boot-clock', ok: true, uptimeMs: expect.stringMatching(/^\d+$/) })
  expect(second.code).toBe(0)
  expect(BigInt(second.json.uptimeMs)).toBeGreaterThanOrEqual(BigInt(first.json.uptimeMs))
  expect((await run(['boot-clock', '--unexpected'])).code).toBe(1)
})

test.skipIf(process.platform !== 'win32')('resident paths are native user-scoped identities, not a writable admission command', async () => {
  const result = await run(['resident-paths'])
  expect(result.code).toBe(0)
  expect(result.json).toMatchObject({ command: 'resident-paths', ok: true,
    retainedStatePresent: expect.any(Boolean), recoveryRegistrationPresent: expect.any(Boolean) })
  expect(result.json.recoveryDirectory).toMatch(/^[A-Za-z]:\\.+\\ClashKuro\\Recovery$/)
  expect(result.json.userSid).toMatch(/^S-1-5-21-\d+-\d+-\d+-\d+$/)
  expect((await run(['resident-paths', '--root', 'C:\\other'])).code).toBe(1)
})

test.skipIf(process.platform !== 'win32' || !existsSync(helper)).each([
  [['set', '--host', 'a;b', '--port', '7890']],
  [['set', '--host', '127.0.0.1', '--port', '070']],
  [['set', '--host', '127.0.0.1']],
  [['clear']],
  [['clear', '--expected-server', 'http=127.0.0.1:7890']],
  [['clear', '--expected-server', '127.0.0.1:7890', '--log', 'runonce.log']],
  [['clear', '--expected-server', '127.0.0.1:7890', '--log', 'C:\\a"b.log']],
  [['get', '--log', 'C:\\x.log']],
  [['bogus']],
  [['serve']],
  [['publish-migration']],
  [['recover']],
])('helper rejects %j before touching any setting', async (args) => {
  const { code, json } = await run(args)
  expect(code).toBe(1)
  expect(json).toMatchObject({ ok: false, error: { code: 87 } })
})
