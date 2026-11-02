#ifndef KURO_MIGRATION_FILES_H
#define KURO_MIGRATION_FILES_H
#include <windows.h>
#include <wchar.h>

/* The coordinator verifies canonical local parents and flushes source bytes first.
   This command publishes a file only; it never reads or changes proxy/RunOnce state. */
static DWORD kuro_migration_publish(const wchar_t *source, const wchar_t *destination, int replace) {
  if (!source || !destination || wcslen(source) < 4 || wcslen(destination) < 4 ||
      source[1] != L':' || source[2] != L'\\' || destination[1] != L':' || destination[2] != L'\\' ||
      !_wcsicmp(source, destination)) return ERROR_INVALID_PARAMETER;
  const wchar_t *a = wcsrchr(source, L'\\'), *b = wcsrchr(destination, L'\\');
  if (!a || !b || a - source != b - destination || _wcsnicmp(source, destination, (size_t)(a - source)))
    return ERROR_INVALID_PARAMETER;
  DWORD attributes = GetFileAttributesW(source);
  if (attributes == INVALID_FILE_ATTRIBUTES) return GetLastError();
  if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
  attributes = GetFileAttributesW(destination);
  if (attributes != INVALID_FILE_ATTRIBUTES) {
    if (!replace) return ERROR_ALREADY_EXISTS;
    if (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
  } else if (GetLastError() != ERROR_FILE_NOT_FOUND) return GetLastError();
  return MoveFileExW(source, destination, MOVEFILE_WRITE_THROUGH | (replace ? MOVEFILE_REPLACE_EXISTING : 0))
    ? ERROR_SUCCESS : GetLastError();
}
#endif
