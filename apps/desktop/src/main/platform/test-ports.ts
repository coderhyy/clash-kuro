import { execFile, type ExecFileException } from 'node:child_process'
import { randomInt } from 'node:crypto'
import { createSocket } from 'node:dgram'
import { createServer } from 'node:net'
import { promisify } from 'node:util'

let excluded: Promise<readonly (readonly [number, number])[]> | undefined
function exclusions() {
  return excluded ??= process.platform !== 'win32' ? Promise.resolve([]) : (async () => {
    const ranges: (readonly [number, number])[] = []
    for (const protocol of ['tcp', 'udp']) {
      const read = async (kind: string) => {
        const args = ['int', 'ipv4', 'show', kind, `protocol=${protocol}`]
        const started = performance.now()
        try {
          return await promisify(execFile)('netsh.exe', args, { windowsHide: true, timeout: 5000, maxBuffer: 128 * 1024 })
        } catch (error) {
          const failure = error as ExecFileException
          throw new Error(`Windows test port inventory failed: netsh.exe ${args.join(' ')} (code=${failure.code ?? 'null'}, signal=${failure.signal ?? 'null'}, killed=${failure.killed ?? 'unknown'}, elapsedMs=${Math.round(performance.now() - started)}, timeoutMs=5000)\n${failure.message}`, { cause: error })
        }
      }
      // Overlapping netsh launches add per-command overhead; keep each read's own 5s budget.
      const { stdout } = await read('excludedportrange')
      const dynamic = await read('dynamicport')
      const range = [...dynamic.stdout.matchAll(/[:：]\s*(\d+)\s*$/gm)].map(match => Number(match[1]))
      if (range.length !== 2 || range[0]! < 1 || range[1]! < 1 || range[0]! + range[1]! > 65536)
        throw new Error(`Unknown Windows ${protocol} dynamic port inventory`)
      // Avoid outgoing ephemeral clients claiming a just-released listener address during restart.
      ranges.push(...[...stdout.matchAll(/^\s*(\d+)\s+(\d+)\s*\*?\s*$/gm)].map(match => [Number(match[1]), Number(match[2])] as const),
        [range[0]!, range[0]! + range[1]! - 1])
    }
    return ranges
  })()
}

/** Test-only resource allocation, before any Core/test action. Never retries a failed test or startup. */
export async function reserveTestPort(candidates?: readonly number[]) {
  if (candidates?.some(port => !Number.isInteger(port) || port < 1 || port > 65535)) throw new Error('Invalid test port candidate')
  const ranges = await exclusions()
  const pool = candidates ? [...candidates] : Array.from({ length: 49152 - 1024 }, (_, index) => index + 1024)
    .filter(port => !ranges.some(([first, last]) => port >= first && port <= last))
  const rejected: { port: number; protocol: string; code: string }[] = []
  for (let attempt = 0; attempt < 32 && pool.length; attempt++) {
    const port = pool.splice(candidates ? 0 : randomInt(pool.length), 1)[0]!
    const tcp = createServer(), udp = createSocket('udp4')
    let releasing: Promise<void> | undefined
    const release = () => releasing ??= Promise.all([
      new Promise<void>(resolve => tcp.listening ? tcp.close(() => resolve()) : resolve()),
      new Promise<void>((resolve, reject) => {
        try { udp.close(resolve) } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'ERR_SOCKET_DGRAM_NOT_RUNNING') resolve()
          else reject(error)
        }
      }),
    ]).then(() => {})
    let protocol = 'TCP'
    try {
      await new Promise<void>((resolve, reject) => tcp.once('error', reject).listen(port, '127.0.0.1', resolve))
      protocol = 'UDP'
      await new Promise<void>((resolve, reject) => udp.once('error', reject).bind(port, '127.0.0.1', resolve))
      return { port, release, rejected }
    } catch (error) {
      await release()
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'EADDRINUSE' && code !== 'EACCES') throw error
      rejected.push({ port, protocol, code })
    }
  }
  throw new Error(`No isolated TCP/UDP test port available: ${JSON.stringify(rejected)}`)
}
