// ADR-0001 self-check: these must stay unresolvable. If one compiles, a forbidden dependency leaked in.
// @ts-expect-error -- no Node built-ins
import type {} from 'node:fs'
// @ts-expect-error -- no Node built-ins
import type {} from 'node:child_process'
// @ts-expect-error -- no Electron
import type {} from 'electron'
// @ts-expect-error -- no DOM
export type NoDom = Document
