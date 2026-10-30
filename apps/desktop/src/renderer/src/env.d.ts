/// <reference types="vite/client" />

import type { StateBridge } from '@tern/state'

declare global {
  interface Window {
    /** Exposed by preload; the renderer's only way to reach the main process (ADR-0004). */
    tern?: StateBridge
    /** Desktop-only helpers outside StateBridge; absent in demo mode. */
    ternFiles?: { pickProfileFile(): Promise<string | null> }
  }
}
