/** Pure admission policy. Evidence must be collected afresh by the migration coordinator,
 * not accepted from an app setting or a user-supplied "migrated" boolean.
 * This module alone does not grant admission or prove Windows boot identity.
 */
export interface MigrationEvidence {
  prepared: {
    userSid: string
    boot: string
    backupDigest: string
    helperDigest: string
    endpoints: readonly string[]
  }
  observed: {
    userSid: string
    boot: string
    backupDigest: string
    helperDigest: string
    legacyRegistration: 'absent' | 'present' | 'unknown'
    writerOwnership: 'exclusive' | 'busy' | 'unknown'
    priorRecovery: 'verified' | 'failed' | 'unknown'
    legacyProcesses: 'absent' | 'present' | 'unknown'
  }
}

const digest = /^[a-f0-9]{64}$/
const sid = /^S-1-5-21-\d+-\d+-\d+-\d+$/
const endpoint = /^127\.0\.0\.1:([1-9]\d{0,4})$/

export function checkMigrationEvidence(evidence: MigrationEvidence): void {
  const { prepared, observed } = evidence
  if (!sid.test(prepared.userSid) || prepared.userSid !== observed.userSid)
    throw new Error('Migration user identity mismatch')
  // Boot evidence is opaque here: the collector must reject missing/ambiguous/recycled identities.
  if (!prepared.boot || !observed.boot || prepared.boot === observed.boot)
    throw new Error('A verified restart after migration preparation is required')
  if (!digest.test(prepared.backupDigest) || prepared.backupDigest !== observed.backupDigest)
    throw new Error('Migration backup missing or changed')
  if (!digest.test(prepared.helperDigest) || prepared.helperDigest !== observed.helperDigest)
    throw new Error('Migration helper missing or changed; prepare again')
  if (!prepared.endpoints.length || prepared.endpoints.length > 8 ||
      new Set(prepared.endpoints).size !== prepared.endpoints.length ||
      prepared.endpoints.some(value => !endpoint.test(value) || Number(endpoint.exec(value)?.[1]) > 65535))
    throw new Error('Invalid migration endpoint inventory')
  if (observed.legacyRegistration !== 'absent') throw new Error('Legacy RunOnce not retired')
  if (observed.legacyProcesses !== 'absent') throw new Error('Legacy writer still present or uninspectable')
  if (observed.writerOwnership !== 'exclusive') throw new Error('Recovery ownership unavailable')
  if (observed.priorRecovery !== 'verified') throw new Error('Prior recovery not verified')
}
