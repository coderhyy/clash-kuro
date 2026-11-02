import { createHash } from 'node:crypto'
import * as nodeFs from 'node:fs'
import { createRequire } from 'node:module'
import { isAbsolute, normalize } from 'node:path'

// Electron's virtual fs must not turn the packaged app.asar identity into directory contents.
const fs: typeof nodeFs = process.versions.electron ? createRequire(__filename)('original-fs') : nodeFs
const pathKey = (path: string) => process.platform === 'win32' ? normalize(path).toLowerCase() : normalize(path)

export async function canonicalMigrationArtifact(path: string): Promise<string> {
  if (!isAbsolute(path) || /^[\\/]{2}/.test(path) || /[\0\r\n]/.test(path))
    throw new Error('Migration deployment requires absolute local paths')
  const stat = await fs.promises.lstat(path), actual = await fs.promises.realpath(path)
  if (!stat.isFile() || stat.isSymbolicLink() || pathKey(actual) !== pathKey(path))
    throw new Error('Migration artifact paths must not traverse links or aliases')
  return actual
}

export async function readMigrationArtifact(path: string, maximum = 64 * 1024 * 1024): Promise<Buffer> {
  await canonicalMigrationArtifact(path)
  const stat = await fs.promises.lstat(path)
  if (!stat.size || stat.size > maximum) throw new Error('Migration artifact is empty or exceeds size limit')
  const bytes = await fs.promises.readFile(path)
  if (!bytes.length || bytes.length > maximum) throw new Error('Migration artifact is empty or exceeds size limit')
  return bytes
}

export async function hashMigrationArtifact(path: string, maximum = 64 * 1024 * 1024): Promise<string> {
  return createHash('sha256').update(await readMigrationArtifact(path, maximum)).digest('hex')
}
