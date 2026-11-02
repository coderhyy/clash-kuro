import { createRequire } from 'node:module'
import { mkdirSync, copyFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const repo = resolve(root, '../../../..')
const require = createRequire(join(repo, 'apps/desktop/package.json'))
const { build, Platform } = require('electron-builder')
const project = join(root, 'out/app')
mkdirSync(project, { recursive: true })
copyFileSync(join(root, 'main.cjs'), join(project, 'main.cjs'))
writeFileSync(join(project, 'package.json'), JSON.stringify({ name: 'kuro-deadline-prototype', version: '0.0.0',
  description: 'Isolated fake-operation experiment', author: 'Kuro prototype', main: 'main.cjs' }, null, 2))
process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'false'
await build({ projectDir: project, targets: Platform.WINDOWS.createTarget('dir'), config: {
  appId: 'dev.kuro.prototype.deadline', productName: 'Kuro Deadline Prototype',
  electronVersion: '45.1.0', electronDist: join(repo, 'apps/desktop/node_modules/electron/dist'),
  directories: { output: join(root, 'out/packaged') },
  npmRebuild: false, nodeGypRebuild: false, asar: true,
  files: ['main.cjs', 'package.json'],
  extraResources: [{ from: join(root, 'out/deadline.node'), to: 'native/deadline.node' }],
  win: { target: 'dir', executableName: 'kuro-deadline-prototype', signAndEditExecutable: false }
} })
