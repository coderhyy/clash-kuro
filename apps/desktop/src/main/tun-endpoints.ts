import { lstat } from 'node:fs/promises'

export const TUN_RUN_DIRECTORY = '/Library/PrivilegedHelperTools/dev.kuro.tun-run'
export const AUTH_SOCKET = '/Library/PrivilegedHelperTools/dev.kuro.tun-run/auth.sock'
export const TUN_CONTROL_SOCKET = '/Library/PrivilegedHelperTools/dev.kuro.tun-run/control.sock'
const ancestors = ['/', '/Library', '/Library/PrivilegedHelperTools', TUN_RUN_DIRECTORY]

/** Directories protect replacement; sockets deliberately permit ordinary-user connects. Native audit identity authorizes requests. */
export async function assertTrustedTunEndpoint(path: string): Promise<void> {
  if (path !== AUTH_SOCKET && path !== TUN_CONTROL_SOCKET) throw new Error('Untrusted TUN helper endpoint path')
  for (const directory of ancestors) {
    const info = await lstat(directory)
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o6022) || !(info.mode & 0o001)) {
      throw new Error('Untrusted TUN helper endpoint directory')
    }
  }
  const endpoint = await lstat(path)
  if (!endpoint.isSocket() || endpoint.isSymbolicLink() || endpoint.uid !== 0 || endpoint.nlink !== 1
    || (endpoint.mode & 0o6000) || !(endpoint.mode & 0o002)) throw new Error('Untrusted TUN helper socket or ordinary-user connection permissions')
}
