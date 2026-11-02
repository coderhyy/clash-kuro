import { expect, test, vi } from 'vitest'
import { fileURLToPath } from 'node:url'
import { collectBootEvidence, parseBootEvidence, verifyRestart, verifyNoKnownLegacyWriters, type BootEvidence } from './migration-boot'

function evidence(): BootEvidence {
  return { version: 1, userSid: 'S-1-5-21-1-2-3-1001', collectedAt: '2026-11-02T00:00:00Z', lastBootUpTime: '2026-11-01T00:00:00Z',
    newest: { record: 100, digest: 'a'.repeat(64), fields: {} },
    kernel: { record: 80, digest: 'b'.repeat(64), fields: { StartTime: '2026-11-01T00:00:02Z' } },
    boot: { record: 79, digest: 'c'.repeat(64), fields: { BootType: '0' } }, checkpoint: null, legacyRunOnce: null, knownWriters: [] }
}
function restarted(): BootEvidence {
  const result = evidence()
  result.collectedAt = '2026-11-02T01:00:00Z'; result.lastBootUpTime = '2026-11-02T00:59:00Z'
  result.newest.record = 130
  result.kernel = { record: 120, digest: 'd'.repeat(64), fields: { StartTime: '2026-11-02T00:59:02Z' } }
  result.boot.record = 119; result.checkpoint = evidence().newest
  return result
}
test('full restart requires preserved checkpoint, new startup events and matching CIM evidence', () => {
  expect(verifyRestart(evidence(), restarted())).toBe(`120:${'d'.repeat(64)}`)
})
test('same boot, logoff, fast startup, resume and missing evidence cannot admit resident', () => {
  for (const change of [
    (v: BootEvidence) => { v.kernel = evidence().kernel },
    (v: BootEvidence) => { v.boot.fields.BootType = '1' },
    (v: BootEvidence) => { v.boot.fields.BootType = '2' },
    (v: BootEvidence) => { delete v.boot.fields.BootType },
    (v: BootEvidence) => { v.checkpoint = null },
    (v: BootEvidence) => { v.checkpoint!.digest = 'f'.repeat(64) },
    (v: BootEvidence) => { v.userSid += '0' },
    (v: BootEvidence) => { v.lastBootUpTime = evidence().lastBootUpTime },
    (v: BootEvidence) => { v.kernel.fields.StartTime = '2026-11-01T00:00:00Z' },
    (v: BootEvidence) => { v.newest.record = 1 },
  ]) {
    const value = restarted(); change(value)
    expect(() => verifyRestart(evidence(), value)).toThrow()
  }
})
test('untrusted JSON is validated before policy evaluation', () => {
  for (const input of [null, [], {}, { ...evidence(), newest: {} }, { ...evidence(), version: 2 },
    { ...evidence(), collectedAt: 'nonsense' }, { ...evidence(), checkpoint: undefined },
    { ...evidence(), knownWriters: undefined }, { ...evidence(), legacyRunOnce: undefined }])
    expect(() => parseBootEvidence(input)).toThrow()
})
test('known writers and even an empty legacy value prohibit migration', () => {
  expect(() => verifyNoKnownLegacyWriters(evidence())).not.toThrow()
  for (const value of [{ ...evidence(), legacyRunOnce: '' },
    { ...evidence(), knownWriters: [{ pid: 123, name: 'kuro-sysproxy' }] }])
    expect(() => verifyNoKnownLegacyWriters(value)).toThrow()
})
test('collector is read-only and rejects process/query failures without fallback', async () => {
  const exec = vi.fn().mockResolvedValue({ stdout: JSON.stringify(restarted()), stderr: '' })
  expect(await collectBootEvidence('collector.ps1', 100, exec)).toEqual(restarted())
  expect(exec).toHaveBeenCalledExactlyOnceWith('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'collector.ps1', '-CheckpointRecord', '100'])
  await expect(collectBootEvidence('collector.ps1', -1, exec)).rejects.toThrow()
  await expect(collectBootEvidence('collector.ps1', 100, async () => { throw new Error('access denied') })).rejects.toThrow('access denied')
})

test.skipIf(process.platform !== 'win32')('actual read-only collection preserves checkpoint and cannot prove a restart in the same run', async () => {
  const script = fileURLToPath(new URL('../../../scripts/collect-migration-evidence.ps1', import.meta.url))
  const before = await collectBootEvidence(script)
  const after = await collectBootEvidence(script, before.newest.record)
  expect(after.checkpoint?.digest).toBe(before.newest.digest)
  expect(() => verifyRestart(before, after)).toThrow('Full restart not verified')
}, 25_000)
