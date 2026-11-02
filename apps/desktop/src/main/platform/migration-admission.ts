import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { collectBootEvidence, parseBootEvidence, verifyNoKnownLegacyWriters, verifyRestart } from './migration-boot'
import { checkMigrationReplayEvidence } from './migration-gate'
import type { MigrationPreparationOptions } from './migration-preparation'
import { readPreparedMigration } from './migration-receipt'
import type { AuthorizeResident, ResidentReservation } from './resident-client'

export interface InitialMigrationAdmissionOptions extends Pick<MigrationPreparationOptions, 'dataDir' | 'helperPath' | 'collectorPath' | 'appPath'> {
  confirmControlledRestart: boolean
  loadReceipt?: typeof readPreparedMigration
  collect?: MigrationPreparationOptions['collect']
}

const hash = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex')

function verifyReservation(reservation: Readonly<ResidentReservation>): void {
  if (!Number.isSafeInteger(reservation.pid) || reservation.pid <= 0 || reservation.pid > 0xffffffff ||
      reservation.pid === process.pid || ![reservation.nonce, reservation.helperDigest, reservation.journalDigest]
        .every(value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)))
    throw new Error('Invalid native reservation identity')
}

/** Candidate prerequisites only: app startup denies first admission until legacy launch exclusion is resolved.
 * Pass only as residentClient's authorize callback for its validated, currently held native exclusive
 * reservation. A supplied reservation object alone is not ownership proof. This authorizes initial
 * replay only; caller holds the app lock and keeps the coordinator free of Core/proxy writers.
 * Native replay acknowledgement is still required before Core or proxy operations.
 */
export function createInitialMigrationAuthorizer(options: InitialMigrationAdmissionOptions): AuthorizeResident {
  const load = options.loadReceipt ?? readPreparedMigration
  const collect = options.collect ?? ((checkpoint?: number) => collectBootEvidence(options.collectorPath, options.helperPath, checkpoint))
  return async reservation => {
    if (options.confirmControlledRestart !== true) throw new Error('Explicit controlled Restart confirmation is required')
    verifyReservation(reservation)
    if (!Array.isArray(reservation.priorEndpoints) || reservation.priorEndpoints.length !== 0)
      throw new Error('Initial migration requires an empty native prior endpoint inventory')
    if (reservation.admissionReceiptDigest !== null)
      throw new Error('Initial migration requires explicitly uninitialized native admission provenance')
    const held = { ...reservation, priorEndpoints: [...reservation.priorEndpoints], initialEndpoints: [...reservation.initialEndpoints] }
    const marker = join(options.dataDir, 'proxy-migration.json')
    const receiptDigest = hash(await readFile(marker))
    const receipt = structuredClone(await load(options.dataDir, options.helperPath, options))
    if (!isDeepStrictEqual(held.initialEndpoints, receipt.endpoints))
      throw new Error('Initial native endpoint inventory differs from the prepared receipt')
    const helperDigest = hash(await readFile(options.helperPath))
    if (held.userSid !== receipt.userSid || held.helperDigest !== helperDigest || helperDigest !== receipt.helperDigest)
      throw new Error('Native reservation does not match the prepared user or current helper')
    const before = parseBootEvidence(receipt.before), baseline = parseBootEvidence(receipt.after)
    if (before.nativeRunOnce !== null) throw new Error('Initial preparation contains native recovery registration')
    verifyNoKnownLegacyWriters(baseline)

    const observed = parseBootEvidence(await collect(baseline.newest.record))
    verifyNoKnownLegacyWriters({ ...observed,
      knownWriters: observed.knownWriters.filter(writer => writer.pid !== process.pid && writer.pid !== held.pid) })
    const restart = verifyRestart(baseline, observed)
    const current = await load(options.dataDir, options.helperPath, options)
    if (!isDeepStrictEqual(receipt, current) || hash(await readFile(marker)) !== receiptDigest ||
        hash(await readFile(options.helperPath)) !== helperDigest)
      throw new Error('Migration receipt, marker or helper changed during admission collection')

    checkMigrationReplayEvidence({
      prepared: { userSid: receipt.userSid, boot: `${baseline.kernel.record}:${baseline.kernel.digest}`,
        backupDigest: receipt.backupDigest, helperDigest: receipt.helperDigest, endpoints: receipt.endpoints },
      observed: { userSid: observed.userSid, boot: restart, backupDigest: current.backupDigest, helperDigest,
        legacyRegistration: 'absent', legacyProcesses: 'absent', writerOwnership: 'exclusive' },
    })
    return { receiptDigest, evidenceDigest: hash(JSON.stringify({ receiptDigest, reservation: held, observed, restart })) }
  }
}

/** An existing native-validated v2 header carries the initial admission, not a new reboot claim.
 * This is still only replay permission: helper ownership and timely native replay must survive.
 */
export function createMigrationAuthorizer(options: InitialMigrationAdmissionOptions & { retainedHelper: string }): AuthorizeResident {
  const initial = createInitialMigrationAuthorizer(options)
  const load = options.loadReceipt ?? readPreparedMigration
  const collect = options.collect ?? (() => collectBootEvidence(options.collectorPath, options.helperPath))
  return async reservation => {
    if (reservation.admissionReceiptDigest === null) return initial(reservation)
    verifyReservation(reservation)
    if (!Array.isArray(reservation.initialEndpoints) || reservation.initialEndpoints.length !== 0)
      throw new Error('Existing native admission cannot seed another initial endpoint inventory')
    if (typeof reservation.admissionReceiptDigest !== 'string' || !/^[a-f0-9]{64}$/.test(reservation.admissionReceiptDigest))
      throw new Error('Native admission provenance unavailable')
    const marker = join(options.dataDir, 'proxy-migration.json')
    const receiptDigest = hash(await readFile(marker))
    if (receiptDigest !== reservation.admissionReceiptDigest) throw new Error('Native admission belongs to another migration receipt')
    const receipt = structuredClone(await load(options.dataDir, options.helperPath, options))
    const helperDigest = hash(await readFile(options.helperPath))
    if (receipt.userSid !== reservation.userSid || receipt.helperDigest !== helperDigest || helperDigest !== reservation.helperDigest)
      throw new Error('Native admission user/helper binding changed; no automatic upgrade or replay')
    const observed = parseBootEvidence(await collect())
    if (observed.userSid !== receipt.userSid || observed.machineGuidSha256 !== receipt.after.machineGuidSha256)
      throw new Error('Previously admitted migration identity changed')
    const command = `"${options.retainedHelper}" recover-admitted`
    if (observed.nativeRunOnce !== null && observed.nativeRunOnce !== command)
      throw new Error('Native recovery registration belongs to a different helper or command')
    verifyNoKnownLegacyWriters({ ...observed, nativeRunOnce: null,
      knownWriters: observed.knownWriters.filter(writer => writer.pid !== process.pid && writer.pid !== reservation.pid) })
    if (!isDeepStrictEqual(receipt, await load(options.dataDir, options.helperPath, options)) ||
        hash(await readFile(marker)) !== receiptDigest || hash(await readFile(options.helperPath)) !== helperDigest)
      throw new Error('Migration evidence changed during active admission')
    return { receiptDigest, evidenceDigest: hash(JSON.stringify({ receiptDigest, reservation, observed })) }
  }
}
