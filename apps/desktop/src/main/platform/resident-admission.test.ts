import { spawn } from 'node:child_process'
import { expect, test } from 'vitest'
import { residentClient, type AuthorizeResident } from './resident-client'

// Fake inherited pipes only; no native helper, Core, registry or sockets.
const script = `
const mode = process.argv[1];
let input = Buffer.alloc(0), admits = 0, closes = 0;
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const held = {reserved:true,protocol:2,pid:process.pid,userSid:'S-1-5-21-1-2-3-1001',
  nonce:'a'.repeat(64),helperDigest:'b'.repeat(64),journalDigest:'c'.repeat(64),priorEndpoints:['127.0.0.1:7891'],initialEndpoints:[],admissionReceiptDigest:null};
if (mode === 'wrong-pid') held.pid++;
if (mode === 'bad-nonce') held.nonce = 'a'.repeat(63);
if (mode === 'missing-provenance') delete held.admissionReceiptDigest;
if (mode === 'bad-provenance') held.admissionReceiptDigest = 'invalid';
if (mode === 'bad-endpoint') held.priorEndpoints = ['127.0.0.1:65536'];
if (mode === 'duplicate-endpoint') held.priorEndpoints.push(held.priorEndpoints[0]);
const inputFrame = chunk => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 8 && input.length >= 8 + input.readUInt32LE(4)) {
    const kind = input.readUInt32LE(0), size = input.readUInt32LE(4);
    const payload = input.subarray(8, 8 + size);
    input = input.subarray(8 + size);
    if (kind === 2) {
      if (++closes !== 1) process.exit(91);
      process.stderr.write('admits=' + admits + '\\n');
      setTimeout(() => process.exit(0), 10);
    } else if (kind === 3) {
      if (++admits !== 1 || size !== 128 || payload.toString('hex') !== 'a'.repeat(64) + 'c'.repeat(64) + 'd'.repeat(64) + 'e'.repeat(64)) process.exit(93);
      if (mode !== 'no-ready') send({ready:true,protocol:2,recoveryVerified:mode !== 'unverified-replay'});
    } else if (kind === 1 && admits === 1) send({command:'get',ok:true});
    else process.exit(94);
  }
};
process.stdin.once('data', () => {
  process.stdin.on('data', inputFrame);
  if (mode === 'old-ready') send({ready:true,protocol:1});
  else send(held);
  if (mode === 'duplicate') send(held);
  if (mode === 'premature') send({ready:true,protocol:2,recoveryVerified:true});
});
process.stdin.on('end', () => { if (!closes) process.exit(92); });
process.stderr.write('fixture-ready\\n');
`

const proof = { receiptDigest: 'd'.repeat(64), evidenceDigest: 'e'.repeat(64) }
async function fixture(mode: string, authorize: AuthorizeResident | undefined,
  body: (client: ReturnType<typeof residentClient>) => Promise<void>, expectedAdmissions = 0) {
  const child = spawn(process.execPath, ['-e', script, mode], { windowsHide: true, stdio: 'pipe' })
  let rescued = false
  let startupFailure!: (error: Error) => void
  const boot = new Promise<void>((resolve, reject) => {
    startupFailure = reject
    child.once('error', reject)
    child.once('exit', () => reject(new Error('Fixture exited before bootstrap')))
    child.stderr.once('data', chunk => String(chunk) === 'fixture-ready\n' ? resolve() : reject(new Error('Invalid fixture bootstrap')))
  })
  const watchdog = setTimeout(() => {
    rescued = true; child.kill('SIGKILL'); startupFailure(new Error('Fixture watchdog rescue is failure'))
  }, 4000)
  let client: ReturnType<typeof residentClient> | undefined
  try {
    // Exclude unrelated Node bootstrap from this protocol-ordering unit budget, not production startup.
    await boot
    client = residentClient(child, 500, authorize)
    child.stdin.write(Buffer.from([0]))
    await body(client)
  }
  finally {
    try {
      if (client) {
        client.close()
        const result = await client.closed
        expect(rescued, 'watchdog rescue is failure').toBe(false)
        expect(result.code).toBe(0)
        expect(client.diagnostics()).toContain(`admits=${expectedAdmissions}\n`)
      } else child.kill('SIGKILL')
    } finally { clearTimeout(watchdog) }
  }
}

test('reserved is not ready: checks bind exact child, then timely replay acknowledgement admits commands', async () => {
  let called = 0
  await fixture('normal', async held => {
    called++
    expect(held.pid).toBeGreaterThan(0)
    expect(held.helperDigest).toBe('b'.repeat(64))
    expect(Object.isFrozen(held)).toBe(true)
    expect(Object.isFrozen(held.priorEndpoints)).toBe(true)
    expect(Object.isFrozen(held.initialEndpoints)).toBe(true)
    return proof
  }, async client => {
    await expect(client.request(['get'])).rejects.toThrow('starting')
    await client.ready
    expect(called).toBe(1)
    expect(JSON.parse((await client.request(['get'])).stdout).ok).toBe(true)
  }, 1)
})

test.each(['wrong-pid', 'bad-nonce', 'bad-endpoint', 'duplicate-endpoint', 'old-ready', 'missing-provenance', 'bad-provenance'])('invalid reservation never invokes policy or writes ADMIT: %s', async mode => {
  let called = false
  await fixture(mode, async () => { called = true; return proof }, async client => {
    await expect(client.ready).rejects.toThrow()
    expect(called).toBe(false)
    await expect(client.request(['set'])).rejects.toThrow(/closing|exited/)
  })
})

test.each(['duplicate', 'premature'])('out-of-order protocol cannot admit while evidence checks are pending: %s', async mode => {
  await fixture(mode, () => new Promise(() => {}), async client => {
    await expect(client.ready).rejects.toThrow('Unexpected')
  })
})

test('protocol 2 requires an admission policy, not protocol 1 compatibility', async () => {
  await fixture('normal', undefined, async client => {
    await expect(client.ready).rejects.toThrow('Unexpected')
  })
})

test('denied or malformed evidence closes without issuing admission', async () => {
  for (const authorize of [async () => { throw new Error('Backup changed') }, async () => ({ ...proof, evidenceDigest: '' })]) {
    await fixture('normal', authorize, async client => {
      await expect(client.ready).rejects.toThrow(/Backup changed|Invalid resident admission/)
    })
  }
})

test('close while checking is sticky even if checks later succeed', async () => {
  let complete!: (value: typeof proof) => void
  let checking!: () => void
  const entered = new Promise<void>(resolve => { checking = resolve })
  await fixture('normal', () => { checking(); return new Promise(resolve => { complete = resolve }) }, async client => {
    await entered
    client.close(); client.close()
    complete(proof)
    await expect(client.ready).rejects.toThrow('closing')
  })
})

test('hung evidence collection is closed by the original startup timer', async () => {
  await fixture('normal', () => new Promise(() => {}), async client => {
    await expect(client.ready).rejects.toThrow('timed out')
  })
})

test.each(['no-ready', 'unverified-replay'])('ADMIT alone cannot authorize requests: %s', async mode => {
  await fixture(mode, async () => proof, async client => {
    await expect(client.ready).rejects.toThrow()
    await expect(client.request(['set'])).rejects.toThrow(/closing|exited/)
  }, 1)
})
