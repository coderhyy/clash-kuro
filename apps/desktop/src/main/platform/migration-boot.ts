import { execCommand, type Exec } from './system-proxy'

interface BootEvent { record: number; digest: string; fields: Record<string, string> }
export interface BootEvidence {
  version: 1; userSid: string; collectedAt: string; lastBootUpTime: string
  newest: BootEvent; kernel: BootEvent; boot: BootEvent; checkpoint: BootEvent | null
  legacyRunOnce: string | null; knownWriters: { pid: number; name: string }[]
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid migration evidence object')
  return value as Record<string, unknown>
}
function time(value: unknown): number {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT[\d:.]+Z$/.test(value) || !Number.isFinite(Date.parse(value)))
    throw new Error('Invalid migration evidence time')
  return Date.parse(value)
}
function event(value: unknown): BootEvent {
  const row = object(value), fields = object(row.fields)
  if (typeof row.record !== 'number' || !Number.isSafeInteger(row.record) || row.record <= 0 ||
      typeof row.digest !== 'string' || !/^[a-f0-9]{64}$/.test(row.digest) ||
      Object.values(fields).some(value => typeof value !== 'string')) throw new Error('Invalid migration event')
  return { record: row.record, digest: row.digest, fields: fields as Record<string, string> }
}
export function parseBootEvidence(input: unknown): BootEvidence {
  const row = object(input)
  if (row.version !== 1 || typeof row.userSid !== 'string' || !/^S-1-5-21-\d+-\d+-\d+-\d+$/.test(row.userSid))
    throw new Error('Invalid migration identity')
  time(row.collectedAt); time(row.lastBootUpTime)
  if (row.legacyRunOnce !== null && typeof row.legacyRunOnce !== 'string') throw new Error('Unknown legacy RunOnce state')
  if (!Array.isArray(row.knownWriters)) throw new Error('Unknown writer inventory')
  const knownWriters = row.knownWriters.map(value => {
    const writer = object(value)
    if (typeof writer.pid !== 'number' || !Number.isSafeInteger(writer.pid) || writer.pid <= 0 ||
        typeof writer.name !== 'string' || !writer.name) throw new Error('Invalid writer inventory')
    return { pid: writer.pid, name: writer.name }
  })
  const result = { version: 1 as const, userSid: row.userSid, collectedAt: row.collectedAt as string,
    lastBootUpTime: row.lastBootUpTime as string, newest: event(row.newest), kernel: event(row.kernel),
    boot: event(row.boot), checkpoint: row.checkpoint === null ? null : event(row.checkpoint),
    legacyRunOnce: row.legacyRunOnce, knownWriters }
  time(result.kernel.fields.StartTime)
  if (result.newest.record < Math.max(result.kernel.record, result.boot.record)) throw new Error('Inconsistent System event inventory')
  return result
}

export function verifyNoKnownLegacyWriters(evidence: BootEvidence): void {
  evidence = parseBootEvidence(evidence)
  if (evidence.legacyRunOnce !== null) throw new Error('Legacy RunOnce remains registered')
  if (evidence.knownWriters.length) throw new Error('Known proxy writer processes remain; do not migrate')
}

/** Logs provide continuity evidence, not a substitute for the controlled, user-performed restart. */
export function verifyRestart(before: BootEvidence, after: BootEvidence): string {
  before = parseBootEvidence(before); after = parseBootEvidence(after)
  if (before.userSid !== after.userSid) throw new Error('Migration user changed')
  if (after.checkpoint?.record !== before.newest.record || after.checkpoint.digest !== before.newest.digest)
    throw new Error('System log checkpoint missing or replaced; prepare again')
  if (after.kernel.record <= before.newest.record || after.boot.record <= before.newest.record ||
      after.kernel.digest === before.kernel.digest || after.boot.fields.BootType !== '0')
    throw new Error('Full restart not verified; logoff, sleep and fast startup do not qualify')
  const start = time(after.kernel.fields.StartTime)
  if (start <= time(before.collectedAt) || start > time(after.collectedAt) ||
      time(after.lastBootUpTime) === time(before.lastBootUpTime) ||
      Math.abs(start - time(after.lastBootUpTime)) > 10_000)
    throw new Error('Kernel/CIM boot evidence is inconsistent; resident remains disabled')
  return `${after.kernel.record}:${after.kernel.digest}`
}

export async function collectBootEvidence(script: string, checkpoint?: number, exec: Exec = execCommand): Promise<BootEvidence> {
  if (checkpoint !== undefined && (!Number.isSafeInteger(checkpoint) || checkpoint <= 0)) throw new Error('Invalid checkpoint record')
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script]
  if (checkpoint !== undefined) args.push('-CheckpointRecord', String(checkpoint))
  const { stdout } = await exec('powershell.exe', args)
  return parseBootEvidence(JSON.parse(stdout.replace(/^\uFEFF/, '')))
}
