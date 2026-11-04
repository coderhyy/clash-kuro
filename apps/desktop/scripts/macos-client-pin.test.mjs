import { chmod, mkdir, mkdtemp, rm, symlink, writeFile, realpath } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterEach, expect, test } from 'vitest'
import { inspectClientTree, clientInventory } from './macos-client-pin.mjs'
import { sha256 } from './fetch-core.mjs'

const directories = []
afterEach(async () => { for (const path of directories.splice(0)) await rm(path, { recursive: true, force: true }) })
test.skipIf(process.platform !== 'darwin')('client tree permits protected relative Framework links and rejects escape, writable content and other symlinks', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-client-tree-')))
  directories.push(root)
  const framework = join(root, 'Contents/Frameworks/Test.framework')
  await mkdir(join(framework, 'Versions/A'), { recursive: true, mode: 0o755 })
  const resource = join(framework, 'Versions/A/resource')
  await writeFile(resource, 'fixture', { mode: 0o644 })
  await symlink('A', join(framework, 'Versions/Current'))
  await expect(inspectClientTree(root)).resolves.toBeUndefined()
  const inventory = JSON.parse(await clientInventory(root))
  expect(inventory.directories[0]).toEqual({ path: '', mode: 0o700 })
  expect(inventory.files).toEqual([{ path: 'Contents/Frameworks/Test.framework/Versions/A/resource', mode: 0o644, sha256: sha256(Buffer.from('fixture')) }])
  expect(inventory.links).toEqual([{ path: 'Contents/Frameworks/Test.framework/Versions/Current', target: 'A' }])
  expect(await clientInventory(root)).toEqual(Buffer.from(`${JSON.stringify(inventory)}\n`))
  const escape = join(framework, 'escape')
  await symlink('/etc/hosts', escape)
  await expect(inspectClientTree(root)).rejects.toThrow(/escapes/)
  await rm(escape)
  await chmod(resource, 0o666)
  await expect(inspectClientTree(root)).rejects.toThrow(/writable/)
  await chmod(resource, 0o644)
  await symlink('Contents/Frameworks/Test.framework/Versions/A/resource', join(root, 'outside-frameworks'))
  await expect(inspectClientTree(root)).rejects.toThrow(/escapes/)
})
