/* Only a private temporary file and exact test child; no proxy or registry APIs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include "recovery-lock.h"

int wmain(int argc, wchar_t **argv) {
  if (argc == 3) {
    HANDLE lock = kuro_recovery_lock(argv[2]);
    if (!wcscmp(argv[1], L"contend")) {
      assert(lock == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION);
      return 0;
    }
    assert(lock != INVALID_HANDLE_VALUE);
    /* Abrupt owner death must release the lock without running cleanup code. */
    TerminateProcess(GetCurrentProcess(), 17);
    return 99;
  }
  wchar_t temp[MAX_PATH], path[MAX_PATH], exe[MAX_PATH], command[3 * MAX_PATH];
  assert(GetTempPathW(MAX_PATH, temp));
  assert(kuro_recovery_lock(NULL) == INVALID_HANDLE_VALUE && GetLastError() == ERROR_INVALID_PARAMETER);
  assert(kuro_recovery_lock(temp) == INVALID_HANDLE_VALUE);
  assert(GetTempFileNameW(temp, L"krL", 0, path));
  assert(GetModuleFileNameW(NULL, exe, MAX_PATH));
  HANDLE lock = kuro_recovery_lock(path);
  assert(lock != INVALID_HANDLE_VALUE);
  DWORD flags = HANDLE_FLAG_INHERIT;
  assert(GetHandleInformation(lock, &flags) && !(flags & HANDLE_FLAG_INHERIT));
  assert(!DeleteFileW(path)); /* Prevent a second owner from replacing the lock identity. */
  for (int phase = 0; phase < 2; ++phase) {
    if (phase) { CloseHandle(lock); lock = INVALID_HANDLE_VALUE; }
    _snwprintf(command, 3 * MAX_PATH, L"\"%ls\" %ls \"%ls\"", exe, phase ? L"die" : L"contend", path);
    STARTUPINFOW startup = {0}; startup.cb = sizeof startup;
    PROCESS_INFORMATION child = {0};
    assert(CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child));
    DWORD waited = WaitForSingleObject(child.hProcess, 3000);
    if (waited != WAIT_OBJECT_0) {
      TerminateProcess(child.hProcess, 98);
      WaitForSingleObject(child.hProcess, 1000);
    }
    assert(waited == WAIT_OBJECT_0); /* Rescue is failure. */
    DWORD code; assert(GetExitCodeProcess(child.hProcess, &code));
    assert(code == (phase ? 17 : 0));
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
  }
  lock = kuro_recovery_lock(path);
  assert(lock != INVALID_HANDLE_VALUE);
  CloseHandle(lock);
  assert(DeleteFileW(path));
  puts("recovery lock: cross-process exclusion, noninheritance, owner-death release passed");
  return 0;
}
