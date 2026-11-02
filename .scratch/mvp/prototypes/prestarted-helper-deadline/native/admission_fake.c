/* Actual engine with private ownership/root and fake proxy/registry only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <assert.h>
#include <wchar.h>
#include <stdio.h>
static int blocked(const void *unused, ...) { (void)unused; ExitProcess(90); return 0; }
#define InternetQueryOptionW blocked
#define InternetSetOptionW blocked
#define RasEnumEntriesW blocked
#define RegCreateKeyExW blocked
#define RegSetValueExW blocked
#define RegOpenKeyExW blocked
#define RegDeleteValueW blocked
#define RegCloseKey blocked
static int fake_exec(int argc, wchar_t **argv);
static int fake_clear(const wchar_t **expected, int count, int recovery);
static int fake_warm(void);
static DWORD fake_register(const wchar_t *path);
static DWORD fake_unregister(void);
static DWORD fake_root(wchar_t *out, size_t cap);
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name);
static BOOL WINAPI fake_create_process(LPCWSTR exe, LPWSTR command, LPSECURITY_ATTRIBUTES process_sa,
  LPSECURITY_ATTRIBUTES thread_sa, BOOL inherit, DWORD flags, LPVOID env, LPCWSTR cwd,
  LPSTARTUPINFOW start, LPPROCESS_INFORMATION process);
static BOOL WINAPI fake_write_file(HANDLE file, LPCVOID data, DWORD bytes, LPDWORD written, LPOVERLAPPED overlapped);
#define WriteFile fake_write_file
#define CreateProcessW fake_create_process
#define KURO_RESIDENT_OWNER_TEST
#define KURO_RESIDENT_ROOT fake_root
#define KURO_RESIDENT_EXEC fake_exec
#define KURO_RESIDENT_CLEAR fake_clear
#define KURO_RESIDENT_WARM fake_warm
#define KURO_RECOVERY_REGISTER fake_register
#define KURO_RECOVERY_REGISTER_ADMITTED fake_register
#define KURO_RECOVERY_UNREGISTER fake_unregister
#define wmain unused_shipping_main
#include "../../../../../apps/desktop/native/win/kuro-sysproxy.c"
#undef wmain
#undef CreateProcessW
#undef WriteFile

static wchar_t fixture_mode[64];
static void trace(const char *text) {
  DWORD written;
  assert(WriteFile(GetStdHandle(STD_ERROR_HANDLE), text, (DWORD)strlen(text), &written, NULL));
}
static BOOL WINAPI fake_write_file(HANDLE file, LPCVOID data, DWORD bytes, LPDWORD written, LPOVERLAPPED overlapped) {
  if (file == resident.recovery && resident.initial_count && !resident_load(&resident.admitted)) {
    LARGE_INTEGER zero = {0}, position;
    assert(SetFilePointerEx(file, zero, &position, FILE_CURRENT));
    if (position.QuadPart == sizeof(KuroResidentJournalHeader)) {
      if (!wcscmp(fixture_mode, L"seed-write-fail")) { *written = 0; SetLastError(ERROR_DISK_FULL); return FALSE; }
      if (!wcscmp(fixture_mode, L"seed-write-short")) {
        assert(bytes > sizeof(KuroResidentJournalRecord));
        return WriteFile(file, data, sizeof(KuroResidentJournalRecord) + 13, written, overlapped);
      }
      if (!wcscmp(fixture_mode, L"seed-write-hung")) Sleep(INFINITE);
    }
    if (!position.QuadPart && bytes == sizeof(KuroResidentJournalHeader)) {
      if (!wcscmp(fixture_mode, L"seed-header-fail")) { *written = 0; SetLastError(ERROR_DISK_FULL); return FALSE; }
      /* Records have already been flushed; simulate death before publishing provenance. */
      if (!wcscmp(fixture_mode, L"seed-header-crash")) ExitProcess(77);
      if (!wcscmp(fixture_mode, L"seed-header-short")) return WriteFile(file, data, bytes / 2, written, overlapped);
    }
  }
  if (file == GetStdHandle(STD_OUTPUT_HANDLE) && bytes >= 16 && !memcmp(data, "{\"reserved\":true", 16) &&
      (!wcscmp(fixture_mode, L"seed-query") || !wcscmp(fixture_mode, L"existing-query"))) {
    BOOL ok = WriteFile(file, data, bytes, written, overlapped);
    assert(ok && PostMessageW(resident.window, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP));
    return ok;
  }
  return WriteFile(file, data, bytes, written, overlapped);
}
static BOOL WINAPI fake_create_process(LPCWSTR exe, LPWSTR command, LPSECURITY_ATTRIBUTES process_sa,
    LPSECURITY_ATTRIBUTES thread_sa, BOOL inherit, DWORD flags, LPVOID env, LPCWSTR cwd,
    LPSTARTUPINFOW start, LPPROCESS_INFORMATION process) {
  assert(resident_load(&resident.admitted) && (flags & CREATE_SUSPENDED));
  trace("core-create\n");
  if (!wcscmp(fixture_mode, L"core-hung")) Sleep(INFINITE);
  if (!wcscmp(fixture_mode, L"core-late")) Sleep(1600);
  return CreateProcessW(exe, command, process_sa, thread_sa, inherit, flags, env, cwd, start, process);
}
static DWORD fake_root(wchar_t *out, size_t cap) {
  DWORD length = GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_ROOT", out, (DWORD)cap);
  wchar_t temp[MAX_PATH], long_temp[MAX_PATH], long_root[MAX_PATH];
  assert(length && length < cap && GetTempPathW(MAX_PATH, temp));
  DWORD root_length = GetLongPathNameW(out, long_root, MAX_PATH);
  DWORD temp_length = GetLongPathNameW(temp, long_temp, MAX_PATH);
  assert(root_length && root_length < MAX_PATH && root_length < cap && temp_length && temp_length < MAX_PATH);
  /* Hosted Windows may spell TEMP with RUNNER~1 while Node realpath uses its long name. */
  assert(!_wcsnicmp(long_root, long_temp, temp_length) && wcsstr(long_root, L"kuro-admission-") != NULL);
  wcscpy(out, long_root);
  return ERROR_SUCCESS;
}
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name) {
  wchar_t namespace[128], private_name[384];
  assert(!wcsncmp(name, L"Global\\ClashKuro.ProxyOwner.", 27));
  DWORD length = GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_NAMESPACE", namespace, 128);
  assert(length && length < 128 && wcsspn(namespace, L"0123456789abcdef-") == length);
  assert(_snwprintf(private_name, 384, L"Local\\ClashKuro.Admission.Test.%ls.%ls", namespace, name + 27) > 0);
  return CreateMutexW(sa, initial, private_name);
}
static int fake_warm(void) {
  trace("warm\n");
  if (!wcscmp(fixture_mode, L"warm-hung")) Sleep(INFINITE);
  if (!wcscmp(fixture_mode, L"warm-late")) Sleep(1600);
  if (!wcscmp(fixture_mode, L"warm-fail")) return 1;
  return 0;
}
static DWORD fake_register(const wchar_t *path) {
  assert(resident_load(&resident.admitted) && wcsstr(path, L".exe"));
  trace("register\n"); return ERROR_SUCCESS;
}
static DWORD fake_unregister(void) {
  assert(resident_load(&resident.admitted));
  trace("unregister\n");
  if (!wcscmp(fixture_mode, L"unregister-hung")) Sleep(INFINITE);
  if (!wcscmp(fixture_mode, L"unregister-late")) Sleep(1600);
  return !wcscmp(fixture_mode, L"unregister-fail") ? ERROR_ACCESS_DENIED : ERROR_SUCCESS;
}
static int fake_clear(const wchar_t **expected, int count, int recovery) {
  assert(resident_load(&resident.admitted) && !recovery && count > 0);
  if (!resident_load(&resident.serving)) {
    KuroResidentJournalState persisted;
    assert(!kuro_resident_journal_read(resident.recovery, &resident.binding, &persisted) && persisted.initialized);
    assert(persisted.count == (unsigned)count);
    for (int i = 0; i < count; ++i) assert(!wcscmp(persisted.servers[i], expected[i]));
  }
  for (int i = 0; i < count; ++i) {
    char text[400];
    assert(_snprintf(text, sizeof text, "clear:%ls\n", expected[i]) > 0);
    trace(text);
  }
  trace("clear-enter\n");
  if (!resident_load(&resident.serving)) {
    if (!wcscmp(fixture_mode, L"hung")) Sleep(INFINITE);
    if (!wcscmp(fixture_mode, L"late")) Sleep(1600);
    if (!wcscmp(fixture_mode, L"slow")) Sleep(600);
    if (!wcscmp(fixture_mode, L"fail")) return 1;
  }
  trace("clear-return\n");
  return 0;
}
static int fake_exec(int argc, wchar_t **argv) {
  assert(resident_load(&resident.serving));
  Buf result = {0};
  if (!wcscmp(argv[1], L"set")) {
    assert((argc == 6 || (argc == 8 && !wcscmp(argv[6], L"--bypass"))) &&
      !wcscmp(argv[2], L"--host") && !wcscmp(argv[4], L"--port"));
    wchar_t endpoint[300];
    _snwprintf(endpoint, 300, L"%ls:%ls", argv[3], argv[5]);
    if (!g_before_set(endpoint)) return 1;
    trace("set\n"); puts_(&result, "{\"command\":\"set\",\"ok\":true,\"connections\":[{\"name\":null,\"status\":\"set\"}]}");
  } else if (!wcscmp(argv[1], L"clear")) {
    assert(argc == 4 && !wcscmp(argv[2], L"--expected-server"));
    const wchar_t *expected[] = {argv[3]};
    if (fake_clear(expected, 1, 0)) return 1;
    puts_(&result, "{\"command\":\"clear\",\"ok\":true,\"connections\":[{\"name\":null,\"status\":\"cleared\"}]}");
  } else {
    assert(argc == 2 && !wcscmp(argv[1], L"get"));
    puts_(&result, "{\"command\":\"get\",\"ok\":true,\"connections\":[{\"name\":null,\"flags\":1,\"proxyServer\":null,\"bypass\":null,\"autoConfigUrl\":null}]}");
  }
  emit(&result); free(result.data); return 0;
}

int wmain(int argc, wchar_t **argv) {
  if (argc > 1 && !wcscmp(argv[1], L"-d")) { trace("fake-core\n"); Sleep(INFINITE); return 99; }
  assert(argc > 1 && (!wcscmp(argv[1], L"reserve") || !wcscmp(argv[1], L"recover-admitted")));
  GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_MODE", fixture_mode, 64);
  return resident_main(argc, argv); /* Never expose any shipping one-shot operation. */
}
