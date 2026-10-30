import type { CommandInput, CommandName, StateSnapshot } from './index'

export type TrayCommand = { [K in CommandName]: { name: K; input: CommandInput<K> } }[CommandName]

export interface TrayMenuItem {
  id: string
  /** Host translates this key instead of using platform-specific menu text here. */
  label: string
  type: 'radio' | 'checkbox' | 'normal'
  checked?: boolean
  command: TrayCommand
}

export function buildTrayMenu(snapshot: StateSnapshot): TrayMenuItem[] {
  return [
    ...(['rule', 'global', 'direct'] as const).map((mode): TrayMenuItem => ({
      id: `mode.${mode}`, label: `mode.${mode}`, type: 'radio', checked: snapshot.settings.mode === mode,
      command: { name: 'setMode', input: { mode } }
    })),
    { id: 'systemProxy', label: 'systemProxy', type: 'checkbox', checked: snapshot.systemProxy.enabled, command: { name: 'setSystemProxy', input: { enabled: !snapshot.systemProxy.enabled } } },
    { id: 'openWindow', label: 'openWindow', type: 'normal', command: { name: 'openWindow', input: {} } },
    { id: 'quit', label: 'quit', type: 'normal', command: { name: 'quit', input: {} } }
  ]
}
