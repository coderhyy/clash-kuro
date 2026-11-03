/* Current production engine, private files/owner and fake WinINet/registry only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <assert.h>
#include <wchar.h>
#include <stdio.h>
static int blocked(const void *unused, ...) { (void)unused; ExitProcess(90); return 0; }
static BOOL WINAPI fake_query(HINTERNET internet, DWORD option, LPVOID data, LPDWORD bytes);
static BOOL WINAPI fake_set(HINTERNET internet, DWORD option, LPVOID data, DWORD bytes);
static DWORD WINAPI fake_ras(LPCWSTR a, LPCWSTR b, LPRASENTRYNAMEW entries, LPDWORD bytes, LPDWORD count);
#define InternetQueryOptionW fake_query
#define InternetSetOptionW fake_set
#define RasEnumEntriesW fake_ras
#define RegCreateKeyExW blocked
#define RegSetValueExW blocked
#define RegOpenKeyExW blocked
#define RegDeleteValueW blocked
#define RegCloseKey blocked
static int fake_exec(int argc, wchar_t **argv);
static int fake_clear(const wchar_t **expected, int count, int recovery);
static DWORD fake_root(wchar_t *out, size_t cap);
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name);
static BOOL WINAPI fake_create_process(LPCWSTR exe, LPWSTR command, LPSECURITY_ATTRIBUTES process_sa,
  LPSECURITY_ATTRIBUTES thread_sa, BOOL inherit, DWORD flags, LPVOID env, LPCWSTR cwd,
  LPSTARTUPINFOW start, LPPROCESS_INFORMATION process);
static BOOL WINAPI fake_write_file(HANDLE file, LPCVOID data, DWORD bytes, LPDWORD written, LPOVERLAPPED overlapped);
static BOOL WINAPI fake_flush(HANDLE file);
static BOOL WINAPI fake_truncate(HANDLE file);
static DWORD fake_wait(HANDLE file, DWORD milliseconds);
static BOOL WINAPI fake_set_event(HANDLE event);
#define WriteFile fake_write_file
#define FlushFileBuffers fake_flush
#define SetEndOfFile fake_truncate
#define WaitForSingleObject fake_wait
#define SetEvent fake_set_event
#define CreateProcessW fake_create_process
#define KURO_RESIDENT_OWNER_TEST
#define KURO_RESIDENT_ROOT fake_root
#define KURO_RESIDENT_EXEC fake_exec
#define KURO_RESIDENT_CLEAR fake_clear
#define wmain unused_shipping_main
#include "../../../../../apps/desktop/native/win/kuro-sysproxy.c"
#undef wmain
#undef CreateProcessW
#undef WriteFile
#undef FlushFileBuffers
#undef SetEndOfFile
#undef WaitForSingleObject
#undef SetEvent

static wchar_t fixture_mode[64], proxy_server[300] = L"127.0.0.1:7891";
static DWORD proxy_flags = PROXY_TYPE_DIRECT;
static DWORD evidence_thread;
static int evidence_waited;
static int fault(const wchar_t *name) {
  if (!wcscmp(fixture_mode, L"diagnostics-report-delay") && !wcscmp(name, L"diagnostics-stall")) return 1;
  if (!wcsncmp(fixture_mode, L"shutdown-", 9))
    return resident_load(&resident.serving) && !wcscmp(fixture_mode + 9, name);
  return !wcscmp(fixture_mode, name);
}
static void trace(const char *text) {
  if (fault(L"diagnostics-stall")) return;
  DWORD written;
  assert(WriteFile(GetStdHandle(STD_ERROR_HANDLE), text, (DWORD)strlen(text), &written, NULL));
}
static void delay_fault(const wchar_t *hung, const wchar_t *late) {
  if (fault(hung)) Sleep(INFINITE);
  if (fault(late)) Sleep(1600);
}
static int is_readback(void) {
  return g_capture == &resident.replay_check.readback || g_capture == &resident.cleanup_check.readback;
}
static BOOL WINAPI fake_query(HINTERNET internet, DWORD option, LPVOID data, LPDWORD bytes) {
  (void)internet; (void)bytes;
  assert(option == INTERNET_OPTION_PER_CONNECTION_OPTION);
  INTERNET_PER_CONN_OPTION_LISTW *list = data;
  assert(!list->pszConnection && list->dwOptionCount == 4);
  if (is_readback()) {
    trace("readback\n");
    delay_fault(L"readback-hung", L"readback-late");
    if (fault(L"readback-fail")) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    if (fault(L"readback-reenabled")) proxy_flags |= PROXY_TYPE_PROXY;
    if (fault(L"readback-foreign")) { proxy_flags |= PROXY_TYPE_PROXY; wcscpy(proxy_server, L"127.0.0.1:9999"); }
  }
  list->pOptions[0].Value.dwValue = proxy_flags;
  size_t size = (wcslen(proxy_server) + 1) * sizeof(wchar_t);
  wchar_t *server = GlobalAlloc(GMEM_FIXED, size); assert(server); memcpy(server, proxy_server, size);
  list->pOptions[1].Value.pszValue = server;
  list->pOptions[2].Value.pszValue = list->pOptions[3].Value.pszValue = NULL;
  return TRUE;
}
static DWORD WINAPI fake_ras(LPCWSTR a, LPCWSTR b, LPRASENTRYNAMEW entries, LPDWORD bytes, LPDWORD count) {
  (void)a; (void)b; (void)entries; (void)bytes; *count = 0;
  return is_readback() && fault(L"readback-ras-fail") ? ERROR_ACCESS_DENIED : ERROR_SUCCESS;
}
static BOOL WINAPI fake_set(HINTERNET internet, DWORD option, LPVOID data, DWORD bytes) {
  (void)internet; (void)bytes;
  if (option != INTERNET_OPTION_PER_CONNECTION_OPTION) {
    assert(option == INTERNET_OPTION_PROXY_SETTINGS_CHANGED || option == INTERNET_OPTION_REFRESH);
    return TRUE;
  }
  INTERNET_PER_CONN_OPTION_LISTW *list = data;
  assert(!list->pszConnection);
  if (list->dwOptionCount == 3) {
    KuroResidentJournalState state;
    const wchar_t *server = list->pOptions[1].Value.pszValue;
    assert(!kuro_resident_journal_read(resident.recovery, &resident.binding, &state));
    int found = 0; for (unsigned i = 0; i < state.count; ++i) if (!wcscmp(state.servers[i], server)) found = 1;
    assert(found); trace("set\n");
    delay_fault(L"set-hung", L"set-late");
    if (fault(L"set-slow")) Sleep(400);
    wcscpy(proxy_server, server);
  } else assert(list->dwOptionCount == 1);
  proxy_flags = list->pOptions[0].Value.dwValue;
  return TRUE;
}
static BOOL WINAPI fake_write_file(HANDLE file, LPCVOID data, DWORD bytes, LPDWORD written, LPOVERLAPPED overlapped) {
  if (file == resident.recovery) {
    if (bytes == sizeof(KuroResidentJournalHeader)) {
      if (fault(L"header-fail")) { *written = 0; SetLastError(ERROR_DISK_FULL); return FALSE; }
      if (fault(L"header-short")) return WriteFile(file, data, bytes / 2, written, overlapped);
      if (fault(L"header-crash")) ExitProcess(77);
      if (fault(L"header-hung")) Sleep(INFINITE);
    } else if (bytes == sizeof(KuroResidentJournalRecord)) {
      trace("append-enter\n");
      if (fault(L"append-fail")) { *written = 0; SetLastError(ERROR_DISK_FULL); return FALSE; }
      if (fault(L"append-short")) return WriteFile(file, data, bytes / 2, written, overlapped);
      if (fault(L"append-hung")) Sleep(INFINITE);
    }
  } else if (file != GetStdHandle(STD_OUTPUT_HANDLE) && file != GetStdHandle(STD_ERROR_HANDLE) && fault(L"log-hung")) Sleep(INFINITE);
  return WriteFile(file, data, bytes, written, overlapped);
}
static BOOL WINAPI fake_flush(HANDLE file) {
  if (file == resident.recovery) {
    if (fault(L"flush-hung")) Sleep(INFINITE);
    if (fault(L"flush-fail")) { SetLastError(ERROR_WRITE_FAULT); return FALSE; }
  }
  return FlushFileBuffers(file);
}
static BOOL WINAPI fake_truncate(HANDLE file) {
  if (file == resident.recovery) {
    if (fault(L"reset-hung")) Sleep(INFINITE);
    if (fault(L"reset-fail")) { SetLastError(ERROR_WRITE_FAULT); return FALSE; }
  }
  return SetEndOfFile(file);
}
static DWORD fake_wait(HANDLE file, DWORD milliseconds) {
  if (fault(L"diagnostics-report-delay")) {
    // Model a blocked drain and a runnable reporter delayed beyond the final 100 ms slot.
    if (file == resident.core_output_done) return WaitForSingleObject(GetCurrentProcess(), milliseconds);
    if (file == resident.report) {
      DWORD result = WaitForSingleObject(file, milliseconds);
      if (result == WAIT_OBJECT_0) Sleep(125);
      return result;
    }
  }
  if (file == resident.reported && evidence_thread == GetCurrentThreadId() && !evidence_waited) {
    assert(WaitForSingleObject(resident.report, 0) == WAIT_OBJECT_0 && milliseconds <= 100);
    trace("evidence-wait-enter\n");
    DWORD result = WaitForSingleObject(file, milliseconds);
    evidence_waited = 1;
    trace("evidence-wait-return\n");
    return result;
  }
  if (file == resident.cleared && fault(L"delayed-supervisor")) {
    trace("supervisor-delayed\n");
    DWORD result = WaitForSingleObject(file, INFINITE);
    trace("supervisor-resumed\n"); return result;
  }
  return WaitForSingleObject(file, milliseconds);
}
static BOOL WINAPI fake_set_event(HANDLE event) {
  if (fault(L"query") || fault(L"log-hung")) {
    if (event == resident.report) {
      assert(!evidence_thread);
      evidence_thread = GetCurrentThreadId();
      trace("evidence-report-release\n");
    } else if (event == resident.finished) {
      assert(evidence_thread == GetCurrentThreadId() && evidence_waited);
      trace("evidence-session-finished\n");
    }
  }
  return SetEvent(event);
}
static BOOL WINAPI fake_create_process(LPCWSTR exe, LPWSTR command, LPSECURITY_ATTRIBUTES process_sa,
    LPSECURITY_ATTRIBUTES thread_sa, BOOL inherit, DWORD flags, LPVOID env, LPCWSTR cwd,
    LPSTARTUPINFOW start, LPPROCESS_INFORMATION process) {
  assert(resident_load(&resident.replay_ok) && (flags & CREATE_SUSPENDED));
  trace("core-create\n"); delay_fault(L"core-hung", L"core-late");
  if (fault(L"core-fail")) { SetLastError(ERROR_FILE_NOT_FOUND); return FALSE; }
  return CreateProcessW(exe, command, process_sa, thread_sa, inherit, flags, env, cwd, start, process);
}
static DWORD fake_root(wchar_t *out, size_t cap) {
  DWORD length = GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_ROOT", out, (DWORD)cap);
  wchar_t temp[MAX_PATH], long_temp[MAX_PATH], long_root[MAX_PATH];
  assert(length && length < cap && GetTempPathW(MAX_PATH, temp));
  DWORD root_length = GetLongPathNameW(out, long_root, MAX_PATH);
  DWORD temp_length = GetLongPathNameW(temp, long_temp, MAX_PATH);
  assert(root_length && root_length < MAX_PATH && root_length < cap && temp_length && temp_length < MAX_PATH);
  assert(!_wcsnicmp(long_root, long_temp, temp_length) && wcsstr(long_root, L"kuro-admission-") != NULL);
  wcscpy(out, long_root); return ERROR_SUCCESS;
}
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name) {
  wchar_t namespace[128], private_name[384];
  assert(!wcsncmp(name, L"Global\\ClashKuro.ProxyOwner.", 27));
  DWORD length = GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_NAMESPACE", namespace, 128);
  assert(length && length < 128 && wcsspn(namespace, L"0123456789abcdef-") == length);
  assert(_snwprintf(private_name, 384, L"Local\\ClashKuro.Admission.Test.%ls.%ls", namespace, name + 27) > 0);
  return CreateMutexW(sa, initial, private_name);
}
static int fake_clear(const wchar_t **expected, int count, int recovery) {
  assert(!recovery && count > 0);
  KuroResidentJournalState persisted;
  assert(!kuro_resident_journal_read(resident.recovery, &resident.binding, &persisted) && persisted.initialized);
  for (int i = 0; i < count; ++i) {
    char text[400]; assert(_snprintf(text, sizeof text, "clear:%ls\n", expected[i]) > 0); trace(text);
  }
  trace("clear-enter\n"); delay_fault(L"clear-hung", L"clear-late");
  if (fault(L"clear-slow")) Sleep(600);
  if (fault(L"delayed-supervisor")) {
    DWORD left; while ((left = resident_left(resident.start + 1600))) Sleep(left);
  }
  if (fault(L"clear-fail")) return 1;
  int result = clear_connections(expected, count, recovery);
  trace("clear-return\n"); return result;
}
static int fake_exec(int argc, wchar_t **argv) {
  assert(resident_load(&resident.serving));
  if (fault(L"query")) {
    assert(PostMessageW(resident.window, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP));
    Sleep(50);
  }
  return command_main(argc, argv);
}
int wmain(int argc, wchar_t **argv) {
  (void)blocked;
  GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_MODE", fixture_mode, 64);
  if (argc > 1 && !wcscmp(argv[1], L"-d")) {
    trace("fake-core\n");
    if (fault(L"diagnostics-stall")) { char noise[4096]; memset(noise, 'x', sizeof noise); DWORD written;
      while (WriteFile(GetStdHandle(STD_ERROR_HANDLE), noise, sizeof noise, &written, NULL)) { } }
    Sleep(INFINITE); return 99;
  }
  wchar_t value[300];
  if (GetEnvironmentVariableW(L"KURO_ADMISSION_TEST_SERVER", value, 300)) { wcscpy(proxy_server, value); proxy_flags |= PROXY_TYPE_PROXY; }
  if (argc < 2 || (wcscmp(argv[1], L"start") && wcscmp(argv[1], L"recover-admitted"))) return 1;
  return resident_main(argc, argv);
}
