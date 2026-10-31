import { expect, test } from 'vitest'
import { fakeSnapshot } from './fake'
import { MAX_BACKUP_BYTES, parseBackup } from './index'

function backup() {
  const { settings, profiles, activeProfileId } = fakeSnapshot()
  return {
    format: 'clash-kuro-backup', version: 1, createdAt: '2026-10-31T00:00:00.000Z',
    settings: { settings, profiles, activeProfileId, language: 'en', future: { enabled: true } },
    profiles: { p1: 'proxies: []\n' }, override: null
  }
}

test('parses a Backup without discarding unknown settings.json fields', () => {
  const data = backup()
  expect(parseBackup(JSON.stringify(data))).toEqual(data)
})

test.each([
  ['format', { format: 'other' }, 'format'],
  ['version', { version: 2 }, 'version'],
  ['creation time', { createdAt: 'not a date' }, 'creation time'],
  ['missing state', { settings: null }, 'saved state'],
  ['missing settings', { settings: { ...backup().settings, settings: null } }, 'settings'],
  ['Settings', { settings: { ...backup().settings, settings: { ...backup().settings.settings, mixedPort: 0 } } }, 'mixed-port'],
  ['Profiles', { settings: { ...backup().settings, profiles: {} } }, 'saved Profiles'],
  ['Profile', { settings: { ...backup().settings, profiles: [{ ...backup().settings.profiles[0], name: '' }] } }, 'Invalid Profile'],
  ['duplicate IDs', { settings: { ...backup().settings, profiles: [backup().settings.profiles[0], backup().settings.profiles[0]] } }, 'Duplicate Profile IDs'],
  ['Active Profile', { settings: { ...backup().settings, activeProfileId: 'missing' } }, 'Active Profile'],
  ['missing content', { profiles: {} }, 'IDs do not match'],
  ['extra content', { profiles: { p1: '', extra: '' } }, 'IDs do not match'],
  ['different ID', { profiles: { other: '' } }, 'IDs do not match'],
  ['non-string content', { profiles: { p1: 42 } }, 'Profile content'],
  ['null contents', { profiles: null }, 'Profile contents'],
  ['array contents', { profiles: [] }, 'Profile contents'],
  ['Override', { override: {} }, 'Override content'],
  ['missing Override', { override: undefined }, 'Override content']
])('rejects invalid %s', (_name, patch, error) => {
  expect(() => parseBackup(JSON.stringify({ ...backup(), ...patch }))).toThrow(error)
})

test.each(['../settings', 'a/b', 'a\\b', 'C:escape', 'a\0b', '.', '..'])('rejects unsafe Profile ID %j before file access', (id) => {
  const data = backup()
  data.settings.profiles[0]!.id = id
  data.settings.activeProfileId = id
  expect(() => parseBackup(JSON.stringify({ ...data, profiles: { [id]: '' } }))).toThrow('Invalid Profile ID')
})

test('does not treat inherited object properties as Profile content', () => {
  const data = backup()
  data.settings.profiles[0]!.id = 'toString'
  data.settings.activeProfileId = 'toString'
  expect(() => parseBackup(JSON.stringify({ ...data, profiles: { p1: '' } }))).toThrow('IDs do not match')
})

test.each(['broken JSON', 'null', '[]', '42'])('rejects malformed Backup %s with a readable error', (json) => {
  expect(() => parseBackup(json)).toThrow(/Invalid Backup/)
})

test('accepts empty storage, empty content and optional Override text without interpreting YAML', () => {
  const data = backup()
  expect(parseBackup(JSON.stringify({ ...data, profiles: { p1: '' }, override: 'not validated as YAML' })).override).toBe('not validated as YAML')
  expect(parseBackup(JSON.stringify({ ...data, settings: { ...data.settings, profiles: [], activeProfileId: null }, profiles: {} })).settings.profiles).toEqual([])
})

test('rejects Backup files over 50 MB, counting UTF-8 rather than UTF-16 units', () => {
  expect(() => parseBackup(' '.repeat(MAX_BACKUP_BYTES + 1))).toThrow('50 MB')
  const data = { ...backup(), override: '备'.repeat(Math.floor(MAX_BACKUP_BYTES / 3)) }
  expect(() => parseBackup(JSON.stringify(data))).toThrow('50 MB')
})
