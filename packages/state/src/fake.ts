import type { LogEntry, Traffic } from '@tern/api'
import type { CommandInput, CommandName, CommandResult, StateBridge, StateSnapshot } from './index'

export function fakeSnapshot(overrides: Partial<StateSnapshot> = {}): StateSnapshot {
  return {
    version: 1,
    core: { status: 'running', error: null },
    settings: { mode: 'rule', mixedPort: 7890, allowLan: false, logLevel: 'info' },
    profiles: [
      {
        id: 'p1',
        name: '示例订阅',
        source: { kind: 'remote', url: 'https://example.com/sub' },
        updatedAt: Date.UTC(2026, 9, 29),
        lastError: null,
        subscriptionInfo: { upload: 1e9, download: 2e10, total: 1e11, expireAt: 1798732800 },
        serverUpdateIntervalHours: 12,
        userUpdateIntervalHours: null
      }
    ],
    activeProfileId: 'p1',
    proxyGroups: [{ name: '节点选择', type: 'Selector', now: '香港 01', all: ['香港 01', '日本 01', 'DIRECT'] }],
    proxies: {
      '香港 01': { name: '香港 01', type: 'Trojan', delay: 82 },
      '日本 01': { name: '日本 01', type: 'Vmess', delay: null },
      DIRECT: { name: 'DIRECT', type: 'Direct', delay: null }
    },
    systemProxy: { enabled: false },
    update: null,
    ...overrides
  }
}

/** In-memory StateBridge for UI development: records commands, lets tests push snapshots. */
export class FakeBridge implements StateBridge {
  calls: Array<{ name: CommandName; input: unknown }> = []
  private listeners = new Set<(s: StateSnapshot) => void>()
  readonly trafficListeners = new Set<(t: Traffic) => void>()
  readonly logListeners = new Set<(l: LogEntry) => void>()
  constructor(public snapshot: StateSnapshot = fakeSnapshot()) {}

  async getSnapshot() {
    return this.snapshot
  }
  subscribe(listener: (s: StateSnapshot) => void) {
    this.listeners.add(listener)
    return () => void this.listeners.delete(listener)
  }
  async run<K extends CommandName>(name: K, input: CommandInput<K>): Promise<CommandResult<K>> {
    this.calls.push({ name, input })
    return { ok: true, value: undefined as CommandResult<K> extends { value: infer V } ? V : never }
  }
  subscribeTraffic(listener: (t: Traffic) => void) {
    this.trafficListeners.add(listener)
    return () => void this.trafficListeners.delete(listener)
  }
  subscribeLogs(listener: (l: LogEntry) => void) {
    this.logListeners.add(listener)
    return () => void this.logListeners.delete(listener)
  }
  /** Test helpers: push live events. */
  emitTraffic(t: Traffic) {
    for (const l of this.trafficListeners) l(t)
  }
  emitLog(entry: LogEntry) {
    for (const l of this.logListeners) l(entry)
  }
  /** Test helper: replace the snapshot and notify subscribers. */
  publish(next: StateSnapshot) {
    this.snapshot = next
    for (const l of this.listeners) l(next)
  }
}
