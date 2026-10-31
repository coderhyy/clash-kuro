/// <reference types="vite/client" />

import type { StateBridge } from '@kuro/state'
import type { BackupResult } from '../../main/ipc-channels'

declare global {
  interface Window {
    /** Exposed by preload; the renderer's only way to reach the main process (ADR-0004). */
    kuro?: StateBridge
    /** Desktop-only helpers outside StateBridge; absent in demo mode. */
    kuroFiles?: {
      pickProfileFile(): Promise<string | null>
      openLoginItemsSettings(): Promise<void>
      exportBackup(): Promise<BackupResult>
      importBackup(): Promise<BackupResult>
    }
  }
}
