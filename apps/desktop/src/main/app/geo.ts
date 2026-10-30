import { copyFile, mkdir, readFile, rename } from 'node:fs/promises'
import { join } from 'node:path'

const FILES = ['Country.mmdb', 'GeoSite.dat', 'ASN.mmdb']

/**
 * Copy the bundled Geo data into Core's data directory (ADR-0012).
 * Re-copies only when the bundled VERSION differs, so Core never has to download it.
 */
export async function installGeoData(bundledDir: string, dataDir: string): Promise<void> {
  const version = (await readFile(join(bundledDir, 'VERSION'), 'utf8')).trim()
  const marker = join(dataDir, 'geo.version')
  const installed = await readFile(marker, 'utf8').then((v) => v.trim(), () => null)
  if (installed === version) return
  await mkdir(dataDir, { recursive: true, mode: 0o700 })
  for (const name of FILES) {
    const tmp = join(dataDir, `${name}.tmp`)
    await copyFile(join(bundledDir, name), tmp)
    await rename(tmp, join(dataDir, name))
  }
  await mkdir(dataDir, { recursive: true })
  await copyFile(join(bundledDir, 'VERSION'), `${marker}.tmp`)
  await rename(`${marker}.tmp`, marker)
}
