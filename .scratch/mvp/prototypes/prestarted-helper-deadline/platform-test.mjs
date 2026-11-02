// Real bundled Core/Platform and native v2 challenge; proxy/registration and admission policy are fake.
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
const root = dirname(fileURLToPath(import.meta.url))
const repo = resolve(root, '../../../..')
const dir = join(root, 'out', `resident-platform-${Date.now()}`)
mkdirSync(dir, { recursive: true })
const recoveryDirectory = realpathSync(mkdtempSync(join(tmpdir(), 'kuro-admission-platform-')))
const namespace = randomUUID()
const quote = s => '"' + s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1') + '"'
const desktop = join(repo, 'apps/desktop')
const require = createRequire(join(desktop, 'package.json'))
const vitest = join(dirname(require.resolve('vitest/package.json')), require('vitest/package.json').bin.vitest)
const command = [process.execPath, vitest, 'run',
  'src/main/platform/mihomo.integration.test.ts', '--maxWorkers=1'].map(quote).join(' ')
const supervisor = spawn(join(root, 'out/watchdog.exe'), ['30000', join(dir, 'supervisor.json'), process.execPath, command], {
  cwd: desktop, windowsHide: true, stdio: 'pipe', env: { ...process.env, KURO_REQUIRE_CORE: '1',
    KURO_RESIDENT_FAKE: join(root, 'out/admission-fake.exe'),
    KURO_ADMISSION_TEST_ROOT: recoveryDirectory, KURO_ADMISSION_TEST_NAMESPACE: namespace, KURO_ADMISSION_TEST_MODE: '' },
})
let output = '', rescued = false
supervisor.stdout.on('data', chunk => { output += chunk })
supervisor.stderr.on('data', chunk => { output += chunk })
const guard = setTimeout(() => { rescued = true; supervisor.kill('SIGKILL') }, 35000)
const code = await new Promise((resolve, reject) => {
  supervisor.once('error', reject); supervisor.once('exit', resolve)
}).finally(() => clearTimeout(guard))
writeFileSync(join(dir, 'test.log'), output)
console.log(output)
assert.equal(rescued, false, 'Outer rescue is a failure')
assert.equal(code, 0, 'Test process must exit normally')
const report = JSON.parse(readFileSync(join(dir, 'supervisor.json')))
assert.equal(report.watchdogKilled, false)
assert.equal(report.lingeringChildren, false)
assert.equal(report.remaining, 0)
writeFileSync(join(dir, 'result.json'), JSON.stringify({ scope: 'real Core/Platform and native v2 challenge; fake proxy, registration and admission policy; no controlled Restart or OS session',
  recoveryDirectory, namespace, report }, null, 2))
console.log(dir)
