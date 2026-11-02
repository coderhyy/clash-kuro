/* Private file only; shipping entry is never invoked. */
#define wmain unused_shipping_main
#include "kuro-sysproxy.c"
#undef wmain
#include "recovery-journal.h"
#include <assert.h>
int wmain(void) {
  wchar_t temp[MAX_PATH], path[MAX_PATH];
  assert(GetTempPathW(MAX_PATH, temp));
  assert(GetTempFileNameW(temp, L"krJ", 0, path));
  HANDLE file = kuro_recovery_lock(path);
  assert(file != INVALID_HANDLE_VALUE);
  KuroRecoveryState state;
  assert(!kuro_recovery_read(file, &state) && state.count == 0);
  assert(!kuro_recovery_admit(file, L"127.0.0.1:7891"));
  assert(!kuro_recovery_admit(file, L"127.0.0.1:7892"));
  assert(!kuro_recovery_admit(file, L"127.0.0.1:7891"));
  CloseHandle(file); /* Crash/restart-equivalent reopen: both A and B survive. */
  file = kuro_recovery_lock(path);
  assert(!kuro_recovery_read(file, &state) && state.count == 2);
  assert(!wcscmp(state.servers[0], L"127.0.0.1:7891"));
  assert(!wcscmp(state.servers[1], L"127.0.0.1:7892"));
  for (unsigned i = 2; i < 8; ++i) {
    wchar_t server[64]; _snwprintf(server, 64, L"127.0.0.1:%u", 7891 + i);
    assert(!kuro_recovery_admit(file, server));
  }
  assert(kuro_recovery_admit(file, L"127.0.0.1:9000") == ERROR_BUFFER_OVERFLOW);
  assert(kuro_recovery_admit(file, L"untrusted endpoint") == ERROR_INVALID_PARAMETER);
  assert(!kuro_recovery_reset_after_clear(file));
  assert(!kuro_recovery_read(file, &state) && !state.count);
  assert(!kuro_recovery_admit(file, L"127.0.0.1:7891"));
  DWORD written;
  assert(WriteFile(file, "torn", 4, &written, NULL) && written == 4);
  assert(kuro_recovery_admit(file, L"127.0.0.1:7892") == ERROR_INVALID_DATA);
  assert(!kuro_recovery_reset_after_clear(file));
  assert(!kuro_recovery_admit(file, L"127.0.0.1:7891"));
  LARGE_INTEGER offset; offset.QuadPart = 8;
  assert(SetFilePointerEx(file, offset, NULL, FILE_BEGIN));
  assert(WriteFile(file, "xx", 2, &written, NULL));
  assert(kuro_recovery_read(file, &state) == ERROR_INVALID_DATA);
  CloseHandle(file); assert(DeleteFileW(path));
  puts("recovery journal: A/B persistence, deduplication, capacity, torn/corrupt rejection, reset passed");
  return 0;
}
