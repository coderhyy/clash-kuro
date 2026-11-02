import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import type { BootEvidence } from './migration-boot'
import type { PreparedMigrationReceipt } from './migration-preparation'
import type { ResidentReservation } from './resident-client'
import { createInitialMigrationAuthorizer, createMigrationAuthorizer, type InitialMigrationAdmissionOptions } from './migration-admission'

const roots: string[] = []
const hash = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')

test('active admission uses existing native provenance, not a fabricated fresh Restart witness', async () => {
  const f = await fixture(), retainedHelper = join(f.root, 'retained.exe')
  f.held.admissionReceiptDigest = hash(await readFile(f.marker))
  f.held.initialEndpoints = []
  f.held.priorEndpoints = ['127.0.0.1:7890']
  f.observed.uptimeMs = '999999999' // No reset relative to original preparation; native admission already exists.
  f.observed.checkpoint = null
  f.observed.nativeRunOnce = `"${retainedHelper}" recover-admitted`
  const authorize = createMigrationAuthorizer({ ...f.options, retainedHelper, confirmControlledRestart: false })
  const result = await authorize(f.held)
  expect(result.receiptDigest).toBe(f.held.admissionReceiptDigest)
  expect(f.collect).toHaveBeenCalledExactlyOnceWith()
  expect(f.loadReceipt).toHaveBeenCalledTimes(2)
  f.observed.nativeRunOnce = null
  await expect(authorize(f.held)).resolves.toMatchObject({ receiptDigest: f.held.admissionReceiptDigest })
})

test.each(['receipt', 'missing-provenance', 'helper', 'sid', 'machine', 'legacy', 'foreign-registration', 'same-name-writer'])(
  'active admission refuses %s without falling back to legacy recovery', async fault => {
    const f = await fixture(), retainedHelper = join(f.root, 'retained.exe')
    f.held.admissionReceiptDigest = hash(await readFile(f.marker))
  f.held.initialEndpoints = []
    if (fault === 'receipt') f.held.admissionReceiptDigest = '9'.repeat(64)
    if (fault === 'missing-provenance') Object.assign(f.held, { admissionReceiptDigest: undefined })
    if (fault === 'helper') f.held.helperDigest = '9'.repeat(64)
    if (fault === 'sid') f.held.userSid = ''
    if (fault === 'machine') f.observed.machineGuidSha256 = '9'.repeat(64)
    if (fault === 'legacy') f.observed.legacyRunOnce = 'old cleanup'
    if (fault === 'foreign-registration') f.observed.nativeRunOnce = `"${retainedHelper}" recover`
    if (fault === 'same-name-writer') f.observed.knownWriters.push({ pid: process.pid + 2, name: 'Clash Kuro' })
    await expect(createMigrationAuthorizer({ ...f.options, retainedHelper })(f.held)).rejects.toThrow()
  })

test('active admission rechecks disk evidence after collection', async () => {
  const f = await fixture()
  f.held.admissionReceiptDigest = hash(await readFile(f.marker))
  f.held.initialEndpoints = []
  f.collect.mockImplementation(async () => {
    await writeFile(f.marker, 'changed during observation')
    return f.observed
  })
  await expect(createMigrationAuthorizer({ ...f.options, retainedHelper: join(f.root, 'retained.exe') })(f.held))
    .rejects.toThrow('changed during active admission')
})

test('new owner still requires controlled Restart and initial evidence', async () => {
  const f = await fixture()
  await expect(createMigrationAuthorizer({ ...f.options, retainedHelper: join(f.root, 'retained.exe'),
    confirmControlledRestart: false })(f.held)).rejects.toThrow('confirmation')
  expect(f.loadReceipt).not.toHaveBeenCalled()
})
beforeEach(() => { vi.spyOn(Date, 'now').mockReturnValue(Date.parse('2026-11-03T00:00:00Z')) })
afterEach(async () => {
  vi.restoreAllMocks()
  for (const root of roots.splice(0)) {
    if (!isAbsolute(root) || !root.startsWith(join(await realpath(tmpdir()), 'kuro-migration-admission-')))
      throw new Error('Unsafe test cleanup path')
    await rm(root, { recursive: true, force: true })
  }
})

function baseline(): BootEvidence {
  return { version: 2, userSid: 'S-1-5-21-1-2-3-1001', machineGuidSha256: 'e'.repeat(64), uptimeMs: '100000',
    collectedAt: '2026-11-02T00:00:03Z', lastBootUpTime: '2026-11-01T00:00:00Z',
    newest: { record: 105, digest: 'f'.repeat(64), fields: {} },
    kernel: { record: 80, digest: 'b'.repeat(64), fields: { StartTime: '2026-11-01T00:00:02Z' } },
    boot: { record: 79, digest: 'c'.repeat(64), fields: {} }, checkpoint: null,
    legacyRunOnce: null, nativeRunOnce: null, knownWriters: [] }
}

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'kuro-migration-admission-')))
  roots.push(root)
  const dataDir = join(root, 'data'), helperPath = join(root, 'helper.exe')
  const collectorPath = join(root, 'never-run.ps1'), appPath = join(root, 'app.asar')
  await mkdir(dataDir)
  await writeFile(helperPath, 'non-executable test helper')
  await writeFile(collectorPath, 'non-executable test collector')
  await writeFile(appPath, 'non-executable test app archive')
  const marker = join(dataDir, 'proxy-migration.json')
  const receipt: PreparedMigrationReceipt = { version: 1, state: 'prepared', id: '00000000-0000-4000-8000-000000000000',
    userSid: baseline().userSid, endpoints: ['127.0.0.1:7890'], helperPath, collectorPath, appPath,
    collectorDigest: hash(await readFile(collectorPath)), appDigest: hash(await readFile(appPath)),
    helperDigest: hash(await readFile(helperPath)), backupDirectory: join(root, 'backup'), backupDigest: 'a'.repeat(64),
    before: { ...baseline(), uptimeMs: '30000', collectedAt: '2026-11-02T00:00:01Z',
      newest: { record: 100, digest: 'a'.repeat(64), fields: {} } },
    after: { ...baseline(), checkpoint: { record: 100, digest: 'a'.repeat(64), fields: {} } } }
  await writeFile(marker, JSON.stringify(receipt, null, 2) + '\n')
  const held: ResidentReservation = { pid: process.pid + 1, nonce: '1'.repeat(64), userSid: receipt.userSid,
    helperDigest: receipt.helperDigest, journalDigest: '2'.repeat(64), priorEndpoints: [], initialEndpoints: [...receipt.endpoints], admissionReceiptDigest: null }
  const observed: BootEvidence = { ...baseline(), uptimeMs: '60000', collectedAt: '2026-11-02T01:00:00Z',
    lastBootUpTime: '2026-11-02T00:59:00Z', newest: { record: 130, digest: '9'.repeat(64), fields: {} },
    kernel: { record: 120, digest: 'd'.repeat(64), fields: { StartTime: '2026-11-02T00:59:02Z' } },
    boot: { record: 119, digest: '8'.repeat(64), fields: {} }, checkpoint: baseline().newest,
    knownWriters: [{ pid: process.pid, name: 'Clash Kuro' }, { pid: held.pid, name: 'kuro-sysproxy' }] }
  // The loader seam stands in for disk receipt verification; no preparation or ownership is simulated.
  const loadReceipt = vi.fn(async () => structuredClone(receipt))
  const collect = vi.fn(async (_checkpoint?: number) => structuredClone(observed))
  const options: InitialMigrationAdmissionOptions = { dataDir, helperPath, collectorPath, appPath,
    confirmControlledRestart: true, loadReceipt, collect }
  return { root, marker, receipt, observed, held, options, loadReceipt, collect }
}

test('factory waits for reservation callback, then authorizes only initial replay with fresh bound evidence', async () => {
  const f = await fixture(), marker = await readFile(f.marker), helper = await readFile(f.options.helperPath)
  const authorize = createInitialMigrationAuthorizer(f.options)
  expect(f.loadReceipt).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
  const proof = await authorize(f.held)
  expect(f.collect).toHaveBeenCalledExactlyOnceWith(105)
  expect(f.loadReceipt).toHaveBeenCalledTimes(2)
  expect(f.loadReceipt).toHaveBeenNthCalledWith(1, f.options.dataDir, f.options.helperPath, f.options)
  expect(proof.receiptDigest).toBe(hash(marker))
  expect(proof.evidenceDigest).toBe(hash(JSON.stringify({ receiptDigest: hash(marker), reservation: f.held,
    observed: f.observed, restart: `120:${'d'.repeat(64)}` })))
  expect(await readFile(f.marker)).toEqual(marker)
  expect(await readFile(f.options.helperPath)).toEqual(helper)
  expect(f.observed.knownWriters).toHaveLength(2)
})

test('controlled Restart must be explicitly confirmed before any loading or collection', async () => {
  const f = await fixture()
  await expect(createInitialMigrationAuthorizer({ ...f.options, confirmControlledRestart: false })(f.held))
    .rejects.toThrow('confirmation')
  expect(f.loadReceipt).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
})

test.each(['initialized', 'missing'])('empty pending endpoints with %s admission provenance deny initial migration', async provenance => {
  const f = await fixture()
  if (provenance === 'initialized') f.held.admissionReceiptDigest = '3'.repeat(64)
  else Reflect.deleteProperty(f.held, 'admissionReceiptDigest')
  expect(f.held.priorEndpoints).toEqual([])
  await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow('admission provenance')
  expect(f.loadReceipt).not.toHaveBeenCalled(); expect(f.collect).not.toHaveBeenCalled()
})

test.each(['sid', 'reservation-helper', 'deployed-helper', 'prepared-helper', 'pid', 'self-pid', 'nonce', 'journal', 'prior', 'unknown-prior'])(
  'invalid or mismatched reservation %s denies before collection', async fault => {
    const f = await fixture()
    if (fault === 'sid') f.held.userSid = 'S-1-5-21-4-3-2-1001'
    else if (fault === 'reservation-helper') f.held.helperDigest = '0'.repeat(64)
    else if (fault === 'deployed-helper') await writeFile(f.options.helperPath, 'replaced helper')
    else if (fault === 'prepared-helper') f.receipt.helperDigest = '0'.repeat(64)
    else if (fault === 'pid') f.held.pid = 0
    else if (fault === 'self-pid') f.held.pid = process.pid
    else if (fault === 'nonce') f.held.nonce = ''
    else if (fault === 'journal') f.held.journalDigest = ''
    else if (fault === 'prior') f.held.priorEndpoints = ['127.0.0.1:7890']
    else Reflect.deleteProperty(f.held, 'priorEndpoints')
    await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow()
    expect(f.collect).not.toHaveBeenCalled()
  })

test.each(['Clash Kuro', 'kuro-sysproxy', 'mihomo', 'a'.repeat(64)])(
  'same-name or hash-named third process %s is never excluded', async name => {
    const f = await fixture()
    f.observed.knownWriters.push({ pid: process.pid + 2, name })
    await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow('Known proxy writer')
  })

test.each(['before-native', 'after-native', 'after-legacy', 'fresh-native', 'fresh-legacy', 'unknown-native', 'unknown-writers'])(
  'initial authorization rejects %s registration or inventory', async fault => {
    const f = await fixture()
    if (fault === 'before-native') f.receipt.before.nativeRunOnce = 'registered'
    else if (fault === 'after-native') f.receipt.after.nativeRunOnce = 'registered'
    else if (fault === 'after-legacy') f.receipt.after.legacyRunOnce = 'registered'
    else if (fault === 'fresh-native') f.observed.nativeRunOnce = 'registered'
    else if (fault === 'fresh-legacy') f.observed.legacyRunOnce = 'registered'
    else if (fault === 'unknown-native') Reflect.deleteProperty(f.observed, 'nativeRunOnce')
    else Reflect.deleteProperty(f.observed, 'knownWriters')
    await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow()
  })

test.each(['uptime', 'checkpoint', 'machine', 'sid', 'kernel', 'malformed-self'])(
  'fresh evidence %s cannot bypass restart or inventory verification', async fault => {
    const f = await fixture()
    if (fault === 'uptime') f.observed.uptimeMs = f.receipt.after.uptimeMs
    else if (fault === 'checkpoint') f.observed.checkpoint!.digest = '0'.repeat(64)
    else if (fault === 'machine') f.observed.machineGuidSha256 = '0'.repeat(64)
    else if (fault === 'sid') f.observed.userSid = 'S-1-5-21-4-3-2-1001'
    else if (fault === 'kernel') f.observed.kernel = f.receipt.after.kernel
    else f.observed.knownWriters[0]!.name = ''
    await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow()
  })

test.each(['receipt', 'marker-whitespace', 'marker-deleted', 'helper'])(
  'evidence %s changed during collection denies without overwriting the change', async fault => {
    const f = await fixture()
    const marker = await readFile(f.marker)
    const collect = async () => {
      if (fault === 'receipt') f.receipt.backupDigest = '0'.repeat(64)
      else if (fault === 'marker-whitespace') await writeFile(f.marker, marker.toString() + '\n')
      else if (fault === 'marker-deleted') await rm(f.marker)
      else await writeFile(f.options.helperPath, 'changed while collecting')
      return structuredClone(f.observed)
    }
    await expect(createInitialMigrationAuthorizer({ ...f.options, collect })(f.held)).rejects.toThrow()
    if (fault === 'marker-deleted') await expect(readFile(f.marker)).rejects.toMatchObject({ code: 'ENOENT' })
    else if (fault === 'marker-whitespace') expect(await readFile(f.marker, 'utf8')).toBe(marker.toString() + '\n')
    else expect(await readFile(f.marker)).toEqual(marker)
  })

test.each(['load', 'collect', 'reload'])('%s failure propagates without changing marker or helper', async failure => {
  const f = await fixture(), marker = await readFile(f.marker), helper = await readFile(f.options.helperPath)
  if (failure === 'collect') f.collect.mockRejectedValueOnce(new Error('fake collection failure'))
  else if (failure === 'load') f.loadReceipt.mockRejectedValueOnce(new Error('fake receipt failure'))
  else f.loadReceipt.mockResolvedValueOnce(structuredClone(f.receipt)).mockRejectedValueOnce(new Error('fake rehash failure'))
  await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow('fake')
  expect(await readFile(f.marker)).toEqual(marker)
  expect(await readFile(f.options.helperPath)).toEqual(helper)
})

test('existing replay policy still rejects an invalid prepared endpoint inventory', async () => {
  const f = await fixture()
  f.receipt.endpoints = []
  await expect(createInitialMigrationAuthorizer(f.options)(f.held)).rejects.toThrow('endpoint inventory')
})

test('evidence commitment includes the reservation nonce and native journal digest', async () => {
  const f = await fixture(), authorize = createInitialMigrationAuthorizer(f.options)
  const first = await authorize(f.held)
  const nonce = await authorize({ ...f.held, nonce: '3'.repeat(64) })
  const journal = await authorize({ ...f.held, journalDigest: '4'.repeat(64) })
  expect(nonce.receiptDigest).toBe(first.receiptDigest)
  expect(nonce.evidenceDigest).not.toBe(first.evidenceDigest)
  expect(journal.evidenceDigest).not.toBe(first.evidenceDigest)
})

test.each([false, true])('real receipt loader rehashes inert backup packet; tamper during collection = %s', async tamper => {
  const f = await fixture(), receipt = f.receipt
  await mkdir(receipt.backupDirectory)
  const files: Record<string, string> = {}
  for (const name of ['current-helper.exe', 'before-get.json', 'before-boot.json', 'legacy-runonce.json',
    'internet-settings.reg', 'backup.json', 'retirement.json', 'after-get.json', 'after-boot.json']) {
    const bytes = name === 'current-helper.exe' ? await readFile(f.options.helperPath)
      : name === 'legacy-runonce.json' ? Buffer.from('null\n')
      : name === 'retirement.json' ? Buffer.from(JSON.stringify({ kind: 'absence-observation', legacyRunOnce: null }))
      : Buffer.from(`inert fixture ${name}\n`)
    await writeFile(join(receipt.backupDirectory, name), bytes)
    files[name] = hash(bytes)
  }
  const manifest = JSON.stringify({ version: 1, id: receipt.id, userSid: receipt.userSid,
    endpoints: receipt.endpoints, helperPath: receipt.helperPath, helperDigest: receipt.helperDigest,
    collectorPath: receipt.collectorPath, collectorDigest: receipt.collectorDigest, appPath: receipt.appPath, appDigest: receipt.appDigest,
    before: receipt.before, after: receipt.after, files })
  await writeFile(join(receipt.backupDirectory, 'manifest.json'), manifest)
  receipt.backupDigest = hash(manifest)
  await writeFile(f.marker, JSON.stringify(receipt))
  const marker = await readFile(f.marker)
  const collect = async (checkpoint?: number) => {
    if (tamper) await writeFile(join(receipt.backupDirectory, 'before-get.json'), 'changed backup')
    return f.collect(checkpoint)
  }
  const admission = createInitialMigrationAuthorizer({ ...f.options, loadReceipt: undefined, collect })(f.held)
  if (tamper) await expect(admission).rejects.toThrow('Migration backup changed')
  else await expect(admission).resolves.toMatchObject({ receiptDigest: hash(marker) })
  expect(await readFile(f.marker)).toEqual(marker)
  expect(f.loadReceipt).not.toHaveBeenCalled()
})
