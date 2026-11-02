/* Actual resident IPC/WinINet engine, fake Core, private registry key. CI exercise only. */
#define RUNONCE_KEY L"Software\\ClashKuroWininetServeFixture"
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"

static HANDLE requests, responses;
static Backup saved;
static LONG verified;
static const wchar_t endpoint[] = L"127.0.0.1:48967";

static int send_bytes(const void *bytes, DWORD size) {
  DWORD written;
  return WriteFile(requests, bytes, size, &written, NULL) && written == size;
}
static int line(char *text, DWORD capacity) {
  for (DWORD i = 0; i + 1 < capacity; ++i) {
    DWORD got;
    if (!ReadFile(responses, text + i, 1, &got, NULL) || got != 1) return 0;
    if (text[i] == '\n') { text[i + 1] = 0; return 1; }
  }
  return 0;
}
static int registration(int present) {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, RUNONCE_KEY, 0, KEY_QUERY_VALUE, &key)) return 0;
  wchar_t value[MAX_PATH]; DWORD type = 0, size = sizeof value;
  LSTATUS error = RegQueryValueExW(key, KURO_RECOVERY_VALUE, NULL, &type, (BYTE *)value, &size);
  RegCloseKey(key);
  if (!present) return error == ERROR_FILE_NOT_FOUND;
  wchar_t exe[MAX_PATH], journal[MAX_PATH], expected[MAX_PATH];
  if (kuro_recovery_paths(exe, journal)) return 0;
  _snwprintf(expected, MAX_PATH, L"\"%ls\" recover", exe);
  return error == ERROR_SUCCESS && type == REG_SZ && size == (wcslen(expected) + 1) * sizeof(wchar_t) &&
    !memcmp(value, expected, size);
}
static DWORD WINAPI drive(void *unused) {
  (void)unused;
  char response[4096];
  const wchar_t command[] = L"set\0--host\0" L"127.0.0.1\0--port\0" L"48967\0--bypass\0" TEST_BYPASS;
  const uint32_t header[] = { 1, sizeof command }, close[] = { 2, 0 };
  int ok = line(response, sizeof response) && strstr(response, "\"ready\":true") &&
    send_bytes(header, sizeof header) && send_bytes(command, sizeof command) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"set\"") && strstr(response, "\"ok\":true") &&
    registration(1) && verify_fixture(&saved, endpoint, 3);
  if (!ok) { resident_close(); return 2; }
  ok = send_bytes(close, sizeof close) && send_bytes(close, sizeof close) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"shutdown\"") && strstr(response, "\"ok\":true") &&
    registration(0) && verify_fixture(&saved, endpoint, 1);
  InterlockedExchange(&verified, ok);
  return ok ? 0 : 2;
}

int wmain(int argc, wchar_t **argv) {
  if (argc > 1 && !wcscmp(argv[1], L"-d")) { Sleep(INFINITE); return 99; }
  if (argc != 6 || wcscmp(argv[1], L"resident-cycle") || wcscmp(argv[5], L"serve") || wcscmp(argv[3], endpoint)) return 1;
  if (!load_backup(argv[2], &saved) || !preflight(&saved, NULL)) return 2;
  HKEY key; DWORD disposition;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, RUNONCE_KEY, 0, NULL, 0, KEY_QUERY_VALUE, NULL, &key, &disposition)) return 2;
  RegCloseKey(key);
  if (disposition != REG_CREATED_NEW_KEY) return 2; /* Never overwrite another run's evidence. */
  wchar_t exe[MAX_PATH], journal[MAX_PATH], folder[MAX_PATH];
  if (kuro_recovery_paths(exe, journal)) return 2;
  wcscpy(folder, exe); wchar_t *slash = wcsrchr(folder, L'\\'); if (!slash) return 2; *slash = 0;
  if (GetFileAttributesW(journal) != INVALID_FILE_ATTRIBUTES || GetLastError() != ERROR_FILE_NOT_FOUND) return 2;
  HANDLE input, output, original = GetStdHandle(STD_OUTPUT_HANDLE);
  if (!CreatePipe(&input, &requests, NULL, 0) || !CreatePipe(&responses, &output, NULL, 0) ||
      !SetStdHandle(STD_INPUT_HANDLE, input) || !SetStdHandle(STD_OUTPUT_HANDLE, output)) return 2;
  HANDLE driver = CreateThread(NULL, 0, drive, NULL, 0, NULL); if (!driver) return 2;
  wchar_t *args[] = { exe, L"serve", L"--core", exe, L"--data", folder, L"--recovery", journal,
    L"--expected-server", (wchar_t *)endpoint, L"--log", argv[4] };
  int result = resident_main(12, args);
  if (result || WaitForSingleObject(driver, resident_left(resident.start + 2200)) != WAIT_OBJECT_0 || !verified) return 2;
  CloseHandle(driver);
  KuroRecoveryState state;
  if (kuro_recovery_read(resident.recovery, &state) || state.count) return 2;
  CloseHandle(resident.recovery);
  if (!DeleteFileW(journal) || RegDeleteKeyW(HKEY_CURRENT_USER, RUNONCE_KEY)) return 2;
  SetStdHandle(STD_OUTPUT_HANDLE, original); g_capture = NULL; g_log = NULL;
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1,\"privateRegistrationVerified\":true}", saved.count);
  emit(&report); free(report.data);
  return 0;
}
