// Preparation only: copies/signs ordinary-user temp fixtures. Never launches App/Core or connects a socket.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmod, cp, lstat, mkdtemp, readFile, realpath, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { macosClientPin } from './macos-client-pin.mjs'

// The experiment driver runs this source separately under the same ordinary UID.
// It cannot select another endpoint/operation; only a structured native denial counts as a successful negative.
export const externalNodeClient = `import {createConnection} from 'node:net';
const socket=createConnection('/var/run/dev.kuro.tun/auth.sock');
let bytes=Buffer.alloc(0),settled=false;
const finish=(error)=>{if(settled)return;settled=true;clearTimeout(timer);socket.destroy();if(error){console.error(error.message);process.exitCode=2;}};
const timer=setTimeout(()=>finish(new Error('auth response timeout')),3000);
socket.once('connect',()=>socket.end('{"version":1,"operation":"authenticate"}\\n'));
socket.on('data',chunk=>{if(bytes.length+chunk.length>8192){finish(new Error('oversize auth reply'));return;}bytes=Buffer.concat([bytes,chunk]);});
socket.once('error',finish);
socket.once('close',()=>{if(!settled)finish(new Error('incomplete auth reply'));});
socket.once('end',()=>{try{
const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
if(!text.endsWith('\\n')||text.trim().includes('\\n'))throw new Error('invalid auth framing');
const reply=JSON.parse(text);console.log(JSON.stringify({nativeReply:reply}));
if(!reply||Object.keys(reply).sort().join(',')!=='error,ok,version'||reply.version!==1||reply.ok!==false||typeof reply.error!=='string'||!reply.error)throw new Error('expected explicit native authentication rejection');
finish();
}catch(error){finish(error);}});
`

export async function prepareElectronAuthNegatives(input) {
  if (process.platform !== 'darwin' || process.getuid() === 0) throw new Error('Ordinary macOS user required')
  const bundle = await realpath(resolve(input))
  const before = await macosClientPin(bundle)
  const require = createRequire(import.meta.url)
  const builderRequire = createRequire(require.resolve('electron-builder'))
  const packagerRequire = createRequire(builderRequire.resolve('app-builder-lib'))
  const asar = packagerRequire('@electron/asar')
  const main = asar.extractFile(join(bundle, 'Contents/Resources/app.asar'), 'out/main/index.js').toString('utf8')
  assert.ok(main.includes('--kuro-auth-verification=') && main.includes('authenticate-only') && main.includes('/var/run/dev.kuro.tun/auth.sock'), 'Candidate lacks the new fixed auth-only entry; build/freeze the committed candidate first')
  const directory = await mkdtemp(join(await realpath(tmpdir()), 'kuro-electron-auth-negatives-'))
  await chmod(directory, 0o700)
  const copies = {}
  for (const label of ['resigned', 'asar-mutated']) {
    const copy = join(directory, `${label}.app`)
    await cp(bundle, copy, { recursive: true, dereference: false, verbatimSymlinks: true, force: false, errorOnExist: true })
    assert.deepEqual(await macosClientPin(copy), before)
    copies[label] = copy
  }
  const entitlements = join(directory, 'entitlements.plist')
  await writeFile(entitlements, execFileSync('/usr/bin/codesign', ['--display', '--entitlements', '-', '--xml', join(bundle, 'Contents/MacOS/Clash Kuro')], { stdio: ['ignore', 'pipe', 'pipe'] }), { mode: 0o600 })
  await writeFile(join(copies.resigned, 'Contents/Resources/auth-reseal-marker.txt'), 'Auth experiment copy only.\n', { flag: 'wx' })
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--options', 'runtime', '--entitlements', entitlements, copies.resigned], { stdio: 'pipe' })
  const resignedPin = await macosClientPin(copies.resigned)
  assert.notEqual(resignedPin.cdhash, before.cdhash)
  const asarPath = join(copies['asar-mutated'], 'Contents/Resources/app.asar')
  const info = await lstat(asarPath)
  assert.ok(info.isFile() && !info.isSymbolicLink() && info.nlink === 1)
  const bytes = await readFile(asarPath), payload = asar.extractFile(asarPath, 'out/main/index.js')
  const offset = bytes.indexOf(payload)
  assert.ok(payload.length > 0 && offset >= 0 && bytes.indexOf(payload, offset + 1) === -1)
  bytes[offset + payload.length - 1] ^= 1
  await writeFile(asarPath, bytes)
  const nodeClient = join(directory, 'auth-external-node.mjs')
  await writeFile(nodeClient, externalNodeClient, { mode: 0o600, flag: 'wx' })
  assert.deepEqual(await macosClientPin(bundle), before, 'Input candidate must remain unchanged')
  const result = { format: 1, directory, bundle, before, copies, resignedPin, nodeClient, noAppLaunched: true,
    limitation: 'Preparation only. Driver must distinguish OS seal refusal from an explicit native identity denial; mutated unsigned copy may never reach auth.' }
  await writeFile(join(directory, 'prepared.json'), JSON.stringify(result, null, 2), { mode: 0o600, flag: 'wx' })
  console.log(JSON.stringify(result, null, 2))
  return result
}
if (process.argv[1] === fileURLToPath(import.meta.url)) prepareElectronAuthNegatives(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1 })
