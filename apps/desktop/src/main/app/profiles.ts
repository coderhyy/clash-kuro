import { readFile } from 'node:fs/promises'
import { isAbsolute } from 'node:path'
import { applyProfileUpdate, buildRuntimeConfig, type ControlChannel, type Platform, type Profile, type Settings } from '@kuro/core'

/** Original content of each Profile lives at `profiles/<id>.yaml`; only refresh ever replaces it (ADR-0003). */
export const contentFile = (id: string) => `profiles/${id}.yaml`

/**
 * Fetch (remote) or read (local) a Profile's original content, store it, and return updated metadata.
 * Remote: direct first, then once through Core's mixed-port. Rejects on failure with old content untouched.
 */
export function createProfileSource(deps: {
  platform: Platform
  userAgent: string
  isCoreRunning(): Promise<boolean>
  now?: () => number
  readLocal?: (path: string) => Promise<string>
}) {
  const now = deps.now ?? Date.now
  const readLocal = deps.readLocal ?? ((path: string) => readFile(path, 'utf8'))

  async function fetchRemote(url: string) {
    try {
      const direct = await deps.platform.fetchText(url, { viaCore: false, userAgent: deps.userAgent })
      if (direct.status >= 200 && direct.status < 300) return direct
      if (!await deps.isCoreRunning()) return direct
    } catch (error) {
      if (!await deps.isCoreRunning()) return { error: error instanceof Error ? error.message : String(error) }
    }
    try {
      return await deps.platform.fetchText(url, { viaCore: true, userAgent: deps.userAgent })
    } catch (error) {
      return { error: error instanceof Error ? error.message : String(error) }
    }
  }

  return {
    async refreshProfile(profile: Profile): Promise<Profile> {
      const previous = (await deps.platform.readFile(contentFile(profile.id))) ?? ''
      let result
      if (profile.source.kind === 'remote') result = await fetchRemote(profile.source.url)
      else {
        const path = profile.source.path
        if (!isAbsolute(path)) throw new Error('Local Profile path must be absolute')
        try {
          result = { status: 200, headers: {}, body: await readLocal(path) }
        } catch (error) {
          result = { error: error instanceof Error ? error.message : String(error) }
        }
      }
      const update = applyProfileUpdate(profile, previous, result, now())
      if (!update.ok) throw new Error(update.profile.lastError ?? 'Profile update failed')
      await deps.platform.writeFileAtomic(contentFile(profile.id), update.content)
      return update.profile
    },

    async buildRuntimeConfig(input: { profile: Profile; settings: Settings; controlChannel: ControlChannel }) {
      const content = await deps.platform.readFile(contentFile(input.profile.id))
      if (content === null) throw new Error('Profile content is missing; update the Profile first')
      return buildRuntimeConfig(content, input.settings, input.controlChannel)
    }
  }
}
