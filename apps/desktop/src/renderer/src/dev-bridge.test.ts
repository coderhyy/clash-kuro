import { describe, expect, it } from 'vitest'
import { DevBridge } from './dev-bridge'

describe('interactive development bridge', () => {
  it('runs the main UI flow using immutable snapshots', async () => {
    const bridge = new DevBridge()
    const before = await bridge.getSnapshot()
    await bridge.run('setMode', { mode: 'global' })
    await bridge.run('setSystemProxy', { enabled: true })
    await bridge.run('selectProxy', { group: '节点选择', proxy: '日本 01' })
    expect(before.settings.mode).toBe('rule')
    expect(bridge.snapshot.settings.mode).toBe('global')
    expect(bridge.snapshot.proxyGroups[0]?.now).toBe('日本 01')
    const imported = await bridge.run('importProfile', {
      name: '本地测试',
      source: { kind: 'local', path: '/tmp/demo.yaml' }
    })
    expect(imported.ok).toBe(true)
    if (!imported.ok) throw new Error(imported.error)
    const profileId = imported.value.profileId
    await bridge.run('setActiveProfile', { profileId })
    await bridge.run('updateSettings', {
      settings: { mixedPort: 7891 },
      profileUpdateIntervalHours: { profileId, hours: 6 }
    })
    await bridge.run('updateProfile', { profileId })
    expect(
      bridge.snapshot.profiles.find((item) => item.id === profileId)
        ?.userUpdateIntervalHours
    ).toBe(6)
    await bridge.run('removeProfile', { profileId })
    expect(bridge.snapshot.activeProfileId).toBeNull()
    await bridge.run('stopCore', {})
    expect(bridge.snapshot.systemProxy.enabled).toBe(false)
    await bridge.run('startCore', {})
    expect(bridge.snapshot.core.status).toBe('running')
    expect(bridge.snapshot.version).toBeGreaterThan(before.version)
  })
  it('returns command errors without publishing invalid state', async () => {
    const bridge = new DevBridge()
    expect(
      (await bridge.run('setActiveProfile', { profileId: 'missing' })).ok
    ).toBe(false)
    expect(
      (await bridge.run('selectProxy', { group: 'missing', proxy: 'missing' }))
        .ok
    ).toBe(false)
    expect(bridge.snapshot.version).toBe(1)
  })
})
