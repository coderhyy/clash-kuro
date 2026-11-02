// A rescued process or incomplete report is never a clean operation result.
export function cleanExit({ data, failure }) {
  return !failure && data.rootExitCode === 0 && data.remaining === 0 &&
    data.watchdogKilled === false && data.lingeringChildren === false
}
