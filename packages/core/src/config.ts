import { parseDocument, stringify } from 'yaml'
import type { ControlChannel, Settings } from './index'

export type ParsedProfile = Record<string, unknown>
export type ProfileParseResult =
  | { ok: true; value: ParsedProfile }
  | { ok: false; error: string }

function isMapping(value: unknown): value is ParsedProfile {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Checks YAML structure only; mihomo -t remains the semantic validator. */
export function parseProfile(yaml: string): ProfileParseResult {
  try {
    const document = parseDocument(yaml, { merge: true })
    if (document.errors.length) {
      return { ok: false, error: `Invalid profile YAML: ${document.errors.map(e => e.message).join('; ')}` }
    }
    const value: unknown = document.toJS({ maxAliasCount: 100 })
    if (!isMapping(value) || Object.keys(value).length === 0) {
      return { ok: false, error: 'Profile must be a non-empty YAML mapping.' }
    }
    if ('profile' in value && !isMapping(value.profile)) {
      return { ok: false, error: 'The profile field must be a YAML mapping.' }
    }
    return { ok: true, value }
  } catch (error) {
    return { ok: false, error: `Invalid profile YAML: ${error instanceof Error ? error.message : String(error)}` }
  }
}

/** Returns a separate config; neither source YAML nor the parsed value is modified. */
export function buildRuntimeConfig(
  profile: string | ProfileParseResult,
  settings: Settings,
  controlChannel: ControlChannel
): string {
  const parsed = typeof profile === 'string' ? parseProfile(profile) : profile
  if (!parsed.ok) throw new Error(parsed.error)
  if (!Number.isInteger(settings.mixedPort) || settings.mixedPort < 1 || settings.mixedPort > 65535) {
    throw new Error('mixedPort must be an integer between 1 and 65535.')
  }
  const address = controlChannel.kind === 'unix' ? controlChannel.path : controlChannel.name
  if (!address.trim() || address.includes('\0')) throw new Error('Control Channel address must be non-empty and contain no NUL.')

  const config = { ...parsed.value }
  // Remove every controller variant so a subscription cannot re-enable TCP access.
  for (const key of Object.keys(config)) {
    if (key.startsWith('external-controller') || key === 'secret') delete config[key]
  }
  config.mode = settings.mode
  config['mixed-port'] = settings.mixedPort
  config['allow-lan'] = settings.allowLan
  config['log-level'] = settings.logLevel
  config.profile = { ...(isMapping(config.profile) ? config.profile : {}), 'store-selected': true }
  config[controlChannel.kind === 'unix' ? 'external-controller-unix' : 'external-controller-pipe'] = address
  return stringify(config)
}
