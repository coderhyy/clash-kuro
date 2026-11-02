#ifndef KURO_RECOVERY_JOURNAL_H
#define KURO_RECOVERY_JOURNAL_H
#include <stdint.h>
#include "recovery-lock.h"

/* Own the nonshared handle for the whole writer lifetime. Append and flush BEFORE
   admitting a new endpoint. Never overwrite A with B; incomplete records fail closed.
   Only verified clear of the entire set permits reset. Windows wchar_t is UTF-16. */
#define KURO_RECOVERY_ENDPOINTS 8
typedef struct { uint32_t magic, checksum; wchar_t server[300]; } KuroRecoveryRecord;
typedef struct { unsigned count; wchar_t servers[KURO_RECOVERY_ENDPOINTS][300]; } KuroRecoveryState;
_Static_assert(sizeof(KuroRecoveryRecord) == 608, "Recovery format must not depend on host padding");
static uint32_t kuro_recovery_checksum(const wchar_t *server) {
  uint32_t hash = 2166136261u;
  const unsigned char *bytes = (const unsigned char *)server;
  for (unsigned i = 0; i < 600; ++i) hash = (hash ^ bytes[i]) * 16777619u;
  return hash;
}
static DWORD kuro_recovery_read(HANDLE file, KuroRecoveryState *state) {
  LARGE_INTEGER size, zero = {0};
  ZeroMemory(state, sizeof *state);
  if (!GetFileSizeEx(file, &size)) return GetLastError();
  if (size.QuadPart < 0 || size.QuadPart > (LONGLONG)(sizeof(KuroRecoveryRecord) * KURO_RECOVERY_ENDPOINTS) ||
      size.QuadPart % sizeof(KuroRecoveryRecord)) return ERROR_INVALID_DATA;
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return GetLastError();
  unsigned count = (unsigned)(size.QuadPart / sizeof(KuroRecoveryRecord));
  for (unsigned i = 0; i < count; ++i) {
    KuroRecoveryRecord record; DWORD bytes;
    if (!ReadFile(file, &record, sizeof record, &bytes, NULL)) return GetLastError();
    if (bytes != sizeof record || record.magic != 0x3152504bu || record.server[299] ||
        record.checksum != kuro_recovery_checksum(record.server) || !kuro_valid_server(record.server)) return ERROR_INVALID_DATA;
    for (unsigned j = 0; j < i; ++j) if (!wcscmp(state->servers[j], record.server)) return ERROR_INVALID_DATA;
    wcscpy(state->servers[i], record.server);
  }
  state->count = count;
  return ERROR_SUCCESS;
}
static DWORD kuro_recovery_admit(HANDLE file, const wchar_t *server) {
  if (!server || wcslen(server) >= 300 || !kuro_valid_server(server)) return ERROR_INVALID_PARAMETER;
  KuroRecoveryState state;
  DWORD error = kuro_recovery_read(file, &state);
  if (error) return error;
  for (unsigned i = 0; i < state.count; ++i) if (!wcscmp(state.servers[i], server))
    return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
  if (state.count == KURO_RECOVERY_ENDPOINTS) return ERROR_BUFFER_OVERFLOW;
  KuroRecoveryRecord record = {0};
  record.magic = 0x3152504bu;
  wcscpy(record.server, server);
  record.checksum = kuro_recovery_checksum(record.server);
  DWORD bytes;
  if (!WriteFile(file, &record, sizeof record, &bytes, NULL)) return GetLastError();
  if (bytes != sizeof record) return ERROR_WRITE_FAULT;
  return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
}
static DWORD kuro_recovery_reset_after_clear(HANDLE file) {
  LARGE_INTEGER zero = {0};
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN) || !SetEndOfFile(file) || !FlushFileBuffers(file)) return GetLastError();
  return ERROR_SUCCESS;
}
#endif
