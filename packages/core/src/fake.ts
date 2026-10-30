import type { ControlChannel, FetchResult, Platform, SystemProxySettings, ValidationResult } from './index'

/** In-memory Platform for tests and UI development. Inspect or tweak the public fields. */
export class FakePlatform implements Platform {
  files = new Map<string, string>()
  runtimeConfig: string | null = null
  coreRunning = false
  systemProxy: SystemProxySettings | null = null
  validate: (yaml: string) => ValidationResult = () => ({ ok: true })
  responses = new Map<string, FetchResult>()
  fetchLog: Array<{ url: string; viaCore: boolean }> = []
  private resumeListeners = new Set<() => void>()

  async readFile(name: string) {
    return this.files.get(name) ?? null
  }
  async writeFileAtomic(name: string, data: string) {
    this.files.set(name, data)
  }
  async removeFile(name: string) {
    this.files.delete(name)
  }
  async applyRuntimeConfig(yaml: string) {
    const result = this.validate(yaml)
    if (result.ok) this.runtimeConfig = yaml
    return result
  }
  async startCore() {
    if (this.runtimeConfig === null) throw new Error('no runtime config')
    this.coreRunning = true
  }
  async stopCore() {
    this.coreRunning = false
  }
  async isCoreRunning() {
    return this.coreRunning
  }
  controlChannel(): ControlChannel {
    return { kind: 'unix', path: '/fake/mihomo.sock' }
  }
  async getSystemProxy() {
    return this.systemProxy
  }
  async setSystemProxy(settings: SystemProxySettings) {
    this.systemProxy = settings
  }
  async clearSystemProxy() {
    this.systemProxy = null
  }
  async fetchText(url: string, options: { viaCore: boolean; userAgent: string }) {
    this.fetchLog.push({ url, viaCore: options.viaCore })
    const res = this.responses.get(url)
    if (!res) throw new Error(`fake: no response for ${url}`)
    return res
  }
  onResume(listener: () => void) {
    this.resumeListeners.add(listener)
    return () => void this.resumeListeners.delete(listener)
  }
  /** Test helper: simulate a system resume. */
  resume() {
    for (const l of this.resumeListeners) l()
  }
}
