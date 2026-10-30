import { defineConfig } from 'electron-vite'
import react from '@vitejs/plugin-react'

// ADR-0011: bundle every dependency into the output so electron-builder collects no node_modules.
export default defineConfig({
  main: { build: { externalizeDeps: false } },
  preload: { build: { externalizeDeps: false } },
  renderer: { plugins: [react()] }
})
