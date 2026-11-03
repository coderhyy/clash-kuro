/* Actual protocol3/WinINet engine, fake Core, private ownership/root. CI only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <wchar.h>
static DWORD fixture_root(wchar_t *out, size_t cap);
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name);
#define KURO_RESIDENT_OWNER_TEST
#define KURO_RESIDENT_ROOT fixture_root
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"
#ifndef KURO_FIXTURE_MODE
#define KURO_FIXTURE_MODE L"serve"
#define KURO_FIXTURE_RECOVERY_ONLY 0
#endif

static HANDLE requests, responses;
static Backup saved;
static LONG verified;
static const wchar_t endpoint[] = L"127.0.0.1:48967";
static wchar_t private_root[MAX_PATH], private_mutex[128];

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
static int digest_matches(const char *response, const char *field, const BYTE digest[32]) {
  char hex[65], expected[128]; resident_hex(digest, hex);
  int count = snprintf(expected, sizeof expected, "\"%s\":\"%s\"", field, hex);
  return count > 0 && count < (int)sizeof expected && strstr(response, expected) != NULL;
}
static int provenance_preserved(void) {
  KuroResidentJournalState state;
  return !kuro_resident_journal_read(resident.recovery, &resident.binding, &state) && state.initialized && !state.count &&
    !memcmp(&state.binding, &resident.binding, sizeof resident.binding);
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
static DWORD WINAPI drive(void *unused) {
  (void)unused;
  char response[4096];
  if (KURO_FIXTURE_RECOVERY_ONLY) {
    int ok = line(response, sizeof response) && strstr(response, "\"command\":\"closing\"") &&
      line(response, sizeof response) && strstr(response, "\"command\":\"shutdown\"") &&
      strstr(response, "\"ok\":true") && strstr(response, "\"corePid\":0") &&
      strstr(response, "\"coreGone\":true") && strstr(response, "\"cleanupReadbackVerified\":true");
    InterlockedExchange(&verified, ok);
    return ok ? 0 : 2;
  }
  const wchar_t command[] = L"set\0--host\0" L"127.0.0.1\0--port\0" L"48967\0--bypass\0" TEST_BYPASS;
  const uint32_t header[] = { 1, sizeof command }, close[] = { 2, 0 };
  int ok = line(response, sizeof response) && strstr(response, "\"ready\":true,\"protocol\":3,\"recoveryVerified\":true") &&
    provenance_preserved() && verify_fixture(&saved, endpoint, 1);
  if (ok) ok =
    send_bytes(header, sizeof header) && send_bytes(command, sizeof command) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"set\"") && strstr(response, "\"ok\":true") &&
    verify_fixture(&saved, endpoint, 3);
  if (!ok) { resident_close(); return 2; }
  ok = send_bytes(close, sizeof close) && send_bytes(close, sizeof close) &&
    line(response, sizeof response) && strstr(response, "\"command\":\"closing\"") &&
    line(response, sizeof response) && strstr(response, "\"command\":\"shutdown\"") && strstr(response, "\"ok\":true") &&
    provenance_preserved() && verify_fixture(&saved, endpoint, 1);
  InterlockedExchange(&verified, ok);
  return ok ? 0 : 2;
}

static int recovery_command(wchar_t *out, size_t capacity, const wchar_t *exe, const wchar_t *log) {
  if (!kuro_valid_log_path(exe) || !kuro_valid_log_path(log)) return 0;
  int length = _snwprintf(out, capacity, L"\"%ls\" recover-admitted --log \"%ls\"", exe, log);
  return length > 0 && (size_t)length < capacity;
}
static int run_recovery(const wchar_t *exe, const wchar_t *log, const KuroResidentJournalBinding *binding) {
  char hex[65]; resident_hex(binding->helper_sha256, hex);
  _snwprintf(resident.retained_path, MAX_PATH, L"%ls\\%hs.exe", private_root, hex);
  if (!CopyFileW(exe, resident.retained_path, TRUE)) return 0;
  wchar_t command[MAX_PATH * 3];
  if (!recovery_command(command, MAX_PATH * 3, resident.retained_path, log)) return 0;
  /* Real retained-path recovery in an exact-child Job, not a spoofed module path.
     The fixture-only namespace crosses exec; native still validates/pins all files. */
  HANDLE job = kuro_core_job(), writer = NULL, nul = INVALID_HANDLE_VALUE;
  PROCESS_INFORMATION process = {0};
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  int ok = 0;
  if (!job || !CreatePipe(&responses, &writer, &sa, 0) ||
      !SetHandleInformation(responses, HANDLE_FLAG_INHERIT, 0)) goto done;
  nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
    &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (nul == INVALID_HANDLE_VALUE || !SetEnvironmentVariableW(L"KURO_WININET_FIXTURE_ROOT", private_root) ||
      !SetEnvironmentVariableW(L"KURO_WININET_FIXTURE_MUTEX", private_mutex)) goto done;
  STARTUPINFOW stdio = {0};
  stdio.hStdInput = stdio.hStdError = nul; stdio.hStdOutput = writer;
  HANDLE inherited[] = {nul, writer};
  BOOL created = kuro_create_core(job, resident.retained_path, command, NULL, inherited, 2, &process, &stdio);
  SetEnvironmentVariableW(L"KURO_WININET_FIXTURE_ROOT", NULL);
  SetEnvironmentVariableW(L"KURO_WININET_FIXTURE_MUTEX", NULL);
  if (!created) goto done;
  CloseHandle(writer); writer = NULL;
  ULONGLONG deadline = GetTickCount64() + 2500;
  if (ResumeThread(process.hThread) == (DWORD)-1) goto done;
  CloseHandle(process.hThread); process.hThread = NULL;
  if (drive(NULL) || WaitForSingleObject(process.hProcess, resident_left(deadline)) != WAIT_OBJECT_0) goto done;
  DWORD code; JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
  if (!GetExitCodeProcess(process.hProcess, &code) || code) goto done;
  do {
    if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof info, NULL)) goto done;
    if (!info.ActiveProcesses) { ok = 1; break; }
    Sleep(1);
  } while (resident_left(deadline));
done:
  if (!ok && job) {
    TerminateJobObject(job, 42);
    if (process.hProcess) WaitForSingleObject(process.hProcess, 2000);
  }
  if (process.hThread) CloseHandle(process.hThread);
  if (process.hProcess) CloseHandle(process.hProcess);
  if (writer) CloseHandle(writer);
  if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
  if (responses) CloseHandle(responses);
  if (job) CloseHandle(job);
  return ok;
}

int wmain(int argc, wchar_t **argv) {
  if (argc == 2 && !wcscmp(argv[1], L"self-test")) {
    /* Pure hash/command/framing checks only: no root, ownership, registry or WinINet. */
    BYTE digest[32], other[32] = {0};
    char hex[65], response[128]; wchar_t command[MAX_PATH * 3];
    if (kuro_resident_sha256("fixture", 7, digest)) return 2;
    resident_hex(digest, hex); snprintf(response, sizeof response, "{\"helper\":\"%s\"}", hex);
    if (!digest_matches(response, "helper", digest) || digest_matches(response, "helper", other) ||
        digest_matches(response, "other", digest) ||
        !recovery_command(command, MAX_PATH * 3, L"C:\\fixture.exe", L"C:\\recovery.jsonl") ||
        wcscmp(command, L"\"C:\\fixture.exe\" recover-admitted --log \"C:\\recovery.jsonl\"") ||
        recovery_command(command, 8, L"C:\\fixture.exe", L"C:\\recovery.jsonl") ||
        recovery_command(command, MAX_PATH * 3, L"relative.exe", L"C:\\recovery.jsonl")) return 2;
    if (KURO_FIXTURE_RECOVERY_ONLY) {
      const char *frames[] = {
        "{\"command\":\"closing\"}\n{\"command\":\"shutdown\",\"ok\":true,\"corePid\":0,\"coreGone\":true,\"cleanupReadbackVerified\":true}\n",
        "{\"ready\":true,\"protocol\":3}\n",
        "{\"command\":\"closing\"}\n{\"command\":\"shutdown\",\"ok\":true,\"corePid\":7,\"coreGone\":true,\"cleanupReadbackVerified\":true}\n"
      };
      for (unsigned i = 0; i < sizeof frames / sizeof *frames; ++i) {
        HANDLE writer; DWORD written;
        if (!CreatePipe(&responses, &writer, NULL, 0) ||
            !WriteFile(writer, frames[i], (DWORD)strlen(frames[i]), &written, NULL) || written != strlen(frames[i])) return 2;
        CloseHandle(writer);
        int result = drive(NULL);
        CloseHandle(responses); responses = NULL;
        if (result != (i ? 2 : 0) || verified != (i ? 0 : 1)) return 2;
      }
    }
    puts("serve fixture: pure hash/command/recovery framing checks passed; no WinINet/registry calls"); return 0;
  }
  if (KURO_FIXTURE_RECOVERY_ONLY && argc == 4 && !wcscmp(argv[1], L"recover-admitted") && !wcscmp(argv[2], L"--log")) {
    DWORD root = GetEnvironmentVariableW(L"KURO_WININET_FIXTURE_ROOT", private_root, MAX_PATH);
    DWORD mutex = GetEnvironmentVariableW(L"KURO_WININET_FIXTURE_MUTEX", private_mutex, 128);
    const wchar_t prefix[] = L"Local\\ClashKuro.WininetServeFixture.{";
    if (!root || root >= MAX_PATH || !wcsstr(private_root, L"\\kuro-wininet-serve-{") ||
        !mutex || mutex >= 128 || wcsncmp(private_mutex, prefix, sizeof prefix / sizeof *prefix - 1)) return 1;
    return resident_main(argc, argv);
  }
  if (argc > 1 && !wcscmp(argv[1], L"-d")) { Sleep(INFINITE); return 99; }
  if (argc != 6 || wcscmp(argv[1], L"resident-cycle") || wcscmp(argv[5], KURO_FIXTURE_MODE) || wcscmp(argv[3], endpoint)) return 1;
  if (!fixture_paths() || !load_backup(argv[2], &saved) || !preflight(&saved, NULL)) return 2;
  wchar_t exe[MAX_PATH], folder[MAX_PATH];
  DWORD length = GetModuleFileNameW(NULL, exe, MAX_PATH);
  if (!length || length >= MAX_PATH) return 2;
  wcscpy(folder, exe); wchar_t *slash = wcsrchr(folder, L'\\'); if (!slash) return 2; *slash = 0;
  /* Private fixture only: persist a native-bound leftover before starting the engine. */
  if (!CreateDirectoryW(private_root, NULL)) return 2;
  KuroResidentJournalBinding binding = {0};
  HANDLE source = resident_read_exe(exe);
  if (source == INVALID_HANDLE_VALUE || kuro_resident_current_sid(binding.sid, KURO_RESIDENT_JOURNAL_SID_CHARS) ||
      kuro_resident_sha256_file(source, binding.helper_sha256)) return 2;
  CloseHandle(source);
  wchar_t journal[MAX_PATH]; _snwprintf(journal, MAX_PATH, L"%ls\\recovery.bin", private_root);
  HANDLE file = CreateFileW(journal, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE || kuro_resident_journal_initialize(file, &binding) ||
      kuro_resident_journal_append(file, &binding, endpoint)) return 2;
  CloseHandle(file);
  Buf staged = {0}; g_capture = &staged;
  int staged_ok = !set_connections(endpoint, TEST_BYPASS, 0);
  g_capture = NULL; free(staged.data);
  if (!staged_ok || !verify_fixture(&saved, endpoint, 3)) return 2;
  HANDLE input, output, original = GetStdHandle(STD_OUTPUT_HANDLE);
  if (KURO_FIXTURE_RECOVERY_ONLY) {
    if (!run_recovery(exe, argv[4], &binding) || !verified || !verify_fixture(&saved, endpoint, 1)) return 2;
    resident.binding = binding; wcscpy(resident.fixed_journal, journal);
    resident.recovery = CreateFileW(journal, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (resident.recovery == INVALID_HANDLE_VALUE) return 2;
    goto recovered;
  }
  if (!CreatePipe(&input, &requests, NULL, 0) || !CreatePipe(&responses, &output, NULL, 0) ||
      !SetStdHandle(STD_INPUT_HANDLE, input) || !SetStdHandle(STD_OUTPUT_HANDLE, output)) return 2;
  HANDLE driver = CreateThread(NULL, 0, drive, NULL, 0, NULL); if (!driver) return 2;
  wchar_t *args[] = { exe, L"start", L"--core", exe, L"--data", folder, L"--log", argv[4] };
  int result = resident_main(8, args);
  if (result || WaitForSingleObject(driver, resident_left(resident.start + 2200)) != WAIT_OBJECT_0 || !verified) return 2;
  CloseHandle(driver);
recovered:
  if (!provenance_preserved()) return 2;
  CloseHandle(resident.recovery);
  if (resident.retained_exe) CloseHandle(resident.retained_exe);
  if (resident.source_exe) CloseHandle(resident.source_exe);
  if (!DeleteFileW(resident.fixed_journal) || !DeleteFileW(resident.retained_path)) return 2;
  for (int i = resident.directory_count; i; --i) CloseHandle(resident.directories[i - 1]);
  if (!RemoveDirectoryW(private_root)) return 2;
  SetStdHandle(STD_OUTPUT_HANDLE, original); g_capture = NULL; g_log = NULL;
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1,\"runOnceManaged\":false,"
    "\"protocol\":3,\"journalReplayVerified\":true,\"testOwnerOnly\":true}", saved.count);
  emit(&report); free(report.data);
  return 0;
}
