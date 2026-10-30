// Download the pinned Core and Geo data from core.lock.json, verify sha256, and place them under resources/core/.
// Any hash mismatch fails the build (ADR-0012). Usage: node scripts/fetch-core.mjs [target ...]  (default: this machine)
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync } from 'node:zlib'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const out = join(root, 'resources', 'core')
const cache = join(root, 'resources', '.cache')

export const sha256 = (data) => createHash('sha256').update(data).digest('hex')

/** Throws unless `data` hashes to `expected`; `label` names the artifact in the error. */
export function verify(data, expected, label) {
  const actual = sha256(data)
  if (actual !== expected) throw new Error(`sha256 mismatch for ${label}: expected ${expected}, got ${actual}`)
  return data
}

/** Lock file self-check: every artifact is pinned by version/commit and has a sha256. */
export function checkLock(lock) {
  const pinned = (url, tag) => url.startsWith('https://') && url.includes(tag) && !/\/latest\b/.test(url)
  const { mihomo, geodata } = lock
  if (!/^v\d+\.\d+\.\d+$/.test(mihomo.version)) throw new Error('mihomo.version must be an exact tag')
  if (!/^[0-9a-f]{40}$/.test(geodata.commit)) throw new Error('geodata.commit must be a full commit sha')
  const items = [
    ['mihomo license', mihomo.license, mihomo.version],
    ...Object.entries(mihomo.targets).map(([k, v]) => [`mihomo ${k}`, v, mihomo.version]),
    ...Object.entries(geodata.files).map(([k, v]) => [k, v, geodata.commit]),
  ]
  for (const [label, item, tag] of items) {
    if (!pinned(item.url, tag)) throw new Error(`${label}: URL must be pinned to ${tag}`)
    if (!/^[0-9a-f]{64}$/.test(item.sha256)) throw new Error(`${label}: missing sha256`)
  }
}

async function download(url, expected, label) {
  const cached = join(cache, expected)
  try { return verify(await readFile(cached), expected, label) } catch {}
  const res = await fetch(url)
  if (!res.ok) throw new Error(`${label}: HTTP ${res.status} from ${url}`)
  const data = verify(Buffer.from(await res.arrayBuffer()), expected, label)
  await mkdir(cache, { recursive: true })
  await writeFile(`${cached}.tmp`, data)
  await rename(`${cached}.tmp`, cached)
  return data
}

async function writeAtomic(path, data, mode) {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(`${path}.tmp`, data, { mode })
  await rename(`${path}.tmp`, path)
}

async function fetchCore(lock, target) {
  const spec = lock.mihomo.targets[target]
  if (!spec) throw new Error(`No pinned Core for ${target}; known: ${Object.keys(lock.mihomo.targets).join(', ')}`)
  const archive = await download(spec.url, spec.sha256, `mihomo ${target}`)
  const exe = target.startsWith('win32') ? 'mihomo.exe' : 'mihomo'
  let binary
  if (spec.format === 'gz') binary = gunzipSync(archive)
  else {
    // shortcut: relies on bsdtar (macOS, Windows 10+) to unzip; add a JS unzip if a CI image lacks it.
    const dir = await mkdtemp(join(tmpdir(), 'kuro-core-'))
    try {
      await writeFile(join(dir, 'a.zip'), archive)
      execFileSync('tar', ['-xf', 'a.zip'], { cwd: dir })
      const name = (await readdir(dir)).find((f) => f.endsWith('.exe'))
      if (!name) throw new Error(`mihomo ${target}: no .exe in archive`)
      binary = await readFile(join(dir, name))
    } finally { await rm(dir, { recursive: true, force: true }) }
  }
  // 0755, never setuid: the bundled Core runs as the user (ADR-0009).
  await writeAtomic(join(out, target, exe), binary, 0o755)
  await chmod(join(out, target, exe), 0o755)
}

async function main() {
  const lock = JSON.parse(await readFile(join(root, 'core.lock.json'), 'utf8'))
  checkLock(lock)
  const targets = process.argv.slice(2)
  if (!targets.length) targets.push(`${process.platform}-${process.arch}`)
  for (const target of targets) await fetchCore(lock, target)
  for (const [name, spec] of Object.entries(lock.geodata.files)) {
    await writeAtomic(join(out, 'geo', name), await download(spec.url, spec.sha256, name))
  }
  await writeAtomic(join(out, 'geo', 'VERSION'), lock.geodata.commit)
  const license = await download(lock.mihomo.license.url, lock.mihomo.license.sha256, 'mihomo license')
  await writeAtomic(join(out, 'licenses', 'mihomo-LICENSE.txt'), license)
  await copyFile(join(root, 'core.lock.json'), join(out, 'core.lock.json'))
  console.log(`Core ${lock.mihomo.version} (${targets.join(', ')}) and Geo data ${lock.geodata.commit.slice(0, 7)} ready in resources/core`)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exit(1) })
}
