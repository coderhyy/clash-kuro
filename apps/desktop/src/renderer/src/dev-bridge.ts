import { FakeBridge, fakeSnapshot } from '@tern/state/fake'
import type {
  CommandInput,
  CommandName,
  CommandOutput,
  CommandResult
} from '@tern/state'
import { t } from './i18n/zh-CN'

// shortcut: development commands simulate state only; real I/O belongs to the main process.
export class DevBridge extends FakeBridge {
  constructor() {
    super(fakeSnapshot())
    // Demo stream so the live panel has something to show without a Core.
    setInterval(() => {
      if (this.snapshot.core.status !== 'running') return
      this.emitTraffic({ up: Math.round(Math.random() * 40_000), down: Math.round(Math.random() * 400_000) })
      if (Math.random() < 0.3) this.emitLog({ level: 'info', payload: `[TCP] 127.0.0.1 --> example.com:443 match Match using 节点选择[香港 01]` })
    }, 1000)
  }

  private profile(id: string) {
    const profile = this.snapshot.profiles.find((profile) => profile.id === id)
    if (!profile) throw new Error(t('notFound'))
    return profile
  }

  private handlers: {
    [K in CommandName]: (input: CommandInput<K>) => CommandOutput<K>
  } = {
    setMode: ({ mode }) => {
      this.snapshot = {
        ...this.snapshot,
        settings: { ...this.snapshot.settings, mode }
      }
    },
    selectProxy: ({ group, proxy }) => {
      const target = this.snapshot.proxyGroups.find(
        (item) => item.name === group
      )
      if (!target?.all.includes(proxy)) throw new Error(t('invalidProxy'))
      this.snapshot = {
        ...this.snapshot,
        proxyGroups: this.snapshot.proxyGroups.map((item) =>
          item.name === group ? { ...item, now: proxy } : item
        )
      }
    },
    setSystemProxy: ({ enabled }) => {
      this.snapshot = {
        ...this.snapshot,
        systemProxy: enabled ? { enabled: true } : { enabled: false }
      }
    },
    importProfile: ({ name, source }) => {
      const profileId = crypto.randomUUID()
      this.snapshot = {
        ...this.snapshot,
        profiles: [
          ...this.snapshot.profiles,
          {
            id: profileId,
            name,
            source,
            updatedAt: Date.now(),
            lastError: null,
            subscriptionInfo: null,
            serverUpdateIntervalHours: null,
            userUpdateIntervalHours: null
          }
        ]
      }
      return { profileId }
    },
    updateProfile: ({ profileId }) => {
      this.profile(profileId)
      this.snapshot = {
        ...this.snapshot,
        profiles: this.snapshot.profiles.map((item) =>
          item.id === profileId
            ? { ...item, updatedAt: Date.now(), lastError: null }
            : item
        )
      }
    },
    removeProfile: ({ profileId }) => {
      this.profile(profileId)
      this.snapshot = {
        ...this.snapshot,
        profiles: this.snapshot.profiles.filter(
          (item) => item.id !== profileId
        ),
        activeProfileId:
          this.snapshot.activeProfileId === profileId
            ? null
            : this.snapshot.activeProfileId
      }
    },
    setActiveProfile: ({ profileId }) => {
      this.profile(profileId)
      this.snapshot = { ...this.snapshot, activeProfileId: profileId }
    },
    updateSettings: ({ settings, profileUpdateIntervalHours: interval }) => {
      if (interval) this.profile(interval.profileId)
      this.snapshot = {
        ...this.snapshot,
        settings: { ...this.snapshot.settings, ...settings },
        profiles: this.snapshot.profiles.map((item) =>
          item.id === interval?.profileId
            ? { ...item, userUpdateIntervalHours: interval.hours }
            : item
        )
      }
    },
    startCore: () => {
      this.snapshot = {
        ...this.snapshot,
        core: { status: 'running', error: null }
      }
    },
    stopCore: () => {
      this.snapshot = {
        ...this.snapshot,
        core: { status: 'stopped', error: null },
        systemProxy: { enabled: false }
      }
    },
    openWindow: () => {},
    quit: () => {}
  }

  override async run<K extends CommandName>(
    name: K,
    input: CommandInput<K>
  ): Promise<CommandResult<K>> {
    this.calls.push({ name, input })
    try {
      const value = this.handlers[name](input)
      this.publish({ ...this.snapshot, version: this.snapshot.version + 1 })
      return { ok: true, value }
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error)
      }
    }
  }
}
