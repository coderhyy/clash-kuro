import { execCommand, type Exec } from './system-proxy'

interface BootEvent { record: number; digest: string; fields: Record<string, string> }
export interface BootEvidence {
  version: 2; userSid: string; machineGuidSha256: string; uptimeMs: string
  collectedAt: string; lastBootUpTime: string
  newest: BootEvent; kernel: BootEvent; boot: BootEvent; checkpoint: BootEvent | null
  legacyRunOnce: string | null; nativeRunOnce: string | null; knownWriters: { pid: number; name: string }[]
}
function object(value: unknown, keys?: readonly string[]): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid migration evidence object')
  if (keys && Object.keys(value).some(key => !keys.includes(key))) throw new Error('Unknown migration evidence field')
  return value as Record<string, unknown>
}
function time(value: unknown): number {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$/.test(value) ||
      !Number.isFinite(Date.parse(value)) || new Date(value).toISOString().slice(0, 19) !== value.slice(0, 19))
    throw new Error('Invalid migration evidence time')
  return Date.parse(value)
}
function event(value: unknown): BootEvent {
  const row = object(value, ['record', 'digest', 'fields']), fields = object(row.fields)
  if (typeof row.record !== 'number' || !Number.isSafeInteger(row.record) || row.record <= 0 ||
      typeof row.digest !== 'string' || !/^[a-f0-9]{64}$/.test(row.digest) ||
      Object.values(fields).some(value => typeof value !== 'string')) throw new Error('Invalid migration event')
  return { record: row.record, digest: row.digest, fields: fields as Record<string, string> }
}
export function parseBootEvidence(input: unknown): BootEvidence {
  const row = object(input, ['version', 'userSid', 'machineGuidSha256', 'uptimeMs', 'collectedAt', 'lastBootUpTime',
    'newest', 'kernel', 'boot', 'checkpoint', 'legacyRunOnce', 'nativeRunOnce', 'knownWriters'])
  if (row.version !== 2 || typeof row.userSid !== 'string' || !/^S-1-5-21-\d+-\d+-\d+-\d+$/.test(row.userSid) ||
      typeof row.machineGuidSha256 !== 'string' || !/^[a-f0-9]{64}$/.test(row.machineGuidSha256))
    throw new Error('Invalid migration identity')
  if (typeof row.uptimeMs !== 'string' || !/^(0|[1-9]\d{0,19})$/.test(row.uptimeMs) || BigInt(row.uptimeMs) > 18446744073709551615n)
    throw new Error('Invalid native uptime evidence')
  const collectedAt = time(row.collectedAt)
  if (collectedAt > Date.now() || time(row.lastBootUpTime) > collectedAt) throw new Error('Future migration evidence time')
  if (row.legacyRunOnce !== null && typeof row.legacyRunOnce !== 'string') throw new Error('Unknown legacy RunOnce state')
  if (row.nativeRunOnce !== null && typeof row.nativeRunOnce !== 'string') throw new Error('Unknown native RunOnce state')
  if (!Array.isArray(row.knownWriters)) throw new Error('Unknown writer inventory')
  const knownWriters = row.knownWriters.map(value => {
    const writer = object(value, ['pid', 'name'])
    if (typeof writer.pid !== 'number' || !Number.isSafeInteger(writer.pid) || writer.pid <= 0 ||
        typeof writer.name !== 'string' || !writer.name) throw new Error('Invalid writer inventory')
    return { pid: writer.pid, name: writer.name }
  })
  const result = { version: 2 as const, userSid: row.userSid, machineGuidSha256: row.machineGuidSha256, uptimeMs: row.uptimeMs,
    collectedAt: row.collectedAt as string,
    lastBootUpTime: row.lastBootUpTime as string, newest: event(row.newest), kernel: event(row.kernel),
    boot: event(row.boot), checkpoint: row.checkpoint === null ? null : event(row.checkpoint),
    legacyRunOnce: row.legacyRunOnce, nativeRunOnce: row.nativeRunOnce, knownWriters }
  if (time(result.kernel.fields.StartTime) > collectedAt) throw new Error('Future kernel event time')
  if (result.newest.record < Math.max(result.kernel.record, result.boot.record)) throw new Error('Inconsistent System event inventory')
  return result
}

/** Initial migration screen only, not an active native recovery policy or proof of writer exclusion. */
export function verifyNoKnownLegacyWriters(evidence: BootEvidence): void {
  evidence = parseBootEvidence(evidence)
  if (evidence.legacyRunOnce !== null) throw new Error('Legacy RunOnce remains registered')
  if (evidence.nativeRunOnce !== null) throw new Error('Native recovery registration exists; initial migration unsupported, preserve evidence')
  if (evidence.knownWriters.length) throw new Error('Known proxy writer processes remain; do not migrate')
}

/** Compare the completed preparation receipt.after with a fresh observation, never receipt.before.
 * A separately recorded, controlled manual Restart attestation remains a prerequisite, not inferred here.
 * This reset witness does not grant admission or prove current writer ownership.
 */
export function verifyRestart(baseline: BootEvidence, observed: BootEvidence): string {
  baseline = parseBootEvidence(baseline); observed = parseBootEvidence(observed)
  if (baseline.userSid !== observed.userSid) throw new Error('Migration user changed')
  if (baseline.machineGuidSha256 !== observed.machineGuidSha256) throw new Error('Migration machine changed')
  if (BigInt(observed.uptimeMs) >= BigInt(baseline.uptimeMs))
    throw new Error('Native uptime did not strictly decrease; restart not verified')
  if (observed.checkpoint?.record !== baseline.newest.record || observed.checkpoint.digest !== baseline.newest.digest)
    throw new Error('System log checkpoint missing or replaced; prepare again')
  // New records corroborate the counter reset; neither BootType nor wall-clock agreement proves it.
  if (observed.kernel.record <= baseline.newest.record || observed.boot.record <= baseline.newest.record ||
      observed.kernel.digest === baseline.kernel.digest || time(observed.collectedAt) < time(baseline.collectedAt))
    throw new Error('Restart corroboration is stale or inconsistent')
  return `${observed.kernel.record}:${observed.kernel.digest}`
}

export async function collectBootEvidence(script: string, checkpoint?: number, exec: Exec = execCommand): Promise<BootEvidence> {
  if (checkpoint !== undefined && (!Number.isSafeInteger(checkpoint) || checkpoint <= 0)) throw new Error('Invalid checkpoint record')
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script]
  if (checkpoint !== undefined) args.push('-CheckpointRecord', String(checkpoint))
  const { stdout, stderr } = await exec('powershell.exe', args)
  if (stderr.trim()) throw new Error('Migration collector reported diagnostics; evidence unverified')
  return parseBootEvidence(JSON.parse(stdout.replace(/^\uFEFF/, '')))
}
