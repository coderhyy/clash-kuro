import { createElement, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { expect, test, vi } from 'vitest'
import { FakeBridge, fakeSnapshot } from '@kuro/state/fake'
import { App } from './app'
import { t } from '../../shared/i18n'

vi.mock('./use-snapshot', () => ({
  useSnapshot: (bridge: FakeBridge) => ({ snapshot: bridge.snapshot, error: null })
}))
vi.mock('@/components/ui/button', () => ({
  Button: ({ variant, size, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: string; size?: string }) =>
    createElement('button', props)
}))
vi.mock('@/components/ui/input', () => ({
  Input: (props: InputHTMLAttributes<HTMLInputElement>) => createElement('input', props)
}))
vi.mock('@/components/ui/switch', () => ({
  Switch: ({ onCheckedChange, ...props }: InputHTMLAttributes<HTMLInputElement> & { onCheckedChange?: (checked: boolean) => void }) =>
    createElement('input', { ...props, type: 'checkbox', readOnly: true })
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
