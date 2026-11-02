/* Actual resident engine; all proxy operations replaced at compile time. No registry access. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <assert.h>
static int fake_exec(int argc, wchar_t **argv);
static int fake_clear(const wchar_t **expected, int count, int recovery);
static int fake_warm(void) { return 0; }
#define KURO_RESIDENT_EXEC fake_exec
#define KURO_RESIDENT_CLEAR fake_clear
#define KURO_RESIDENT_WARM fake_warm
#define wmain helper_entry
#include "../../../../../apps/desktop/native/win/kuro-sysproxy.c"
#undef wmain
static int mode, setting, enabled;
static int fake_exec(int argc, wchar_t **argv) {
  (void)argc;
  Buf result = {0};
  if (!wcscmp(argv[1], L"set")) {
    assert(g_before_set(L"127.0.0.1:7891"));
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
  assert(count == 1 && !wcscmp(expected[0], L"127.0.0.1:7891"));
  assert(!setting); /* Clear must not overlap or precede the in-flight set's completion. */
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
  if (argc < 2 || wcscmp(argv[1], L"serve")) return 98; /* Never expose the real one-shot CLI. */
  for (int i = 2; i + 1 < argc; i += 2) if (!wcscmp(argv[i], L"--data")) {
    const wchar_t *name = wcsrchr(argv[i + 1], L'\\'); name = name ? name + 1 : argv[i + 1];
    mode = !wcscmp(name, L"clear-hang") ? 1 : !wcscmp(name, L"late-set") ? 2 : !wcscmp(name, L"set-hang") ? 3 : 0;
  }
  return helper_entry(argc, argv);
}
