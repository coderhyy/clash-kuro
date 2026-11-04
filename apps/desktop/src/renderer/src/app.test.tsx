import * as React from 'react'
import { createElement, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { expect, test, vi } from 'vitest'
import { FakeBridge, fakeSnapshot } from '@kuro/state/fake'
import { App } from './app'
import { t } from '../../shared/i18n'
import type { TunStatus } from '@kuro/core'

const tunControls = vi.hoisted(() => ({
  toggle: undefined as ((checked: boolean) => void) | undefined,
  recover: undefined as (() => void) | undefined
}))

vi.mock('react', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react')>()
  return { ...actual, useState: vi.fn(actual.useState) }
})

vi.mock('./use-snapshot', () => ({
  useSnapshot: (bridge: FakeBridge) => ({ snapshot: bridge.snapshot, error: null })
}))
vi.mock('@/components/ui/button', () => ({
  Button: ({ variant, size, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: string; size?: string }) => {
    if (props.id === 'tun-recover') tunControls.recover = () => props.onClick?.({} as never)
    return createElement('button', props)
  }
}))
vi.mock('@/components/ui/input', () => ({
  Input: (props: InputHTMLAttributes<HTMLInputElement>) => createElement('input', props)
}))
vi.mock('@/components/ui/switch', () => ({
  Switch: ({ onCheckedChange, ...props }: InputHTMLAttributes<HTMLInputElement> & { onCheckedChange?: (checked: boolean) => void }) => {
    if (props.id === 'tun') tunControls.toggle = onCheckedChange
    return createElement('input', { ...props, type: 'checkbox', readOnly: true })
  }
}))
vi.mock('@/components/ui/badge', () => ({
  Badge: ({ children }: { children: ReactNode }) => createElement('span', null, children)
}))

test.each(['off', 'on', 'unknown', 'restart'] as const)('%s renders truthful proxy status and control availability', (state) => {
  const restartRequired = state === 'restart'
  const proxyUnknown = restartRequired || state === 'unknown'
  const snapshot = fakeSnapshot({
    core: restartRequired
      ? { status: 'stopped', error: 'Restart the app', restartRequired: true }
      : { status: 'stopped', error: null },
    systemProxy: proxyUnknown ? { enabled: false, unknown: true }
      : state === 'on' ? { enabled: true } : { enabled: false }
  })
  const html = renderToStaticMarkup(createElement(App, { bridge: new FakeBridge(snapshot), demo: false }))
  const proxyStatus = html.match(/<span[^>]*class="proxy-status[^"]*"[^>]*>(.*?)<\/span>/)?.[1]
  expect(proxyStatus).toBe(t(proxyUnknown ? 'unknown' : state))
  const startButton = html.match(new RegExp(`<button\\b[^>]*>(?:(?!<\\/button>)[\\s\\S])*?${t('startCore')}<\\/button>`))?.[0]
  const proxyToggle = html.match(/<input\b[^>]*id="system-proxy"[^>]*>/)?.[0]
  expect(startButton).toBeDefined()
  expect(proxyToggle).toBeDefined()
  expect(startButton?.includes('disabled=""')).toBe(restartRequired)
  expect(proxyToggle?.includes('disabled=""')).toBe(proxyUnknown || restartRequired)
  const modeControl = html.match(/<fieldset\b[^>]*class="mode-control"[^>]*>/)?.[0]
  expect(modeControl).toBeDefined()
  expect(modeControl?.includes('disabled=""')).toBe(restartRequired)
  if (restartRequired) expect(html).toContain('Restart the app')
})


test.each([
  { availability: 'unsupported', state: 'off' },
  { availability: 'not-installed', state: 'off' },
  { availability: 'ready', state: 'off' },
  { availability: 'ready', state: 'on' },
  { availability: 'blocked', state: 'off', error: 'Owned cleanup is incomplete' },
  { availability: 'ready', state: 'unknown', error: 'Cannot inspect owned routes' }
] satisfies TunStatus[])('TUN renders truthful availability and recovery for %j', (tun) => {
  const snapshot = fakeSnapshot({ tun })
  const html = renderToStaticMarkup(createElement(App, { bridge: new FakeBridge(snapshot), demo: false }))
  const toggle = html.match(/<input\b[^>]*id="tun"[^>]*>/)?.[0]
  if (tun.availability === 'unsupported') {
    expect(toggle).toBeUndefined()
    expect(html).not.toContain('id="tun-status"')
    return
  }
  expect(toggle).toBeDefined()
  expect(toggle?.includes('disabled=""')).toBe(tun.availability !== 'ready' || tun.state === 'unknown')
  expect(toggle?.includes('checked=""')).toBe(tun.state === 'on')
  expect(html).toContain(t('tunHint'))
  expect(html.includes(t('recoverTun'))).toBe(tun.availability === 'blocked' || tun.state === 'unknown')
  if (tun.error) expect(html).toContain(tun.error)
  if (tun.availability === 'not-installed') expect(html).toContain(t('tunNotInstalled'))
})


test('TUN controls dispatch the shared set and recovery commands', async () => {
  const bridge = new FakeBridge(fakeSnapshot({ tun: { availability: 'ready', state: 'off' } }))
  renderToStaticMarkup(createElement(App, { bridge, demo: false }))
  tunControls.toggle?.(true)
  expect(bridge.calls).toEqual([{ name: 'setTun', input: { enabled: true } }])
  await Promise.resolve()
  bridge.publish(fakeSnapshot({ tun: { availability: 'blocked', state: 'unknown', error: 'Inspect routes first' } }))
  renderToStaticMarkup(createElement(App, { bridge, demo: false }))
  tunControls.recover?.()
  expect(bridge.calls[1]).toEqual({ name: 'recoverTun', input: {} })
})

test.each(['en', 'zh-CN'] as const)('TUN manual-start hint and recovery are translated in %s', (language) => {
  const bridge = new FakeBridge(fakeSnapshot({
    resolvedLanguage: language,
    tun: { availability: 'blocked', state: 'unknown', error: 'Native cleanup not confirmed' }
  }))
  const html = renderToStaticMarkup(createElement(App, { bridge, demo: false }))
  expect(html).toContain(t('tunHint', {}, language))
  expect(html).toContain(t('recoverTun', {}, language))
  expect(html).toContain('Native cleanup not confirmed')
})


test.each([
  { availability: 'ready', state: 'off' },
  { availability: 'blocked', state: 'unknown' }
] satisfies TunStatus[])('busy TUN controls reject additional actions for %j', (tun) => {
  const busy = vi.mocked(React.useState).mockReturnValueOnce([true, vi.fn()])
  try {
    const bridge = new FakeBridge(fakeSnapshot({ tun }))
    const html = renderToStaticMarkup(createElement(App, { bridge, demo: false }))
    expect(html.match(/<input\b[^>]*id="tun"[^>]*>/)?.[0]).toContain('disabled=""')
    if (tun.availability === 'blocked') {
      expect(html.match(/<button\b[^>]*id="tun-recover"[^>]*>/)?.[0]).toContain('disabled=""')
    }
  } finally {
    busy.mockClear()
  }
})
