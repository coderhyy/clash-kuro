import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test } from 'vitest'
import { residentClient } from './resident-client'

// Private fake child; no Core, WinINet, registry, files or network access.
const script = `
const mode = process.argv[1];
let input = Buffer.alloc(0), closes = 0;
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
if (mode !== 'no-ready') send({ready:true,protocol:1});
process.stdin.on('data', chunk => {
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
    else if (mode !== 'hang') send({command,ok:true});
  }
});
process.stdin.on('end', () => { if (!closes) process.exit(92); });
`

async function fixture(mode: string, body: (client: ReturnType<typeof residentClient>, child: ChildProcessWithoutNullStreams) => Promise<void>) {
  const child = spawn(process.execPath, ['-e', script, mode], { windowsHide: true, stdio: 'pipe' })
  const client = residentClient(child, 500)
  let rescued = false
  const watchdog = setTimeout(() => { rescued = true; child.kill('SIGKILL') }, 5000)
  try { await body(client, child) }
  finally {
    client.close()
    const result = await client.exited
    clearTimeout(watchdog)
    expect(rescued, 'external watchdog rescue is failure').toBe(false)
    expect(result.code).toBe(0)
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

test.each(['hang', 'bad', 'overflow', 'eof'])('failed channel stays closed and waits for real exit: %s', async mode => {
  await fixture(mode, async client => {
    await client.ready
    await expect(client.request(['get'])).rejects.toThrow()
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
