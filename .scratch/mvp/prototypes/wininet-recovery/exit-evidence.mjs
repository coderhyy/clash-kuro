// A rescued process or incomplete report is never a clean operation result.
export function cleanExit({ data, failure }) {
  return !failure && data.rootExitCode === 0 && data.remaining === 0 &&
    data.watchdogKilled === false && data.lingeringChildren === false
}

export function parseNativeShutdown(text) {
  const records = text.trim().split(/\r?\n/).map(line => JSON.parse(line))
  if (records.length !== 2 || records[0]?.command !== 'closing' || records[1]?.command !== 'shutdown' ||
      records.some(record => record.protocol !== 3)) throw new Error('Incomplete or ambiguous native shutdown evidence')
  return records[1]
}
