#ifndef KURO_RECOVERY_LOCK_H
#define KURO_RECOVERY_LOCK_H
#include <windows.h>

/* Stable per-user file, never deleted/replaced while recovery is supported.
   No sharing and no handle inheritance: only owner process death/close releases it.
   Fail immediately on contention; callers must not retry with a new deadline.
   This bounds our waiting policy, not latency inside filesystem/kernel calls. */
static HANDLE kuro_recovery_lock(const wchar_t *path) {
  if (!path || !*path) { SetLastError(ERROR_INVALID_PARAMETER); return INVALID_HANDLE_VALUE; }
  HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (file == INVALID_HANDLE_VALUE) return file;
  FILE_ATTRIBUTE_TAG_INFO info;
  if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &info, sizeof info)) {
    DWORD error = GetLastError(); CloseHandle(file); SetLastError(error); return INVALID_HANDLE_VALUE;
  }
  if (info.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) {
    CloseHandle(file); SetLastError(ERROR_ACCESS_DENIED); return INVALID_HANDLE_VALUE;
  }
  return file;
}
#endif
