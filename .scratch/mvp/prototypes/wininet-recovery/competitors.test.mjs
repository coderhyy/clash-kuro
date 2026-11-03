import assert from 'node:assert/strict'
import { test } from 'node:test'
import { isCompetingProcess } from './competitors.mjs'

const recovery = 'C:\\Users\\Tester\\AppData\\Local\\ClashKuro\\Recovery'
const hash = 'abcdef0123456789'.repeat(4)
const competes = (ProcessName, Path, root = recovery) => isCompetingProcess({ ProcessName, Path }, root)

test('known app, Core, helper and competing proxy names block restoration', () => {
  for (const name of ['Clash Kuro', 'Clash Kuro.exe', 'KURO-SYSPROXY.EXE', 'mihomo', 'verge-mihomo',
    'clash-verge', 'Fiddler', 'Fiddler Everywhere', 'sing-box', 'v2ray', 'v2rayN']) {
    assert.equal(competes(name), true, name)
  }
})

test('service exception is informational, not a writer', () => {
  for (const name of ['clash-verge-service', 'CLASH-VERGE-SERVICE.EXE']) assert.equal(competes(name), false)
  assert.equal(competes('clash-verge-service-other'), true)
})

test('retained hash helpers block within the recovery directory, case insensitively', () => {
  assert.equal(competes(hash, `${recovery}\\${hash}.exe`), true)
  assert.equal(competes(`${hash.toUpperCase()}.EXE`, `${recovery.toUpperCase()}\\nested\\${hash}.exe`), true)
  assert.equal(competes(hash, `${recovery}\\${hash}.exe`, `${recovery}\\`), true)
})

test('known outside paths, siblings and traversal are not retained helpers', () => {
  for (const path of [`C:\\Other\\${hash}.exe`, `${recovery}-other\\${hash}.exe`,
    `${recovery}\\..\\Other\\${hash}.exe`, `D:\\Other\\${hash}.exe`]) {
    assert.equal(competes(hash, path), false, path)
  }
})

test('unreadable or ambiguous hash paths fail closed', () => {
  for (const path of [undefined, null, '', `${hash}.exe`]) assert.equal(competes(hash, path), true)
  assert.equal(competes(hash, `${recovery}\\${hash}.exe`, ''), true)
  assert.equal(competes(hash, `${recovery}\\${hash}.exe`, 'relative\\Recovery'), true)
})

test('unrelated processes do not block', () => {
  assert.equal(competes('notepad'), false)
  assert.equal(competes(`${hash.slice(1)}`, `${recovery}\\unrelated.exe`), false)
  assert.equal(isCompetingProcess({}, recovery), false)
})
