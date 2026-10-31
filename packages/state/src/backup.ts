import { parseOverride } from '@kuro/core'
import { validateSavedState, type SavedState } from './store'

export const BACKUP_FORMAT = 'clash-kuro-backup'
export const MAX_BACKUP_BYTES = 50 * 1024 * 1024

export interface Backup {
  format: typeof BACKUP_FORMAT
  version: 1
  createdAt: string
  settings: SavedState
  profiles: Record<string, string>
  override: string | null
}

export function backupProfileFile(id: string): string {
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new Error('Invalid Profile ID in Backup')
  return `profiles/${id}.yaml`
}

export function parseBackup(json: string): Backup {
  // Count UTF-8 bytes without a platform/DOM encoder (ADR-0001).
  let bytes = 0
  for (const character of json) {
    const code = character.codePointAt(0)!
    bytes += code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4
    if (bytes > MAX_BACKUP_BYTES) throw new Error('Backup exceeds 50 MB')
  }
  let value: unknown
  try { value = JSON.parse(json) } catch { throw new Error('Invalid Backup JSON') }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid Backup structure')
  const backup = value as Backup
  if (backup.format !== BACKUP_FORMAT) throw new Error('Invalid Backup format')
  if (backup.version !== 1) throw new Error('Unsupported Backup version')
  if (typeof backup.createdAt !== 'string' || !Number.isFinite(Date.parse(backup.createdAt))) throw new Error('Invalid Backup creation time')
  validateSavedState(backup.settings)
  if (!backup.profiles || typeof backup.profiles !== 'object' || Array.isArray(backup.profiles)) throw new Error('Invalid Backup Profile contents')
  if (Object.keys(backup.profiles).length !== backup.settings.profiles.length) throw new Error('Backup Profile IDs do not match contents')
  for (const profile of backup.settings.profiles) {
    backupProfileFile(profile.id)
    if (!Object.hasOwn(backup.profiles, profile.id)) throw new Error('Backup Profile IDs do not match contents')
    if (typeof backup.profiles[profile.id] !== 'string') throw new Error('Invalid Backup Profile content')
  }
  if (backup.override !== null && typeof backup.override !== 'string') throw new Error('Invalid Backup Override content')
  if (backup.override !== null) {
    const override = parseOverride(backup.override)
    if (!override.ok) throw new Error(`Invalid Backup Override: ${override.error}`)
  }
  return backup
}
