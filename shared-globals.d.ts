// Globals that exist in Node, Electron and React Native alike. Anything else must come through Platform.
declare function setTimeout(handler: () => void, ms?: number): unknown
declare function clearTimeout(id: unknown): void
declare const console: {
  log(...args: unknown[]): void
  warn(...args: unknown[]): void
  error(...args: unknown[]): void
}
