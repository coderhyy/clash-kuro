/* Negative regression test: fake WinINet/RAS and forbidden registry APIs only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <assert.h>
#include <wchar.h>
static DWORD flags = PROXY_TYPE_DIRECT;
static wchar_t server[300];
static int registry_calls;
static int forbidden_registry(const void *unused, ...) {
  (void)unused; ++registry_calls; assert(!"No current command may touch RunOnce"); return ERROR_ACCESS_DENIED;
}
static DWORD WINAPI fake_ras(LPCWSTR a, LPCWSTR b, LPRASENTRYNAMEW entries, LPDWORD bytes, LPDWORD count) {
  (void)a; (void)b; (void)entries; (void)bytes; *count = 0; return ERROR_SUCCESS;
}
static BOOL WINAPI fake_query(HINTERNET internet, DWORD option, LPVOID data, LPDWORD bytes) {
  (void)internet; (void)bytes; assert(option == INTERNET_OPTION_PER_CONNECTION_OPTION);
  INTERNET_PER_CONN_OPTION_LISTW *list = data;
  list->pOptions[0].Value.dwValue = flags;
  size_t size = (wcslen(server) + 1) * sizeof(wchar_t);
  wchar_t *copy = GlobalAlloc(GMEM_FIXED, size); assert(copy); memcpy(copy, server, size);
  list->pOptions[1].Value.pszValue = copy;
  return TRUE;
}
static BOOL WINAPI fake_set(HINTERNET internet, DWORD option, LPVOID data, DWORD bytes) {
  (void)internet; (void)bytes;
  if (option == INTERNET_OPTION_PER_CONNECTION_OPTION) {
    INTERNET_PER_CONN_OPTION_LISTW *list = data;
    flags = list->pOptions[0].Value.dwValue;
    if (list->dwOptionCount == 3) wcscpy(server, list->pOptions[1].Value.pszValue);
  }
  return TRUE;
}
#define RasEnumEntriesW fake_ras
#define InternetQueryOptionW fake_query
#define InternetSetOptionW fake_set
#define RegCreateKeyExW forbidden_registry
#define RegSetValueExW forbidden_registry
#define RegOpenKeyExW forbidden_registry
#define RegQueryValueExW forbidden_registry
#define RegDeleteValueW forbidden_registry
#define RegCloseKey forbidden_registry
#define wmain shipping_main
#include "kuro-sysproxy.c"
#undef wmain
int wmain(void) {
  (void)forbidden_registry;
  Buf result = {0}; g_capture = &result;
  const wchar_t *expected[] = { L"127.0.0.1:7891" };
  /* Even former registration=true call sites cannot create/delete a value. */
  assert(!set_connections(expected[0], L"localhost", 1));
  assert(flags & PROXY_TYPE_PROXY);
  assert(!clear_connections(expected, 1, 1));
  assert(!(flags & PROXY_TYPE_PROXY));
  assert(!get_connections(expected, 1));
  assert(!registry_calls && !strstr(result.data, "runOnce"));
  free(result.data);
  /* Model preemption after the first reason CAS; another caller must finish publication. */
  resident.close = CreateEventW(NULL, TRUE, FALSE, NULL); assert(resident.close);
  resident.first_trigger = RES_CLOSE_QUERY;
  resident_close_reason(RES_CLOSE_IPC);
  assert(resident.trigger_epoch && resident.first_trigger == RES_CLOSE_QUERY);
  assert(WaitForSingleObject(resident.close, 0) == WAIT_OBJECT_0);
  ULONGLONG start = resident.start, epoch = resident.trigger_epoch;
  Sleep(1); resident_close_reason(RES_CLOSE_END);
  assert(start == resident.start && epoch == resident.trigger_epoch);
  assert(resident.first_trigger == RES_CLOSE_QUERY && (resident.triggers & RES_CLOSE_END));
  CloseHandle(resident.close);
  puts("no RunOnce: successful set/clear/readback never call registry APIs");
  return 0;
}
