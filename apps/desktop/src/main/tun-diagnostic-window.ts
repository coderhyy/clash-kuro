import { spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, open, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

// One disposable diagnostic candidate; no CLI/environment-selected privileged executable.
const entry = '/private/tmp/kuro-ipv4-local-native-result-acnhcyrv/paired.py'
const entrySHA = 'b7cf9d1700c6fd016a9ab6ba7de4cca23e9c0f732bf4777f1fcb0730c37d5f47'
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`

export function createTunDiagnosticWindow() {
  const controller = new AbortController()
  const evidence = `/private/tmp/kuro-local-ipv4-${randomUUID()}`
  let attempted = false
  let child: ReturnType<typeof spawn> | undefined
  let ended = false
  let entryStarted = false
  async function cancel(reason: Error) {
    if (controller.signal.aborted) reason = controller.signal.reason as Error
    else controller.abort(reason)
    try {
      const info = await lstat(evidence)
      entryStarted = true
      if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.() || (info.mode & 0o077)) return
      await writeFile(join(evidence, 'cancel-requested.json'), JSON.stringify({ reason: reason.message, at: Date.now(), actualStop: false }), { flag: 'wx', mode: 0o600 })
    } catch (error) {
      // Before the root entry creates E, dismiss only our own authorization wrapper.
      // Once E exists, only its cancellation protocol may unwind the root entry.
      if ((error as NodeJS.ErrnoException).code === 'ENOENT' && !entryStarted && child && !ended) child.kill('SIGTERM')
    }
  }
  async function prepare() {
    if (attempted) throw new Error('Diagnostic attempt already used; retain evidence and reopen only after cleanup')
    attempted = true
    try {
      if (controller.signal.aborted) throw controller.signal.reason
      if (process.platform !== 'darwin' || process.getuid?.() !== 501) throw new Error('Fixed diagnostic operator required')
      const bytes = await readFile(entry)
      if (createHash('sha256').update(bytes).digest('hex') !== entrySHA) throw new Error('Diagnostic entry changed')
      // Root executes the same bytes it hashes, not a second unchecked pathname read.
      const bootstrap = `import hashlib,sys; p=sys.argv[1]; b=open(p,'rb').read(); assert hashlib.sha256(b).hexdigest()==${JSON.stringify(entrySHA)},'diagnostic entry changed'; sys.argv=[p,sys.argv[2]]; exec(compile(b,p,'exec'),{'__name__':'__main__','__file__':p})`
      const command = ['/usr/bin/python3', '-I', '-B', '-c', bootstrap, entry, evidence].map(quote).join(' ')
      child = spawn('/usr/bin/osascript', ['-e', 'on run argv', '-e', 'do shell script (item 1 of argv) with administrator privileges', '-e', 'end run', command], { stdio: ['ignore', 'pipe', 'pipe'] })
      let stdout = '', stderr = ''
      child.stdout!.on('data', data => { stdout = (stdout + String(data)).slice(0, 16384) })
      child.stderr!.on('data', data => { stderr = (stderr + String(data)).slice(0, 16384) })
      child.once('error', error => { ended = true; void cancel(error) })
      child.once('exit', (code, signal) => {
        ended = true
        void cancel(new Error(`Local diagnostic collector ended: code=${code}, signal=${signal}; stop evidence still required`))
      })
      child.once('close', (code, signal) => {
        const result = JSON.stringify({ code, signal, stdout, stderr, at: Date.now(), actualStop: false })
        void writeFile(join(evidence, 'app-collector-exit.json'), result, { mode: 0o600, flag: 'wx' }).catch(error => {
          if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
            // Preserve authorization/preparation failure without creating E ahead of the initializer.
            return writeFile(`${evidence}.launcher.json`, result, { mode: 0o600, flag: 'wx' }).catch(() => {})
          }
        })
      })
      const until = Date.now() + 180_000 // Administrator prompt is before any TUN start.
      while (!ended && !controller.signal.aborted && Date.now() < until) {
        try {
          const file = await open(join(evidence, 'prepared.json'), constants.O_RDONLY | constants.O_NOFOLLOW)
          entryStarted = true
          try {
            const info = await file.stat()
            if (!info.isFile() || info.nlink !== 1 || info.uid !== 501 || (info.mode & 0o777) !== 0o600 || info.size > 4096) throw new Error('Unsafe diagnostic prepared marker')
            const value = JSON.parse(await file.readFile('utf8'))
            if (Object.keys(value).sort().join(',') !== 'evidence,format,prepared'
              || value.format !== 1 || value.prepared !== true || value.evidence !== evidence) throw new Error('Diagnostic preparation identity mismatch')
            if (ended || controller.signal.aborted) throw new Error('Collector exited before TUN open')
            return
          } finally { await file.close() }
        } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
        await new Promise(resolve => setTimeout(resolve, 25))
      }
      throw controller.signal.reason ?? new Error('Local diagnostic preparation failed or timed out; TUN was not started')
    } catch (error) {
      await cancel(error instanceof Error ? error : new Error(String(error)))
      throw error
    }
  }
  return { signal: controller.signal, evidence, prepare, cancel }
}
