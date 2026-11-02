/* Actual protocol2/WinINet engine, fake Core, private ownership/root/registry. CI only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <wchar.h>
static DWORD fixture_root(wchar_t *out, size_t cap);
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name);
#define KURO_RESIDENT_OWNER_TEST
#define KURO_RESIDENT_ROOT fixture_root
#define RUNONCE_KEY L"Software\\ClashKuroWininetServeFixture"
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"

static HANDLE requests, responses;
static Backup saved;
static LONG verified;
static const wchar_t endpoint[] = L"127.0.0.1:48967";
static wchar_t private_root[MAX_PATH], private_mutex[128];
static BYTE receipt[32], evidence[32];

static DWORD fixture_root(wchar_t *out, size_t cap) {
  size_t length = wcslen(private_root);
  if (!length || length >= cap) return ERROR_INVALID_PARAMETER;
  wcscpy(out, private_root); return ERROR_SUCCESS;
}
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name) {
  if (wcsncmp(name, L"Global\\ClashKuro.ProxyOwner.", 27) || !private_mutex[0]) {
    SetLastError(ERROR_INVALID_PARAMETER); return NULL;
  }
  return CreateMutexW(sa, initial, private_mutex);
}
static int fixture_paths(void) {
  wchar_t temp[MAX_PATH], expanded[MAX_PATH], text[40]; GUID id;
  DWORD length = GetTempPathW(MAX_PATH, temp);
  if (!length || length >= MAX_PATH || CoCreateGuid(&id) != S_OK || !StringFromGUID2(&id, text, 40)) return 0;
  length = GetLongPathNameW(temp, expanded, MAX_PATH);
  if (!length || length >= MAX_PATH) return 0;
  int count = _snwprintf(private_root, MAX_PATH, L"%lskuro-wininet-serve-%ls", expanded, text);
  if (count <= 0 || count + 70 >= MAX_PATH) return 0;
  return _snwprintf(private_mutex, 128, L"Local\\ClashKuro.WininetServeFixture.%ls", text) > 0;
}
static int fixture_proof(void) {
  /* Synthetic fixture commitments, NOT migration receipt/evidence authorization. */
  const char r[] = "wininet-serve: test-only receipt v2", e[] = "wininet-serve: test-only evidence v2";
  return !kuro_resident_sha256(r, sizeof r - 1, receipt) && !kuro_resident_sha256(e, sizeof e - 1, evidence);
}
static int digest_matches(const char *response, const char *field, const BYTE digest[32]) {
  char hex[65], expected[128]; resident_hex(digest, hex);
  int count = snprintf(expected, sizeof expected, "\"%s\":\"%s\"", field, hex);
  return count > 0 && count < (int)sizeof expected && strstr(response, expected) != NULL;
}
static int provenance_preserved(void) {
  KuroResidentJournalState state;
  return !kuro_resident_journal_read(resident.recovery, &resident.binding, &state) && state.initialized && !state.count &&
    !memcmp(state.provenance.receipt_sha256, receipt, 32) && !memcmp(state.provenance.evidence_sha256, evidence, 32);
}

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
  wchar_t value[MAX_PATH + 32]; DWORD type = 0, size = sizeof value;
  LSTATUS error = RegQueryValueExW(key, KURO_RECOVERY_VALUE, NULL, &type, (BYTE *)value, &size);
  RegCloseKey(key);
  if (!present) return error == ERROR_FILE_NOT_FOUND;
  wchar_t expected[MAX_PATH + 32];
  _snwprintf(expected, MAX_PATH + 32, L"\"%ls\" recover-admitted", resident.retained_path);
  return error == ERROR_SUCCESS && type == REG_SZ && size == (wcslen(expected) + 1) * sizeof(wchar_t) &&
    !memcmp(value, expected, size);
}
static DWORD WINAPI drive(void *unused) {
  (void)unused;
  char response[4096];
  const wchar_t command[] = L"set\0--host\0" L"127.0.0.1\0--port\0" L"48967\0--bypass\0" TEST_BYPASS;
  const uint32_t header[] = { 1, sizeof command }, close[] = { 2, 0 };
  const uint32_t admission[] = { 3, KURO_ADMISSION_BYTES };
  int ok = line(response, sizeof response) && strstr(response, "\"reserved\":true,\"protocol\":2") &&
    strstr(response, "\"admissionReceiptDigest\":null,\"priorEndpoints\":[],\"initialEndpoints\":[\"127.0.0.1:48967\"]") &&
    digest_matches(response, "nonce", resident.nonce) && digest_matches(response, "helperDigest", resident.binding.helper_sha256) &&
    digest_matches(response, "journalDigest", resident.journal_sha256);
  if (!ok) { resident_close(); return 2; }
  /* Stage a leftover only in this fixture, while native ownership is held and the
     engine waits for ADMIT. Restore the shipping hook before sending any frame. */
  int (*before_set)(const wchar_t *) = g_before_set;
  Buf staged = {0}, *capture = g_capture;
  g_before_set = NULL; g_capture = &staged;
  ok = !set_connections(endpoint, TEST_BYPASS, 0);
  g_before_set = before_set; g_capture = capture; free(staged.data);
  ok = ok && registration(0) && verify_fixture(&saved, endpoint, 3);
  BYTE fields[KURO_ADMISSION_BYTES];
  memcpy(fields, resident.nonce, 32); memcpy(fields + 32, resident.journal_sha256, 32);
  memcpy(fields + 64, receipt, 32); memcpy(fields + 96, evidence, 32);
  ok = ok && send_bytes(admission, sizeof admission) && send_bytes(fields, sizeof fields) &&
    line(response, sizeof response) && strstr(response, "\"ready\":true,\"protocol\":2,\"recoveryVerified\":true") &&
    registration(0) && provenance_preserved() && verify_fixture(&saved, endpoint, 1) &&
    send_bytes(header, sizeof header) && send_bytes(command, sizeof command) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"set\"") && strstr(response, "\"ok\":true") &&
    registration(1) && verify_fixture(&saved, endpoint, 3);
  if (!ok) { resident_close(); return 2; }
  ok = send_bytes(close, sizeof close) && send_bytes(close, sizeof close) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"shutdown\"") && strstr(response, "\"ok\":true") &&
    registration(0) && provenance_preserved() && verify_fixture(&saved, endpoint, 1);
  InterlockedExchange(&verified, ok);
  return ok ? 0 : 2;
}

int wmain(int argc, wchar_t **argv) {
  if (argc == 2 && !wcscmp(argv[1], L"self-test")) {
    /* Pure commitments/field checks only: no root, ownership, registry or WinINet. */
    char hex[65], response[128];
    if (!fixture_proof()) return 2;
    resident_hex(receipt, hex); snprintf(response, sizeof response, "{\"receipt\":\"%s\"}", hex);
    if (!digest_matches(response, "receipt", receipt) || digest_matches(response, "receipt", evidence) ||
        digest_matches(response, "other", receipt)) return 2;
    puts("serve fixture: pure test-only commitments passed; no WinINet/registry calls"); return 0;
  }
  if (argc > 1 && !wcscmp(argv[1], L"-d")) { Sleep(INFINITE); return 99; }
  if (argc != 6 || wcscmp(argv[1], L"resident-cycle") || wcscmp(argv[5], L"serve") || wcscmp(argv[3], endpoint)) return 1;
  if (!fixture_paths() || !fixture_proof() || !load_backup(argv[2], &saved) || !preflight(&saved, NULL)) return 2;
  HKEY key; DWORD disposition;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, RUNONCE_KEY, 0, NULL, 0, KEY_QUERY_VALUE, NULL, &key, &disposition)) return 2;
  RegCloseKey(key);
  if (disposition != REG_CREATED_NEW_KEY) return 2; /* Never overwrite another run's evidence. */
  wchar_t exe[MAX_PATH], folder[MAX_PATH];
  DWORD length = GetModuleFileNameW(NULL, exe, MAX_PATH);
  if (!length || length >= MAX_PATH) return 2;
  wcscpy(folder, exe); wchar_t *slash = wcsrchr(folder, L'\\'); if (!slash) return 2; *slash = 0;
  HANDLE input, output, original = GetStdHandle(STD_OUTPUT_HANDLE);
  if (!CreatePipe(&input, &requests, NULL, 0) || !CreatePipe(&responses, &output, NULL, 0) ||
      !SetStdHandle(STD_INPUT_HANDLE, input) || !SetStdHandle(STD_OUTPUT_HANDLE, output)) return 2;
  HANDLE driver = CreateThread(NULL, 0, drive, NULL, 0, NULL); if (!driver) return 2;
  wchar_t *args[] = { exe, L"reserve", L"--core", exe, L"--data", folder, L"--initial-server", (wchar_t *)endpoint,
    L"--expected-server", (wchar_t *)endpoint, L"--log", argv[4] };
  int result = resident_main(12, args);
  if (result || WaitForSingleObject(driver, resident_left(resident.start + 2200)) != WAIT_OBJECT_0 || !verified) return 2;
  CloseHandle(driver);
  if (!provenance_preserved()) return 2;
  CloseHandle(resident.recovery);
  CloseHandle(resident.retained_exe); CloseHandle(resident.source_exe);
  if (!DeleteFileW(resident.fixed_journal) || !DeleteFileW(resident.retained_path)) return 2;
  for (int i = resident.directory_count; i; --i) CloseHandle(resident.directories[i - 1]);
  if (!RemoveDirectoryW(private_root) || RegDeleteKeyW(HKEY_CURRENT_USER, RUNONCE_KEY)) return 2;
  SetStdHandle(STD_OUTPUT_HANDLE, original); g_capture = NULL; g_log = NULL;
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1,\"privateRegistrationVerified\":true,"
    "\"protocol\":2,\"seedReplayVerified\":true,\"testAdmissionOnly\":true}", saved.count);
  emit(&report); free(report.data);
  return 0;
}
