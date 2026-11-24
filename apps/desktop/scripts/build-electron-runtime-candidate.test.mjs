import { expect, test } from 'vitest'
import { join } from 'node:path'
import { candidateBuildPlan } from './build-electron-runtime-candidate.mjs'

const commit = '1'.repeat(40)
test('candidate rebuild starts with source compilation and separates sealed normal and auth-only modes', () => {
  const finite = candidateBuildPlan('darwin-arm64', 'finite-session', commit)
  const auth = candidateBuildPlan('darwin-arm64', 'auth-only', commit)
  expect(finite.commands[0][0]).toMatch(/electron-vite$/)
  expect(finite.commands[0][1]).toEqual(['build'])
  expect(finite.commands[1][1]).toContain('-c.extraMetadata.kuroAuthObservationOnly=false')
  expect(finite.commands[1][1]).toContain('-c.extraMetadata.kuroCandidateMode=finite-session')
  expect(auth.commands[1][1]).toContain('-c.extraMetadata.kuroAuthObservationOnly=true')
  expect(finite.output).not.toBe(auth.output)
  expect(finite.output).toContain(commit.slice(0, 12))
  expect(finite.bundle).toBe(join(finite.output, 'mac-arm64', 'Clash Kuro.app'))
  expect(candidateBuildPlan('darwin-x64', 'finite-session', commit).commands[1][1]).toContain('--x64')
  // Plan has no re-sign/copy-old-App step and no launch/install command.
  expect(finite.commands).toHaveLength(2)
})
test('candidate rebuild refuses unspecified modes and non-fixed commit/target', () => {
  expect(() => candidateBuildPlan('darwin-arm64', 'enabled', commit)).toThrow()
  expect(() => candidateBuildPlan('darwin-arm64', 'finite-session', 'HEAD')).toThrow()
  expect(() => candidateBuildPlan('../../old.app', 'finite-session', commit)).toThrow()
})
test('local diagnostic window is explicit and only sealed into finite-session candidates', () => {
  expect(candidateBuildPlan('darwin-arm64', 'finite-session', commit).commands[1][1]).toContain('-c.extraMetadata.kuroTunDiagnosticWindow=false')
  expect(candidateBuildPlan('darwin-arm64', 'finite-session', commit, true).commands[1][1]).toContain('-c.extraMetadata.kuroTunDiagnosticWindow=true')
  expect(() => candidateBuildPlan('darwin-arm64', 'auth-only', commit, true)).toThrow()
})
