/* Fake registry only. Never call shipping CLI. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <wchar.h>
static int mode, writes, deletes;
static wchar_t saved[260];
static LSTATUS WINAPI fake_create(HKEY root, LPCWSTR name, DWORD reserved, LPWSTR cls, DWORD options,
    REGSAM access, const LPSECURITY_ATTRIBUTES sa, PHKEY key, LPDWORD disposition) {
  (void)root; (void)name; (void)reserved; (void)cls; (void)options; (void)access; (void)sa; (void)disposition;
  *key = (HKEY)(ULONG_PTR)1; return mode == 1 ? ERROR_ACCESS_DENIED : ERROR_SUCCESS;
}
static LSTATUS WINAPI fake_set(HKEY key, LPCWSTR name, DWORD reserved, DWORD type, const BYTE *bytes, DWORD size) {
  (void)key; (void)reserved;
  assert(!wcscmp(name, L"ClashKuroResidentCleanup") && type == REG_SZ && size <= sizeof saved);
  ++writes; memcpy(saved, bytes, size); return mode == 2 ? ERROR_ACCESS_DENIED : ERROR_SUCCESS;
}
static LSTATUS WINAPI fake_open(HKEY root, LPCWSTR name, DWORD options, REGSAM access, PHKEY key) {
  (void)root; (void)name; (void)options; (void)access;
  *key = (HKEY)(ULONG_PTR)1; return mode == 3 ? ERROR_FILE_NOT_FOUND : ERROR_SUCCESS;
}
static LSTATUS WINAPI fake_delete(HKEY key, LPCWSTR name) {
  (void)key; assert(!wcscmp(name, L"ClashKuroResidentCleanup")); ++deletes;
  return mode == 4 ? ERROR_ACCESS_DENIED : ERROR_SUCCESS;
}
static LSTATUS WINAPI fake_close(HKEY key) { (void)key; return ERROR_SUCCESS; }
#define RegCreateKeyExW fake_create
#define RegSetValueExW fake_set
#define RegOpenKeyExW fake_open
#define RegDeleteValueW fake_delete
#define RegCloseKey fake_close
#define wmain shipping_main
#include "kuro-sysproxy.c"
#undef wmain
int wmain(void) {
  wchar_t exe[MAX_PATH], journal[MAX_PATH], expected[MAX_PATH];
  assert(!kuro_recovery_paths(exe, journal));
  assert(!kuro_recovery_register(journal));
  _snwprintf(expected, MAX_PATH, L"\"%ls\" recover", exe);
  assert(!wcscmp(saved, expected) && writes == 1);
  assert(kuro_recovery_register(L"C:\\different\\recovery.bin") == ERROR_INVALID_PARAMETER && writes == 1);
  mode = 1; assert(kuro_recovery_register(journal) == ERROR_ACCESS_DENIED && writes == 1);
  mode = 2; assert(kuro_recovery_register(journal) == ERROR_ACCESS_DENIED && writes == 2);
  mode = 3; assert(!kuro_recovery_unregister() && !deletes);
  mode = 4; assert(kuro_recovery_unregister() == ERROR_ACCESS_DENIED && deletes == 1);
  mode = 0; assert(!kuro_recovery_unregister() && deletes == 2);
  puts("recovery registration: quoted stable command, matching journal, failure propagation, separate value passed");
  return 0;
}
