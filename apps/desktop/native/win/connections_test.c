// Fake WinINet/RAS and registry access: this test never reads or changes real proxy settings.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <assert.h>

static DWORD WINAPI failed_ras(LPCWSTR reserved, LPCWSTR book, LPRASENTRYNAMEW entries, LPDWORD size, LPDWORD count) {
  (void)reserved; (void)book; (void)entries; (void)size;
  *count = 0;
  return ERROR_ACCESS_DENIED;
}
static BOOL WINAPI direct_lan(HINTERNET internet, DWORD option, LPVOID buffer, LPDWORD size) {
  (void)internet; (void)option; (void)size;
  INTERNET_PER_CONN_OPTION_LISTW *list = buffer;
  list->pOptions[0].Value.dwValue = PROXY_TYPE_DIRECT;
  return TRUE;
}
static BOOL WINAPI reject_write(HINTERNET internet, DWORD option, LPVOID buffer, DWORD size) {
  (void)internet; (void)option; (void)buffer; (void)size;
  SetLastError(ERROR_ACCESS_DENIED);
  return FALSE;
}
static LSTATUS WINAPI forbidden_recovery(HKEY root, LPCWSTR name, DWORD options, REGSAM access, PHKEY key) {
  (void)root; (void)name; (void)options; (void)access; (void)key;
  assert(!"Incomplete RAS enumeration must retain recovery registration");
  return ERROR_ACCESS_DENIED;
}
#define RasEnumEntriesW failed_ras
#define InternetQueryOptionW direct_lan
#define InternetSetOptionW reject_write
#define RegOpenKeyExW forbidden_recovery
#define wmain shipping_main
#include "kuro-sysproxy.c"
#undef wmain

int wmain(void) {
  const wchar_t *expected[] = { L"127.0.0.1:7891" };
  assert(cmd_get() == 2);
  assert(clear_connections(expected, 1, 1) == 2);
  assert(set_connections(expected[0], L"localhost", 0) == 2);
  return 0;
}
