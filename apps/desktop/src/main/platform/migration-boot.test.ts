import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { fileURLToPath } from 'node:url'
import { collectBootEvidence, parseBootEvidence, verifyRestart, verifyNoKnownLegacyWriters, type BootEvidence } from './migration-boot'

beforeEach(() => { vi.spyOn(Date, 'now').mockReturnValue(Date.parse('2026-11-03T00:00:00Z')) })
afterEach(() => { vi.restoreAllMocks() })

function evidence(): BootEvidence {
  return { version: 2, userSid: 'S-1-5-21-1-2-3-1001', machineGuidSha256: 'e'.repeat(64), uptimeMs: '1555200000',
    collectedAt: '2026-11-02T00:00:00Z', lastBootUpTime: '2026-10-15T00:00:00Z',
    newest: { record: 100, digest: 'a'.repeat(64), fields: {} },
    kernel: { record: 80, digest: 'b'.repeat(64), fields: { StartTime: '2026-10-15T00:00:02Z' } },
    boot: { record: 79, digest: 'c'.repeat(64), fields: { BootType: '0' } }, checkpoint: null,
    legacyRunOnce: null, nativeRunOnce: null, knownWriters: [] }
}
function restarted(): BootEvidence {
  const result = evidence()
  result.uptimeMs = '60000'
  result.collectedAt = '2026-11-02T01:00:00Z'; result.lastBootUpTime = '2026-11-02T00:59:00Z'
  result.newest.record = 130
  result.kernel = { record: 120, digest: 'd'.repeat(64), fields: { StartTime: '2026-11-02T00:59:02Z' } }
  result.boot = { record: 119, digest: 'f'.repeat(64), fields: { BootType: '0' } }
  result.checkpoint = evidence().newest
  return result
}

test('strict native uptime decrease with same machine/account and retained event corroboration witnesses reset', () => {
  expect(verifyRestart(evidence(), restarted())).toBe(`120:${'d'.repeat(64)}`)
})

test('the comparison uses the completed preparation after checkpoint, not its initial before sample', () => {
  const receipt = { before: evidence(), after: evidence() }
  receipt.before.uptimeMs = '30000'
  expect(() => verifyRestart(receipt.before, restarted())).toThrow('strictly decrease')
  expect(() => verifyRestart(receipt.after, restarted())).not.toThrow()
})

test.each(['1555200000', '1555200001', '18446744073709551615'])(
  'equal or greater uptime %s denies even with apparently new startup events', uptimeMs => {
    expect(() => verifyRestart(evidence(), { ...restarted(), uptimeMs })).toThrow('strictly decrease')
  })

test('uint64 comparison is lossless above Number.MAX_SAFE_INTEGER and accepts a zero fresh sample', () => {
  const baseline = { ...evidence(), uptimeMs: '9007199254740993' }
  const observed = { ...restarted(), uptimeMs: '9007199254740992' }
  expect(() => verifyRestart(baseline, observed)).not.toThrow()
  expect(() => verifyRestart({ ...baseline, uptimeMs: observed.uptimeMs }, observed)).toThrow('strictly decrease')
  expect(() => verifyRestart({ ...baseline, uptimeMs: '18446744073709551615' }, observed)).not.toThrow()
  expect(() => verifyRestart(evidence(), { ...observed, uptimeMs: '0' })).not.toThrow()
  expect(() => verifyRestart({ ...baseline, uptimeMs: '0' }, { ...observed, uptimeMs: '0' })).toThrow('strictly decrease')
})

test('BootType and estimated boot wall times are not reset oracles or fallbacks', () => {
  for (const bootType of ['0', '1', '2', 'unknown', undefined]) {
    const observed = restarted()
    if (bootType === undefined) delete observed.boot.fields.BootType
    else observed.boot.fields.BootType = bootType
    observed.lastBootUpTime = evidence().lastBootUpTime
    observed.kernel.fields.StartTime = '2026-10-15T00:15:00Z'
    expect(() => verifyRestart(evidence(), observed)).not.toThrow()
    observed.uptimeMs = evidence().uptimeMs
    expect(() => verifyRestart(evidence(), observed)).toThrow('strictly decrease')
  }
})

test('a decreasing counter cannot bypass identity, event or checkpoint corroboration failures', () => {
  for (const change of [
    (v: BootEvidence) => { v.kernel = evidence().kernel },
    (v: BootEvidence) => { v.boot.record = evidence().newest.record },
    (v: BootEvidence) => { v.kernel.digest = evidence().kernel.digest },
    (v: BootEvidence) => { v.checkpoint = null },
    (v: BootEvidence) => { v.checkpoint!.record++ },
    (v: BootEvidence) => { v.checkpoint!.digest = 'f'.repeat(64) },
    (v: BootEvidence) => { v.userSid += '0' },
    (v: BootEvidence) => { v.machineGuidSha256 = 'f'.repeat(64) },
    (v: BootEvidence) => { v.newest.record = 1 },
    (v: BootEvidence) => {
      v.collectedAt = '2026-11-01T23:59:59Z'; v.lastBootUpTime = evidence().lastBootUpTime
      v.kernel = { ...v.kernel, fields: evidence().kernel.fields }
    },
  ]) {
    const value = restarted(); change(value)
    expect(() => verifyRestart(evidence(), value)).toThrow()
  }
})

test.each([undefined, null, 60000, -1, '', '-1', '+1', '01', '1.5', '1e3', ' 1', '1 ',
  '18446744073709551616', '9'.repeat(100)])('invalid or lossy uptime %j denies without coercion', uptimeMs => {
  expect(() => parseBootEvidence({ ...evidence(), uptimeMs })).toThrow('uptime')
})

test.each([undefined, null, '', 'machine-name', 'e'.repeat(63), 'e'.repeat(65), 'E'.repeat(64), 123])(
  'missing or malformed machine identity %j denies', machineGuidSha256 => {
    expect(() => parseBootEvidence({ ...evidence(), machineGuidSha256 })).toThrow('identity')
  })

test('old evidence contracts deny rather than inventing native uptime or machine identity', () => {
  const { uptimeMs: _uptime, machineGuidSha256: _machine, ...old } = evidence()
  expect(() => parseBootEvidence({ ...old, version: 1 })).toThrow()
  expect(() => parseBootEvidence(old)).toThrow()
  expect(() => parseBootEvidence({ ...evidence(), version: 1 })).toThrow()
})

test('untrusted JSON rejects missing, unknown and malformed structural fields', () => {
  for (const input of [null, [], {}, { ...evidence(), newest: {} }, { ...evidence(), version: 3 },
    { ...evidence(), collectedAt: 'nonsense' }, { ...evidence(), checkpoint: undefined },
    { ...evidence(), knownWriters: undefined }, { ...evidence(), legacyRunOnce: undefined },
    { ...evidence(), migrated: true }, { ...evidence(), uptimeSource: 'wall-clock' },
    { ...evidence(), kernel: { ...evidence().kernel, unknown: true } },
    { ...evidence(), boot: { ...evidence().boot, fields: { BootType: 0 } } },
    { ...evidence(), knownWriters: [{ pid: 123, name: 'writer', trusted: true }] }])
    expect(() => parseBootEvidence(input)).toThrow()
})

test('future and invalid timestamps fail safely, without a CIM/kernel agreement tolerance', () => {
  for (const change of [
    (v: BootEvidence) => { v.collectedAt = '2026-11-04T00:00:00Z' },
    (v: BootEvidence) => { v.lastBootUpTime = '2026-11-02T01:00:01Z' },
    (v: BootEvidence) => { v.kernel.fields.StartTime = '2026-11-02T01:00:01Z' },
    (v: BootEvidence) => { v.collectedAt = '2026-02-30T00:00:00Z' },
    (v: BootEvidence) => { v.collectedAt = '2026-11-02T24:00:00Z' },
  ]) {
    const value = restarted(); change(value)
    expect(() => parseBootEvidence(value)).toThrow()
  }
  expect(parseBootEvidence({ ...evidence(), collectedAt: '2026-11-02T00:00:00.1234567Z' }).uptimeMs).toBe(evidence().uptimeMs)
})

test.each([undefined, 0, false, {}, []])('unknown native registration state %j denies', nativeRunOnce => {
  expect(() => parseBootEvidence({ ...evidence(), nativeRunOnce })).toThrow('Unknown native RunOnce state')
})

test('missing native registration field denies the previous v2 contract', () => {
  const { nativeRunOnce: _native, ...old } = evidence()
  expect(() => parseBootEvidence(old)).toThrow('Unknown native RunOnce state')
})

test('initial migration screen rejects either registration and hash-named writers, without proving exclusion', () => {
  expect(() => verifyNoKnownLegacyWriters(evidence())).not.toThrow()
  for (const value of [{ ...evidence(), legacyRunOnce: '' },
    { ...evidence(), nativeRunOnce: '' },
    { ...evidence(), nativeRunOnce: `"C:\\retained\\${'a'.repeat(64)}.exe" recover` },
    { ...evidence(), knownWriters: [{ pid: 123, name: 'a'.repeat(64) }] },
    { ...evidence(), knownWriters: [{ pid: 123, name: 'A'.repeat(64) }] },
    { ...evidence(), knownWriters: [{ pid: 123, name: 'kuro-sysproxy' }] }])
    expect(() => verifyNoKnownLegacyWriters(value)).toThrow()
})

test('collector invokes only the read-only script and rejects query, diagnostics and contract failures', async () => {
  const exec = vi.fn().mockResolvedValue({ stdout: '\ufeff' + JSON.stringify(restarted()), stderr: '' })
  expect(await collectBootEvidence('collector.ps1', 'helper.exe', 100, exec)).toEqual(restarted())
  expect(exec).toHaveBeenCalledExactlyOnceWith('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'collector.ps1', '-Helper', 'helper.exe', '-CheckpointRecord', '100'])
  await expect(collectBootEvidence('collector.ps1', 'helper.exe', -1, exec)).rejects.toThrow()
  expect(exec).toHaveBeenCalledTimes(1)
  await expect(collectBootEvidence('collector.ps1', 'helper.exe', 100, async () => { throw new Error('access denied') })).rejects.toThrow('access denied')
  const timeout = Object.assign(new Error('collector timeout'), { code: 'ETIMEDOUT', signal: 'SIGTERM', killed: true })
  await expect(collectBootEvidence('collector.ps1', 'helper.exe', 100, async () => { throw timeout }))
    .rejects.toThrow('code=ETIMEDOUT, signal=SIGTERM, killed=true')
  for (const result of [{ stdout: '', stderr: '' }, { stdout: JSON.stringify(evidence()), stderr: 'warning' },
    { stdout: JSON.stringify({ ...restarted(), uptimeMs: 60000 }), stderr: '' }])
    await expect(collectBootEvidence('collector.ps1', 'helper.exe', 100, async () => result)).rejects.toThrow()
})

test.skipIf(process.platform !== 'win32' || process.env.KURO_READ_ONLY_BOOT_EVIDENCE !== '1')(
  'opt-in actual read-only collection preserves checkpoint and denies same-run reset', async () => {
    vi.restoreAllMocks()
    const script = fileURLToPath(new URL('../../../scripts/collect-migration-evidence.ps1', import.meta.url))
    const helper = fileURLToPath(new URL('../../../resources/win/x64/kuro-sysproxy.exe', import.meta.url))
    const baseline = await collectBootEvidence(script, helper)
    const observed = await collectBootEvidence(script, helper, baseline.newest.record)
    expect(observed.checkpoint?.digest).toBe(baseline.newest.digest)
    expect(observed.machineGuidSha256).toBe(baseline.machineGuidSha256)
    expect(BigInt(observed.uptimeMs)).toBeGreaterThanOrEqual(BigInt(baseline.uptimeMs))
    expect(() => verifyRestart(baseline, observed)).toThrow('strictly decrease')
  }, 25_000)
