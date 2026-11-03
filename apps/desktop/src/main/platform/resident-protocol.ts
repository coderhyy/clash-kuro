/** Private inherited pipe protocol. No shell parsing, socket listener or reconnect. */
export function residentRequest(args: readonly string[]): Buffer {
  if (!args.length || args.length > 32 || !args[0] || args.some(arg => arg.includes('\0'))) {
    throw new Error('Invalid resident helper arguments')
  }
  const bytes = args.reduce((size, arg) => size + (arg.length + 1) * 2, 0)
  if (bytes > 65536) throw new Error('Resident helper request exceeds 65536 bytes')
  const frame = Buffer.allocUnsafe(8 + bytes)
  frame.writeUInt32LE(1, 0)
  frame.writeUInt32LE(bytes, 4)
  frame.write(args.join('\0') + '\0', 8, 'utf16le')
  return frame
}

/** The native reader handles this before dispatching work, even with a blocked worker. */
export function residentClose(): Buffer {
  const frame = Buffer.alloc(8)
  frame.writeUInt32LE(2, 0)
  return frame
}
