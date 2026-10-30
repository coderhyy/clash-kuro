// Runs the real kuro-sysproxy.exe on Windows. Read-only: never sets or clears the system proxy.
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

test.skipIf(process.platform !== 'win32' || !existsSync(helper)).each([
  [['set', '--host', 'a;b', '--port', '7890']],
  [['set', '--host', '127.0.0.1', '--port', '070']],
  [['set', '--host', '127.0.0.1']],
  [['clear']],
  [['clear', '--expected-server', 'http=127.0.0.1:7890']],
  [['bogus']],
])('helper rejects %j before touching any setting', async (args) => {
  const { code, json } = await run(args)
  expect(code).toBe(1)
  expect(json).toMatchObject({ ok: false, error: { code: 87 } })
})
