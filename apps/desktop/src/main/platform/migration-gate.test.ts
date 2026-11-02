import { expect, test } from 'vitest'
import { checkMigrationEvidence, type MigrationEvidence } from './migration-gate'

function evidence(): MigrationEvidence {
  return {
    prepared: { userSid: 'S-1-5-21-1-2-3-1001', boot: 'collector-boot-a', backupDigest: 'a'.repeat(64),
      helperDigest: 'b'.repeat(64), endpoints: ['127.0.0.1:7891'] },
    observed: { userSid: 'S-1-5-21-1-2-3-1001', boot: 'collector-boot-b', backupDigest: 'a'.repeat(64),
      helperDigest: 'b'.repeat(64), legacyRegistration: 'absent', writerOwnership: 'exclusive',
      priorRecovery: 'verified', legacyProcesses: 'absent' },
  }
}

test('policy accepts all verified conditions without rewriting evidence', () => {
  const value = evidence(), before = structuredClone(value)
  expect(() => checkMigrationEvidence(value)).not.toThrow()
  expect(value).toEqual(before)
})

test('same boot, wrong identity, changed helper and changed backup all block', () => {
  for (const patch of [{ boot: 'collector-boot-a' }, { boot: '' }, { userSid: 'S-1-5-21-1-2-3-1002' },
    { helperDigest: 'c'.repeat(64) }, { backupDigest: 'c'.repeat(64) }]) {
    const value = evidence()
    Object.assign(value.observed, patch)
    expect(() => checkMigrationEvidence(value)).toThrow()
  }
})

test('every failed or unknown post-restart condition blocks', () => {
  for (const field of ['legacyRegistration', 'legacyProcesses', 'writerOwnership', 'priorRecovery'] as const) {
    for (const result of ['unknown', field === 'writerOwnership' ? 'busy' : field === 'priorRecovery' ? 'failed' : 'present']) {
      const value = evidence()
      Object.assign(value.observed, { [field]: result })
      expect(() => checkMigrationEvidence(value)).toThrow()
    }
  }
})

test('malformed, duplicate or oversized endpoint inventory blocks', () => {
  for (const endpoints of [[], ['other:7891'], ['127.0.0.1:0'], ['127.0.0.1:65536'],
    ['127.0.0.1:7891', '127.0.0.1:7891'], Array.from({ length: 9 }, (_, i) => `127.0.0.1:${i + 1}`)]) {
    const value = evidence()
    value.prepared.endpoints = endpoints
    expect(() => checkMigrationEvidence(value)).toThrow()
  }
})
