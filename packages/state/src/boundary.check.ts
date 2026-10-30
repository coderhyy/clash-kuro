// ADR-0001 self-check: these must stay unresolvable. If one compiles, a forbidden dependency leaked in.
// @ts-expect-error -- no Node built-ins
import type {} from 'node:fs'
// @ts-expect-error -- no Node built-ins
import type {} from 'node:child_process'
// @ts-expect-error -- no Electron
import type {} from 'electron'
// React declares empty DOM interface stubs; the actual DOM globals and methods must stay absent.
// @ts-expect-error -- no DOM global
export type NoDom = typeof document
// @ts-expect-error -- no DOM capabilities
export type NoDomMethods = Document['createElement']
