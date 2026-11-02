import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { guardMigrationStartup } from './migration-startup'

test('Windows default remains legacy only when no migration has begun; no flag enables resident', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'kuro-migration-gate-'))
  try {
    await expect(guardMigrationStartup(dir, { os: 'win32', args: [] })).resolves.toBeUndefined()
    await expect(guardMigrationStartup(dir, { os: 'win32', args: ['--experimental-resident'] })).rejects.toThrow('not available')
    await writeFile(join(dir, 'proxy-migration.json'), '')
    await expect(guardMigrationStartup(dir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
    await writeFile(join(dir, 'proxy-migration.json'), '{"verified":true}')
    await expect(guardMigrationStartup(dir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
    await expect(guardMigrationStartup(dir, { os: 'darwin', args: [] })).resolves.toBeUndefined()
  } finally { await rm(dir, { recursive: true, force: true }) }
})
test('non-file migration marker is denied rather than treated as missing', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'kuro-migration-gate-'))
  try {
    await mkdir(join(dir, 'proxy-migration.json'))
    await expect(guardMigrationStartup(dir, { os: 'win32', args: [] })).rejects.toThrow('legacy startup is blocked')
  } finally { await rm(dir, { recursive: true, force: true }) }
})
