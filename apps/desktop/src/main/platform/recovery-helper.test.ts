import { mkdir, mkdtemp, readFile, readdir, realpath, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { prepareRecoveryHelper } from './recovery-helper'

test('recovery deployment survives app removal and concurrent publication without replacing old bytes', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-recovery-deploy-')))
  try {
    const source = join(root, 'app.exe'), directory = join(root, 'retained')
    await writeFile(source, 'fake-helper-v1')
    const copies = await Promise.all(Array.from({ length: 4 }, () => prepareRecoveryHelper(source, directory)))
    expect(new Set(copies).size).toBe(1)
    await writeFile(source, 'fake-helper-v2')
    const next = await prepareRecoveryHelper(source, directory)
    expect(next).not.toBe(copies[0])
    await rm(source)
    expect(await readFile(copies[0]!, 'utf8')).toBe('fake-helper-v1')
    expect(await readFile(next, 'utf8')).toBe('fake-helper-v2')
    expect((await readdir(directory)).length).toBe(2)
    await writeFile(source, 'fake-helper-v2')
    await writeFile(next, 'tampered')
    await expect(prepareRecoveryHelper(source, directory)).rejects.toThrow('content address')
    expect(await readFile(next, 'utf8')).toBe('tampered')
    expect((await readdir(directory)).some(name => name.endsWith('.tmp'))).toBe(false)
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('recovery deployment rejects relative paths before filesystem mutation', async () => {
  await expect(prepareRecoveryHelper('relative', 'relative')).rejects.toThrow('absolute')
})

test('recovery deployment refuses a linked directory instead of publishing through it', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-recovery-link-')))
  try {
    const source = join(root, 'fake.exe'), target = join(root, 'target'), alias = join(root, 'alias')
    await writeFile(source, 'fake')
    await mkdir(target)
    await symlink(target, alias, process.platform === 'win32' ? 'junction' : 'dir')
    await expect(prepareRecoveryHelper(source, alias)).rejects.toThrow('links')
    expect(await readdir(target)).toEqual([])
    await rm(alias)
  } finally { await rm(root, { recursive: true, force: true }) }
})
