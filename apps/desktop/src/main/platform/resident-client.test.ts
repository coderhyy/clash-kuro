import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { residentClient } from './resident-client'

// Private fake child; no Core, WinINet, registry, files or network access.
const script = `
const mode = process.argv[1];
if (mode === 'slow-bootstrap') Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 650);
let input = Buffer.alloc(0), closes = 0;
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const inputFrame = chunk => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 8 && input.length >= 8 + input.readUInt32LE(4)) {
    const kind = input.readUInt32LE(0), size = input.readUInt32LE(4);
    const command = input.subarray(8, 8 + size).toString('utf16le').split('\\0')[0];
    input = input.subarray(8 + size);
    if (kind === 2) {
      if (++closes !== 1) process.exit(91);
      if (mode === 'hang') send({command:'get',ok:true}); // Late result cannot reopen admission.
      if (mode.startsWith('report-')) {
        const final = {command:'shutdown',ok:true,timedOut:mode==='report-invalid',coreGone:true,corePid:123,durationMs:40};
        if (mode === 'report-truncated') process.stdout.write('{');
        else {
          send(final);
          if (mode === 'report-duplicate') send(final);
        }
      }
      setTimeout(() => process.exit(0), 30);
    } else if (mode === 'bad') send({command:'wrong',ok:true});
    else if (mode === 'overflow') process.stdout.write('x'.repeat(1024 * 1024 + 1));
    else if (mode === 'eof') { process.stdout.end(); setTimeout(() => process.exit(0), 100); }
    else if (mode === 'mutation-failure') send({command,ok:false});
    else if (mode === 'diagnostics') {
      process.stderr.write('x'.repeat(32768) + 'core-start-error', () => send({command,ok:true}));
    }
    else if (mode !== 'hang') send({command,ok:true});
  }
};
process.stdin.once('data', chunk => {
  if (chunk[0] !== 0) process.exit(93);
  process.stdin.on('data', inputFrame);
  if (mode !== 'no-ready') send({ready:true,protocol:1});
  if (chunk.length > 1) inputFrame(chunk.subarray(1));
});
process.stdin.on('end', () => { if (!closes) process.exit(92); });
process.stderr.write('fixture-ready\\n');
`

async function fixture(mode: string, body: (client: ReturnType<typeof residentClient>, child: ChildProcessWithoutNullStreams) => Promise<void>) {
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
  }, 5000)
  let client: ReturnType<typeof residentClient> | undefined
  try {
    // Node bootstrap is outside this protocol-only budget, but still bounded by the watchdog.
    await boot
    client = residentClient(child, 500)
    child.stdin.write(Buffer.from([0]))
    await body(client, child)
  }
  finally {
    try {
      if (client) {
        client.close()
        const result = await client.exited
        expect(rescued, 'external watchdog rescue is failure').toBe(false)
        expect(result.code).toBe(0)
      } else child.kill('SIGKILL')
    } finally { clearTimeout(watchdog) }
  }
}

test('handshake, command correlation, one outstanding request and idempotent close', async () => {
  await fixture('normal', async (client, child) => {
    await expect(client.request(['get'])).rejects.toThrow('starting')
    await client.ready
    const first = client.request(['get'])
    await expect(client.request(['get'])).rejects.toThrow('busy')
    expect(JSON.parse((await first).stdout)).toEqual({ command: 'get', ok: true })
    client.close(); client.close()
    await expect(client.request(['set'])).rejects.toThrow('closing')
    await client.exited
    await expect(client.request(['get'])).rejects.toThrow('exited')
    const late = residentClient(child)
    await expect(late.ready).rejects.toThrow('exited')
    await expect(late.exited).resolves.toEqual({ code: 0, signal: null })
  })
})

test('fixture bootstrap does not consume the protocol deadline', async () => {
  await fixture('slow-bootstrap', async client => {
    await client.ready
    expect(JSON.parse((await client.request(['get'])).stdout)).toEqual({ command: 'get', ok: true })
  })
})

test.each([
  ['hang', 'timed out'],
  ['bad', 'Unexpected resident helper response'],
  ['overflow', 'response exceeds limit'],
  ['eof', 'output ended'],
])('failed channel stays closed and waits for real exit: %s', async (mode, error) => {
  await fixture(mode, async client => {
    await client.ready
    await expect(client.request(['get'])).rejects.toThrow(error)
    await expect(client.request(['set'])).rejects.toThrow(/closing|exited/)
    await client.exited
    await expect(client.request(['get'])).rejects.toThrow('exited')
  })
})

test('startup deadline closes an unready child instead of allowing requests', async () => {
  await fixture('no-ready', async client => {
    await expect(client.ready).rejects.toThrow('timed out')
    await expect(client.request(['set'])).rejects.toThrow(/closing|exited/)
  })
})

test('Core diagnostics are drained, bounded, and separate from JSON responses', async () => {
  await fixture('diagnostics', async client => {
    await client.ready
    await client.request(['get'])
    client.close()
    await client.closed
    expect(Buffer.byteLength(client.diagnostics())).toBe(16 * 1024)
    expect(client.diagnostics().endsWith('core-start-error')).toBe(true)
  })
})

test('a failed mutation closes admission before the response consumer can enqueue another set', async () => {
  await fixture('mutation-failure', async client => {
    await client.ready
    expect(JSON.parse((await client.request(['set'])).stdout).ok).toBe(false)
    await expect(client.request(['set'])).rejects.toThrow(/closing|exited/)
  })
})

test('spawn failure rejects readiness and records that no writer process was created', async () => {
  const child = spawn(join(tmpdir(), randomUUID(), 'missing.exe'), [], { windowsHide: true, stdio: 'pipe' })
  const client = residentClient(child)
  await expect(client.ready).rejects.toThrow()
  expect(child.pid).toBeUndefined()
  await expect(client.exited).resolves.toEqual({ code: null, signal: null })
  await expect(client.closed).resolves.toEqual({ code: null, signal: null, report: null })
  await expect(client.request(['set'])).rejects.toThrow('exited')
})

test.each(['report-valid', 'report-invalid', 'report-duplicate', 'report-truncated', 'normal'])('final evidence requires one consistent complete report after stdout drains: %s', async mode => {
  await fixture(mode, async client => {
    await client.ready
    client.close()
    const result = await client.closed
    expect(result.code).toBe(0)
    expect(result.report).toEqual(mode === 'report-valid'
      ? { command: 'shutdown', ok: true, timedOut: false, coreGone: true, corePid: 123, durationMs: 40 }
      : null)
    await expect(client.request(['set'])).rejects.toThrow('exited')
  })
})
