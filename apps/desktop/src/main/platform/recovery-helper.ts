import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { link, lstat, mkdir, open, readFile, realpath, rm } from 'node:fs/promises'
import { isAbsolute, join, resolve } from 'node:path'

/** Keep recovery executable bytes outside the versioned app installation.
 * Never overwrite or garbage-collect old versions: a pending RunOnce may still need them.
 * The caller chooses a trusted local per-user directory, not a network/shared location.
 */
export async function prepareRecoveryHelper(source: string, directory: string): Promise<string> {
  if (!isAbsolute(source) || !isAbsolute(directory)) throw new Error('Recovery helper paths must be absolute')
  await mkdir(directory, { recursive: true })
  const folder = await lstat(directory)
  const canonical = await realpath(directory)
  const normalize = (value: string) => process.platform === 'win32' ? resolve(value).toLowerCase() : resolve(value)
  if (!folder.isDirectory() || folder.isSymbolicLink() || normalize(canonical) !== normalize(directory)) {
    throw new Error('Recovery directory must not traverse links')
  }
  const bytes = await readFile(source)
  if (!bytes.length) throw new Error('Recovery helper is empty')
  const hash = createHash('sha256').update(bytes).digest('hex')
  const destination = join(directory, `${hash}.exe`)
  const verify = async () => {
    const stat = await lstat(destination)
    if (!stat.isFile() || stat.isSymbolicLink() || !bytes.equals(await readFile(destination))) {
      throw new Error('Existing recovery helper does not match its content address')
    }
  }
  const temporary = join(directory, `${randomUUID()}.tmp`)
  const file = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o700)
  try {
    try {
      await file.writeFile(bytes)
      await file.sync()
    } finally { await file.close() }
    // Publishing a fully written inode without replacing an existing executable.
    try { await link(temporary, destination) }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error }
    await verify()
    return destination
  } finally { await rm(temporary, { force: true }) }
}
