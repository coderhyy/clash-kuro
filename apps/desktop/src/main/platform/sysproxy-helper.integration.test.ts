// Real helper: read-only System Proxy plus private temporary-file publication; no set/clear.
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
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
  [['recover']],
])('helper rejects %j before touching any setting', async (args) => {
  const { code, json } = await run(args)
  expect(code).toBe(1)
  expect(json).toMatchObject({ ok: false, error: { code: 87 } })
})

test.skipIf(process.platform !== 'win32')('native migration publication preserves no-replace and reports filesystem failures', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-publish-')))
  const source = join(root, 'source.tmp'), destination = join(root, 'evidence.json')
  const publish = (from = source, to = destination, replace = 'no') => run([
    'publish-migration', '--source', from, '--destination', to, '--replace', replace])
  try {
    await writeFile(source, 'original')
    expect(await publish()).toEqual({ code: 0, json: { command: 'publish-migration', ok: true, errorCode: 0 } })
    expect(await readFile(destination, 'utf8')).toBe('original')
    await expect(readFile(source)).rejects.toMatchObject({ code: 'ENOENT' })
    await writeFile(source, 'replacement')
    expect((await publish()).json).toMatchObject({ ok: false, errorCode: 183 })
    expect(await readFile(destination, 'utf8')).toBe('original')
    expect(await readFile(source, 'utf8')).toBe('replacement')
    expect((await publish(source, destination, 'yes')).code).toBe(0)
    expect(await readFile(destination, 'utf8')).toBe('replacement')
    expect((await publish()).json).toMatchObject({ ok: false, errorCode: 2 })
    await mkdir(join(root, 'folder'))
    await writeFile(source, 'retained')
    expect((await publish(source, join(root, 'folder'), 'yes')).json.ok).toBe(false)
    expect((await publish(source, join(root, 'folder', 'different-parent'))).json.ok).toBe(false)
    expect((await publish(source, source, 'yes')).json.ok).toBe(false)
    expect(await readFile(source, 'utf8')).toBe('retained')
  } finally {
    if (!root.startsWith(join(await realpath(tmpdir()), 'kuro-publish-'))) throw new Error('Unsafe publication fixture cleanup')
    await rm(root, { recursive: true, force: true })
  }
})
