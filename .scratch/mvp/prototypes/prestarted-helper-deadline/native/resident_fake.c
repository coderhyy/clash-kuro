/* Actual resident engine; all proxy operations replaced at compile time. No registry access. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <assert.h>
static int fake_exec(int argc, wchar_t **argv);
static int fake_clear(const wchar_t **expected, int count, int recovery);
static int fake_warm(void) { return 0; }
static DWORD fake_register(const wchar_t *path);
static DWORD fake_unregister(void);
#define KURO_RECOVERY_REGISTER fake_register
#define KURO_RECOVERY_UNREGISTER fake_unregister
#define KURO_RESIDENT_EXEC fake_exec
#define KURO_RESIDENT_CLEAR fake_clear
#define KURO_RESIDENT_WARM fake_warm
#define wmain helper_entry
#include "../../../../../apps/desktop/native/win/kuro-sysproxy.c"
#undef wmain
static int mode, setting, enabled;
static void fake_trace(const char *message) {
  DWORD written;
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), message, (DWORD)strlen(message), &written, NULL);
}
static DWORD fake_register(const wchar_t *path) {
  (void)path;
  if (resident.recovery_only || mode == 6) {
    fake_trace("register-start\n");
    if (mode == 4 || mode == 5 || mode == 6) Sleep(INFINITE);
    fake_trace("register-ok\n");
  }
  return ERROR_SUCCESS;
}
static DWORD fake_unregister(void) {
  if (resident.recovery_only) fake_trace("unregister\n");
  return ERROR_SUCCESS;
}
static int fake_exec(int argc, wchar_t **argv) {
  Buf result = {0};
  if (!wcscmp(argv[1], L"set")) {
    wchar_t endpoint[300];
    assert(argc >= 6 && !wcscmp(argv[2], L"--host") && !wcscmp(argv[4], L"--port"));
    assert(swprintf(endpoint, 300, L"%ls:%ls", argv[3], argv[5]) > 0);
    assert(resident.server_count == 1);
    assert(!wcscmp(endpoint, resident.servers[0]));
    assert(g_before_set(endpoint));
    setting = 1;
    DWORD written;
    if (mode == 2 || mode == 3)
      WriteFile(GetStdHandle(STD_ERROR_HANDLE), "set-start\n", 10, &written, NULL);
    if (mode == 3) Sleep(INFINITE);
    if (mode == 2) Sleep(400);
    enabled = 1; setting = 0;
    puts_(&result, "{\"command\":\"set\",\"ok\":true}");
  } else {
    assert(!wcscmp(argv[1], L"get"));
    putf(&result, "{\"command\":\"get\",\"ok\":true,\"flags\":%d}", enabled ? 3 : 1);
  }
  emit(&result); free(result.data);
  return 0;
}
static int fake_clear(const wchar_t **expected, int count, int recovery) {
  (void)recovery;
  assert(count == 1 && kuro_valid_server(expected[0]));
  assert(!setting); /* Clear must not overlap or precede the in-flight set's completion. */
  if (resident.recovery_only) fake_trace("clear-start\n");
  if (mode == 4) return 1;
  if (mode == 1) Sleep(INFINITE);
  enabled = 0;
  return 0;
}
int wmain(int argc, wchar_t **argv) {
  if (argc > 1 && !wcscmp(argv[1], L"-d")) {
    DWORD written;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), "fake-core-start\n", 16, &written, NULL);
    if (argc > 2 && wcsstr(argv[2], L"diagnostics-stall")) {
      char noise[4096]; memset(noise, 'x', sizeof noise);
      while (WriteFile(GetStdHandle(STD_ERROR_HANDLE), noise, sizeof noise, &written, NULL)) { }
    }
    Sleep(INFINITE); return 99;
  }
  if (argc < 2 || (wcscmp(argv[1], L"serve") && wcscmp(argv[1], L"recover"))) return 98; /* Never expose the real one-shot CLI. */
  if (!wcscmp(argv[1], L"recover")) for (int i = 2; i + 1 < argc; i += 2)
    if (!wcscmp(argv[i], L"--recovery")) {
      if (wcsstr(argv[i + 1], L"recovery-hang.bin")) mode = 1;
      if (wcsstr(argv[i + 1], L"recovery-clear-fail.bin")) mode = 4;
      if (wcsstr(argv[i + 1], L"recovery-register-hang.bin")) mode = 5;
    }
  for (int i = 2; i + 1 < argc; i += 2) if (!wcscmp(argv[i], L"--data")) {
    const wchar_t *name = wcsrchr(argv[i + 1], L'\\'); name = name ? name + 1 : argv[i + 1];
    mode = !wcscmp(name, L"clear-hang") || !wcscmp(name, L"replay-registration") ? 1 :
      !wcscmp(name, L"late-set") ? 2 : !wcscmp(name, L"set-hang") ? 3 : !wcscmp(name, L"register-hang") ? 6 : 0;
  }
  return helper_entry(argc, argv);
}
