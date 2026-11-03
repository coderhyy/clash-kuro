#ifndef KURO_RESIDENT_PROTOCOL_H
#define KURO_RESIDENT_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>

/* Protocol 3, private inherited stdin: LE uint32 kind, LE uint32 bytes,
   UTF-16LE NUL-terminated argv. EXEC=1, CLOSE=2. Native startup owns recovery;
   there is no admission frame. CLOSE bypasses the operation queue.
   EOF/malformed framing closes the instance; there is no reconnect or resynchronization. */
#define KURO_REQUEST_BYTES 65536u
#define KURO_REQUEST_ARGS 32u
static uint32_t kuro_u32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static int kuro_request_header(const unsigned char header[8], uint32_t *kind, uint32_t *bytes) {
  *kind = kuro_u32(header); *bytes = kuro_u32(header + 4);
  return (*kind == 2 && *bytes == 0) || (*kind == 1 && *bytes >= 2 &&
    *bytes <= KURO_REQUEST_BYTES && !(*bytes & 1));
}
/* Caller owns aligned payload storage through operation completion, including after timeout. */
static int kuro_request_args(wchar_t *payload, size_t bytes, wchar_t **argv, size_t *argc) {
  *argc = 0;
  if (!payload || bytes < 2 || bytes > KURO_REQUEST_BYTES || (bytes & 1)) return 0;
  size_t units = bytes / 2, start = 0;
  for (size_t i = 0; i < units; ++i) {
    if (payload[i]) continue;
    if (*argc == KURO_REQUEST_ARGS || (i == 0 && start == 0)) return 0;
    argv[(*argc)++] = payload + start;
    start = i + 1;
  }
  return start == units && *argc > 0;
}
#endif
