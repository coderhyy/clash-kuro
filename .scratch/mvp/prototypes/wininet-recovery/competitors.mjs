import { win32 } from 'node:path'

export function isCompetingProcess(row, recoveryDirectory) {
  const name = String(row.ProcessName ?? '').replace(/\.exe$/i, '')
  if (/^clash-verge-service$/i.test(name)) return false
  if (/clash-verge|fiddler|Clash Kuro|mihomo|sing-box|v2ray|kuro-sysproxy/i.test(name)) return true
  if (!/^[a-f0-9]{64}$/i.test(name)) return false
  // An unreadable hash-named executable could be a retained proxy writer.
  if (!row.Path || !recoveryDirectory || !win32.isAbsolute(row.Path) || !win32.isAbsolute(recoveryDirectory)) return true
  const relative = win32.relative(recoveryDirectory.toLowerCase(), row.Path.toLowerCase())
  return relative !== '' && relative !== '..' && !relative.startsWith('..\\') && !win32.isAbsolute(relative)
}
