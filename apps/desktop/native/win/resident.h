/* One user process/Core lifetime. No reconnect, restart, elevation or service installation. */
#include "core-process.h"
#include "resident-protocol.h"
#include "resident-owner.h"
#include "resident-journal.h"
#ifndef KURO_RESIDENT_ROOT
#define KURO_RESIDENT_ROOT kuro_resident_recovery_root
#endif

#ifndef KURO_RESIDENT_EXEC
#define KURO_RESIDENT_EXEC command_main
#endif
#ifndef KURO_RESIDENT_CLEAR
#define KURO_RESIDENT_CLEAR clear_connections
#endif
typedef struct {
  Buf clear_result, readback;
  ULONGLONG started, clear_completed, readback_completed;
  LONG verified;
} ResidentCleanup;

static struct {
  HANDLE close, request, cleared, finished, report, reported, job, core, core_ready, core_started, core_output_done, recovery;
  HANDLE replay_started, replay_finished, source_exe, retained_exe, prior_exe, directories[MAX_PATH / 2];
  HWND window;
  DWORD main_thread;
  LONG core_pid;
  LONG gate, closing, window_waiting;
  LONG triggers, first_trigger, query_events, end_events, session_flags, query_flags, end_flags;
  ULONGLONG start, cleanup_completed;
  ULONGLONG trigger_epoch, query_epoch, end_epoch, core_stop_requested, core_confirmed;
  ULONGLONG replay_start, replay_completed, core_start_completed;
  LONG clear_ok;
  LONG serving, replay_ok;
  int core_gone, timed_out, recovery_only, directory_count;
  const wchar_t *core_path, *data_dir, *recovery_path;
  wchar_t payload[KURO_REQUEST_BYTES / 2];
  DWORD bytes, kind;
  wchar_t fixed_journal[MAX_PATH], retained_path[MAX_PATH];
  KuroResidentJournalBinding binding, current_binding;
  KuroResidentJournalState prior;
  wchar_t servers[MAX_EXPECTED][300];
  int server_count, append_attempted;
  Buf response;
  ResidentCleanup replay_check, cleanup_check;
  SRWLOCK output_lock;
} resident;

static LONG resident_load(LONG *p) { return InterlockedCompareExchange(p, 0, 0); }
static DWORD resident_left(ULONGLONG deadline) {
  ULONGLONG now = GetTickCount64();
  return now < deadline ? (DWORD)(deadline - now) : 0;
}
static ULONGLONG resident_epoch(void) {
  FILETIME time; GetSystemTimeAsFileTime(&time);
  ULARGE_INTEGER ticks; ticks.LowPart = time.dwLowDateTime; ticks.HighPart = time.dwHighDateTime;
  return ticks.QuadPart / 10000 - 11644473600000ULL;
}
enum { RES_CLOSE_FAILURE = 1, RES_CLOSE_IPC = 2, RES_CLOSE_EOF = 4,
  RES_CLOSE_CORE = 8, RES_CLOSE_QUERY = 16, RES_CLOSE_END = 32, RES_CLOSE_RECOVER = 64 };
static void resident_close_reason(LONG reason) {
  InterlockedCompareExchange(&resident.first_trigger, reason ? reason : RES_CLOSE_FAILURE, 0);
  // A preempted first publisher must not leave another caller's closing report without an epoch.
  InterlockedCompareExchange64((LONG64 *)&resident.trigger_epoch, (LONG64)resident_epoch(), 0);
  InterlockedOr(&resident.triggers, reason);
  InterlockedOr(&resident.gate, 2);
  ULONGLONG origin = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.replay_start, 0, 0);
  if (resident_load(&resident.serving) || !origin) origin = GetTickCount64();
  InterlockedCompareExchange64((LONG64 *)&resident.start, (LONG64)origin, 0);
  InterlockedExchange(&resident.closing, 1);
  SetEvent(resident.close); /* Any caller may publish the first trigger; no single-owner handoff. */
}
static void resident_close(void) { resident_close_reason(RES_CLOSE_FAILURE); }
static void resident_write_bytes(const char *data, size_t size) {
  while (size) {
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), data, (DWORD)size, &written, NULL) || !written) {
      resident_close(); return;
    }
    data += written; size -= written;
  }
}
static void resident_write(const char *data, size_t size) {
  AcquireSRWLockExclusive(&resident.output_lock);
  resident_write_bytes(data, size);
  ReleaseSRWLockExclusive(&resident.output_lock);
}
static int resident_read(void *data, DWORD bytes) {
  unsigned char *p = data;
  while (bytes) {
    DWORD count = 0;
    if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), p, bytes, &count, NULL) || !count) return 0;
    p += count; bytes -= count;
  }
  return 1;
}
static DWORD WINAPI resident_reader(void *unused) {
  (void)unused;
  unsigned char header[8]; uint32_t kind, bytes;
  while (resident_read(header, sizeof header)) {
    if (!kuro_request_header(header, &kind, &bytes)) { resident_close(); break; }
    if (kind == 2) { resident_close_reason(RES_CLOSE_IPC); continue; }
    if (!resident_load(&resident.serving)) { resident_close(); break; }
    if (InterlockedCompareExchange(&resident.gate, 1, 0) != 0) break;
    if (!resident_read(resident.payload, bytes)) break;
    resident.bytes = bytes; resident.kind = kind;
    SetEvent(resident.request);
  }
  resident_close_reason(RES_CLOSE_EOF);
  return 0;
}
static int resident_remember(const wchar_t *server) {
  for (int i = 0; i < resident.server_count; ++i)
    if (!wcscmp(server, resident.servers[i])) return 1;
  if (resident.server_count == MAX_EXPECTED || !kuro_valid_server(server)) return 0;
  wcscpy(resident.servers[resident.server_count++], server);
  return 1;
}
static int resident_admit(const wchar_t *server) {
  // Persist before WinINet; retain the lock and journal across every failure path.
  if (!resident_load(&resident.serving)) return 0;
  resident.append_attempted = 1; /* A failed append may already have changed the journal. */
  return !kuro_resident_journal_append(resident.recovery, &resident.binding, server) &&
    resident_remember(server);
}

static void resident_hex(const BYTE bytes[32], char text[65]) {
  static const char digits[] = "0123456789abcdef";
  for (unsigned i = 0; i < 32; ++i) { text[2 * i] = digits[bytes[i] >> 4]; text[2 * i + 1] = digits[bytes[i] & 15]; }
  text[64] = 0;
}

/* Pin each ancestor without delete sharing; reject reparse points before descending.
   The same-user model is operational provenance, not hostile same-user protection. */
static DWORD resident_pin_root(wchar_t root[MAX_PATH]) {
  DWORD error = KURO_RESIDENT_ROOT(root, MAX_PATH);
  if (error) return error;
  size_t length = wcslen(root);
  if (length < 4 || length + 70 >= MAX_PATH || root[1] != L':' || root[2] != L'\\' ||
      !((root[0] >= L'A' && root[0] <= L'Z') || (root[0] >= L'a' && root[0] <= L'z'))) return ERROR_BAD_PATHNAME;
  wchar_t drive[] = { root[0], L':', L'\\', 0 };
  if (GetDriveTypeW(drive) != DRIVE_FIXED) return ERROR_BAD_PATHNAME;
  size_t component = 3;
  for (size_t i = 3; i <= length; ++i) {
    if (root[i] != L'\\' && root[i]) {
      if (root[i] < 0x20 || root[i] == L'/' || root[i] == L':' || root[i] == L'"') return ERROR_BAD_PATHNAME;
      continue;
    }
    if (i == component || (i - component == 1 && root[component] == L'.') ||
        (i - component == 2 && root[component] == L'.' && root[component + 1] == L'.')) return ERROR_BAD_PATHNAME;
    wchar_t saved = root[i]; root[i] = 0;
    if (!CreateDirectoryW(root, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) { error = GetLastError(); root[i] = saved; return error; }
    HANDLE directory = CreateFileW(root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
      NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    root[i] = saved;
    if (directory == INVALID_HANDLE_VALUE) return GetLastError();
    FILE_ATTRIBUTE_TAG_INFO info;
    if (!GetFileInformationByHandleEx(directory, FileAttributeTagInfo, &info, sizeof info)) {
      error = GetLastError(); CloseHandle(directory); return error;
    }
    if (!(info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
      CloseHandle(directory); return ERROR_ACCESS_DENIED;
    }
    resident.directories[resident.directory_count++] = directory;
    component = i + 1;
  }
  return ERROR_SUCCESS;
}
static HANDLE resident_read_exe(const wchar_t *path) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (file == INVALID_HANDLE_VALUE) return file;
  FILE_ATTRIBUTE_TAG_INFO info;
  if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &info, sizeof info) ||
      (info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
    CloseHandle(file); SetLastError(ERROR_ACCESS_DENIED); return INVALID_HANDLE_VALUE;
  }
  return file;
}
static DWORD resident_acquire(void) {
  BOOL abandoned;
  DWORD error = kuro_resident_owner_acquire(&abandoned);
  if (error) return error; /* Abandonment never skips provenance validation. */
  error = kuro_resident_current_sid(resident.binding.sid, KURO_RESIDENT_JOURNAL_SID_CHARS);
  if (error) return error;
  wchar_t root[MAX_PATH], exe[MAX_PATH];
  error = resident_pin_root(root);
  if (error) return error;
  DWORD length = GetModuleFileNameW(NULL, exe, MAX_PATH);
  if (!length || length >= MAX_PATH) return ERROR_FILENAME_EXCED_RANGE;
  resident.source_exe = resident_read_exe(exe);
  if (resident.source_exe == INVALID_HANDLE_VALUE) return GetLastError();
  error = kuro_resident_sha256_file(resident.source_exe, resident.binding.helper_sha256);
  if (error) return error;
  char hash[65]; resident_hex(resident.binding.helper_sha256, hash);
  _snwprintf(resident.retained_path, MAX_PATH, L"%ls\\%hs.exe", root, hash);
  if (resident.recovery_only && _wcsicmp(exe, resident.retained_path)) return ERROR_ACCESS_DENIED;
  if (_wcsicmp(exe, resident.retained_path) && !CopyFileW(exe, resident.retained_path, TRUE) && GetLastError() != ERROR_FILE_EXISTS)
    return GetLastError();
  resident.retained_exe = resident_read_exe(resident.retained_path);
  if (resident.retained_exe == INVALID_HANDLE_VALUE) return GetLastError();
  BYTE retained_hash[32];
  error = kuro_resident_sha256_file(resident.retained_exe, retained_hash);
  if (error) return error;
  if (memcmp(retained_hash, resident.binding.helper_sha256, 32)) return ERROR_INVALID_DATA;
  resident.current_binding = resident.binding;
  _snwprintf(resident.fixed_journal, MAX_PATH, L"%ls\\recovery.bin", root);
  resident.recovery_path = resident.fixed_journal;
  resident.recovery = CreateFileW(resident.recovery_path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
    resident.recovery_only ? OPEN_EXISTING : OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (resident.recovery == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    return resident.recovery_only && error == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : error;
  }
  FILE_ATTRIBUTE_TAG_INFO info;
  if (!GetFileInformationByHandleEx(resident.recovery, FileAttributeTagInfo, &info, sizeof info)) return GetLastError();
  if (info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
  error = kuro_resident_journal_read_owner(resident.recovery, &resident.binding, &resident.prior);
  if (error) return error;
  if (resident.prior.initialized && memcmp(resident.prior.binding.helper_sha256, resident.binding.helper_sha256, 32)) {
    wchar_t prior_path[MAX_PATH]; resident_hex(resident.prior.binding.helper_sha256, hash);
    _snwprintf(prior_path, MAX_PATH, L"%ls\\%hs.exe", root, hash);
    resident.prior_exe = resident_read_exe(prior_path);
    if (resident.prior_exe == INVALID_HANDLE_VALUE) return GetLastError();
    error = kuro_resident_sha256_file(resident.prior_exe, retained_hash);
    if (error) return error;
    if (memcmp(retained_hash, resident.prior.binding.helper_sha256, 32)) return ERROR_INVALID_DATA;
    resident.binding = resident.prior.binding;
  }
  return ERROR_SUCCESS;
}
static DWORD WINAPI resident_core_output(void *input) {
  char bytes[4096]; DWORD count;
  while (ReadFile(input, bytes, sizeof bytes, &count, NULL) && count) {
    DWORD offset = 0;
    while (offset < count) {
      DWORD written;
      if (!WriteFile(GetStdHandle(STD_ERROR_HANDLE), bytes + offset, count - offset, &written, NULL) || !written) {
        CloseHandle(input); SetEvent(resident.core_output_done); return 0;
      }
      offset += written;
    }
  }
  CloseHandle(input);
  SetEvent(resident.core_output_done);
  return 0;
}
static int resident_start_core(void) {
  if (resident_load(&resident.closing) || !resident_left(resident.replay_start + 1500)) return 0;
  SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
    &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (nul == INVALID_HANDLE_VALUE) return 0;
  HANDLE output = NULL, writer = NULL;
  if (!CreatePipe(&output, &writer, &sa, 0)) { CloseHandle(nul); return 0; }
  if (!SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0)) {
    CloseHandle(output); CloseHandle(writer); CloseHandle(nul); return 0;
  }
  // Diagnostics may block their own thread, never the operation worker or shutdown supervisor.
  ResetEvent(resident.core_output_done);
  HANDLE drain = CreateThread(NULL, 0, resident_core_output, output, 0, NULL);
  if (!drain) { SetEvent(resident.core_output_done); CloseHandle(output); CloseHandle(writer); CloseHandle(nul); return 0; }
  CloseHandle(drain);
  wchar_t command[2048];
  _snwprintf(command, 2048, L"\"%ls\" -d \"%ls\\.\" -f \"%ls\\runtime.yaml\"",
    resident.core_path, resident.data_dir, resident.data_dir);
  STARTUPINFOW stdio = {0};
  stdio.hStdInput = nul;
  stdio.hStdOutput = stdio.hStdError = writer;
  HANDLE inherited[] = { nul, writer };
  PROCESS_INFORMATION core = {0};
  BOOL ok = kuro_create_core(resident.job, resident.core_path, command, resident.data_dir,
    inherited, 2, &core, &stdio);
  CloseHandle(nul); CloseHandle(writer);
  if (!ok) return 0;
  InterlockedExchange(&resident.core_pid, (LONG)core.dwProcessId);
  InterlockedExchangePointer((PVOID volatile *)&resident.core, core.hProcess);
  SetEvent(resident.core_ready);
  DWORD resumed = (DWORD)-1;
  if (!resident_load(&resident.closing) && resident_left(resident.replay_start + 1500))
    resumed = ResumeThread(core.hThread);
  else TerminateProcess(core.hProcess, 0);
  CloseHandle(core.hThread);
  return resumed != (DWORD)-1;
}
static int resident_verify_clear(const wchar_t **expected, int count, ULONGLONG deadline, ResidentCleanup *check) {
  InterlockedExchange64((LONG64 *)&check->started, (LONG64)GetTickCount64());
  g_capture = &check->clear_result;
  int cleared = resident_left(deadline) && (!count || KURO_RESIDENT_CLEAR(expected, count, 0) == 0);
  InterlockedExchange64((LONG64 *)&check->clear_completed, (LONG64)GetTickCount64());
  // Re-enumerate and verify flags AFTER notification; API success alone is not proof.
  g_capture = &check->readback;
  int verified = resident_left(deadline) && get_connections(expected, count) == 0;
  g_capture = &resident.response;
  ULONGLONG completed = GetTickCount64();
  InterlockedExchange(&check->verified, cleared && verified && completed < deadline);
  InterlockedExchange64((LONG64 *)&check->readback_completed, (LONG64)completed);
  return resident_load(&check->verified);
}
static int resident_replay(void) {
  const wchar_t *expected[KURO_RESIDENT_JOURNAL_ENDPOINTS];
  for (unsigned i = 0; i < resident.prior.count; ++i) expected[i] = resident.prior.servers[i];
  ULONGLONG deadline = resident.replay_start + 1500;
  int ok = resident_verify_clear(expected, (int)resident.prior.count, deadline, &resident.replay_check);
  if (ok && resident.prior.count) ok = resident_left(deadline) &&
    !kuro_resident_journal_reset_after_clear(resident.recovery, &resident.binding);
  if (ok && memcmp(resident.binding.helper_sha256, resident.current_binding.helper_sha256, 32)) {
    ok = resident_left(deadline) &&
      !kuro_resident_journal_rebind(resident.recovery, &resident.binding, &resident.current_binding);
    if (ok) resident.binding = resident.current_binding;
  }
  ULONGLONG completed = GetTickCount64();
  InterlockedExchange(&resident.replay_ok, ok && completed < deadline);
  InterlockedExchange64((LONG64 *)&resident.replay_completed, (LONG64)completed);
  SetEvent(resident.replay_finished);
  return resident_load(&resident.replay_ok);
}
static DWORD WINAPI resident_worker(void *unused) {
  (void)unused;
  g_capture = &resident.response;
  InterlockedCompareExchange64((LONG64 *)&resident.replay_start, (LONG64)GetTickCount64(), 0);
  SetEvent(resident.replay_started);
  if (resident.recovery_only && !resident.prior.initialized) {
    InterlockedExchange(&resident.replay_ok, 1);
    goto cleanup; /* No provenance means no authority to clear. */
  }
  if (!resident.prior.initialized &&
      kuro_resident_journal_initialize(resident.recovery, &resident.binding)) {
    resident_close(); goto cleanup;
  }
  if (!resident_replay()) resident_close();
  if (resident.recovery_only || resident_load(&resident.closing)) goto cleanup;
  resident.response.len = 0;
  int started = !resident_load(&resident.closing) && resident_start_core();
  ULONGLONG core_completed = GetTickCount64();
  InterlockedExchange64((LONG64 *)&resident.core_start_completed, (LONG64)core_completed);
  if (!started || core_completed >= resident.replay_start + 1500) resident_close();
  SetEvent(resident.core_started);
  AcquireSRWLockExclusive(&resident.output_lock);
  if (!resident_load(&resident.closing)) {
    InterlockedExchange(&resident.serving, 1);
    const char *ready = "{\"ready\":true,\"protocol\":3,\"recoveryVerified\":true}\n";
    resident_write_bytes(ready, strlen(ready));
  }
  ReleaseSRWLockExclusive(&resident.output_lock);
  HANDLE events[] = {resident.close, resident.request};
  for (;;) {
    DWORD event = WaitForMultipleObjects(2, events, FALSE, INFINITE);
    if (event != WAIT_OBJECT_0 + 1 || (resident_load(&resident.gate) & 2)) {
      resident_close_reason(event == WAIT_FAILED ? RES_CLOSE_FAILURE : 0); break;
    }
    if (resident.kind != 1) { resident_close(); break; }
    wchar_t *args[KURO_REQUEST_ARGS + 1]; size_t count;
    args[0] = L"kuro-sysproxy";
    if (!kuro_request_args(resident.payload, resident.bytes, args + 1, &count)) { resident_close(); break; }
    if (wcscmp(args[1], L"get") && wcscmp(args[1], L"set") && wcscmp(args[1], L"clear")) { resident_close(); break; }
    int valid = 1;
    for (size_t i = 2; i < count + 1; i += 2) {
      if (i + 1 >= count + 1 || !wcscmp(args[i], L"--log")) { valid = 0; break; }
    }
    if (!valid) { resident_close(); break; }
    // Only this CAS admits an operation. Close wins over a queued/partially-read request.
    if (InterlockedCompareExchange(&resident.gate, 5, 1) != 1) { resident_close(); break; }
    int mutating = wcscmp(args[1], L"get") != 0;
    resident.response.len = 0;
    int code = KURO_RESIDENT_EXEC((int)count + 1, args);
    // Close admission before publishing a failed mutation; a fast client may immediately retry.
    if (code && mutating) resident_close();
    // The response owns its bytes; release the request slot before publishing it.
    InterlockedAnd(&resident.gate, ~5L);
    resident_write(resident.response.data, resident.response.len);
  }
cleanup:;
  if (!resident_load(&resident.serving)) {
    SetEvent(resident.core_started);
    ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.replay_completed, 0, 0);
    if (!completed) completed = GetTickCount64();
    InterlockedExchange(&resident.clear_ok, resident_load(&resident.replay_ok) &&
      !(resident_load(&resident.triggers) & RES_CLOSE_FAILURE));
    InterlockedExchange64((LONG64 *)&resident.cleanup_completed, (LONG64)completed);
    SetEvent(resident.cleared);
    return 0;
  }
  const wchar_t *expected[MAX_EXPECTED];
  for (int i = 0; i < resident.server_count; ++i) expected[i] = resident.servers[i];
  resident.response.len = 0;
  const ULONGLONG deadline = resident.start + 1500;
  int cleared = resident_verify_clear(expected, resident.server_count, deadline, &resident.cleanup_check);
  if (cleared && (resident.server_count || resident.append_attempted)) cleared = resident_left(deadline) &&
    !kuro_resident_journal_reset_after_clear(resident.recovery, &resident.binding);
  ULONGLONG completed = GetTickCount64();
  InterlockedExchange(&resident.clear_ok, cleared && completed < deadline);
  InterlockedExchange64((LONG64 *)&resident.cleanup_completed, (LONG64)completed);
  SetEvent(resident.cleared);
  return 0;
}
static DWORD WINAPI resident_report(void *unused) {
  (void)unused;
  WaitForSingleObject(resident.close, INFINITE);
  Buf closing = {0};
  putf(&closing, "{\"command\":\"closing\",\"protocol\":3,\"triggerMask\":%lu,\"queryEvents\":%lu,\"endEvents\":%lu,\"sessionFlags\":%lu,\"firstTrigger\":%lu,\"firstTriggerEpochMs\":%llu}\n",
    (unsigned long)resident_load(&resident.triggers), (unsigned long)resident_load(&resident.query_events),
    (unsigned long)resident_load(&resident.end_events), (unsigned long)resident_load(&resident.session_flags),
    (unsigned long)resident_load(&resident.first_trigger),
    (unsigned long long)InterlockedCompareExchange64((LONG64 *)&resident.trigger_epoch, 0, 0));
  resident_write(closing.data, closing.len);
  log_append(closing.data, closing.len);
  free(closing.data);
  WaitForSingleObject(resident.report, INFINITE);
  Buf report = {0};
  SYSTEMTIME time; GetSystemTime(&time);
  ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.cleanup_completed, 0, 0);
  char cleanup_duration[32] = "null";
  if (completed) snprintf(cleanup_duration, sizeof cleanup_duration, "%llu", completed - resident.start);
  int ok = resident_load(&resident.clear_ok) && !resident.timed_out && resident.core_gone;
  putf(&report, "{\"command\":\"shutdown\",\"ok\":%s,\"timedOut\":%s,\"coreGone\":%s,\"corePid\":%lu,\"durationMs\":%llu,\"cleanupDurationMs\":%s,"
    "\"pid\":%lu,\"timestamp\":\"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\","
    "\"triggerMask\":%lu,\"queryEvents\":%lu,\"endEvents\":%lu,\"sessionFlags\":%lu",
    ok ? "true" : "false",
    resident.timed_out ? "true" : "false", resident.core_gone ? "true" : "false",
    (unsigned long)resident_load(&resident.core_pid), GetTickCount64() - resident.start, cleanup_duration,
    GetCurrentProcessId(), time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond, time.wMilliseconds,
    (unsigned long)resident_load(&resident.triggers), (unsigned long)resident_load(&resident.query_events),
    (unsigned long)resident_load(&resident.end_events), (unsigned long)resident_load(&resident.session_flags));
  putf(&report, ",\"protocol\":3,\"recoveryNoop\":%s,\"firstTrigger\":%lu,\"firstTriggerEpochMs\":%llu,\"querySessionFlags\":%lu,\"endSessionFlags\":%lu,\"queryEpochMs\":%llu,\"endEpochMs\":%llu",
    resident.recovery_only && !resident.prior.initialized ? "true" : "false",
    (unsigned long)resident_load(&resident.first_trigger),
    (unsigned long long)InterlockedCompareExchange64((LONG64 *)&resident.trigger_epoch, 0, 0),
    (unsigned long)resident_load(&resident.query_flags), (unsigned long)resident_load(&resident.end_flags),
    (unsigned long long)InterlockedCompareExchange64((LONG64 *)&resident.query_epoch, 0, 0),
    (unsigned long long)InterlockedCompareExchange64((LONG64 *)&resident.end_epoch, 0, 0));
  ResidentCleanup *check = resident_load(&resident.serving) ? &resident.cleanup_check : &resident.replay_check;
  ULONGLONG clear_start = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&check->started, 0, 0);
  ULONGLONG clear_end = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&check->clear_completed, 0, 0);
  ULONGLONG readback_end = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&check->readback_completed, 0, 0);
  const char *names[] = {"clearStartedMs", "clearCompletedMs", "readbackCompletedMs", "coreStopRequestedMs", "coreConfirmedMs"};
  ULONGLONG ticks[] = {clear_start, clear_end, readback_end, resident.core_stop_requested, resident.core_confirmed};
  for (unsigned i = 0; i < sizeof ticks / sizeof *ticks; ++i) {
    putf(&report, ",\"%s\":", names[i]);
    if (ticks[i] && ticks[i] >= resident.start) putf(&report, "%llu", ticks[i] - resident.start);
    else puts_(&report, "null");
  }
  putf(&report, ",\"cleanupReadbackVerified\":%s,\"coreStopMethod\":\"TerminateJobObject-owned-job\",\"clearResult\":",
    readback_end && resident_load(&check->verified) ? "true" : "false");
  if (clear_end && check->clear_result.len) put(&report, check->clear_result.data, check->clear_result.len - 1);
  else puts_(&report, "null");
  puts_(&report, ",\"cleanupReadback\":");
  if (readback_end && check->readback.len) put(&report, check->readback.data, check->readback.len - 1);
  else puts_(&report, "null");
  puts_(&report, "}\n");
  // A failed report grants no cleanup success; publish it before the optional log can block.
  if (!ok) resident_write(report.data, report.len);
  log_append(report.data, report.len);
  if (ok) resident_write(report.data, report.len);
  free(report.data);
  SetEvent(resident.reported);
  return 0;
}
static DWORD WINAPI resident_supervisor(void *unused) {
  (void)unused;
  if (!resident.recovery_only) {
    HANDLE replay[] = {resident.close, resident.replay_started};
    if (WaitForMultipleObjects(2, replay, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
      DWORD waited = WaitForSingleObject(resident.replay_finished, resident_left(resident.replay_start + 1500));
      ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.replay_completed, 0, 0);
      if (waited != WAIT_OBJECT_0 || !resident_load(&resident.replay_ok) || !completed || completed >= resident.replay_start + 1500)
        resident_close();
      else if (!resident_load(&resident.closing)) {
        waited = WaitForSingleObject(resident.core_started, resident_left(resident.replay_start + 1500));
        completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.core_start_completed, 0, 0);
        if (!resident_load(&resident.closing) && (waited != WAIT_OBJECT_0 || !completed || completed >= resident.replay_start + 1500))
          resident_close();
      }
    }
  }
  HANDLE startup[] = {resident.close, resident.core_ready};
  if (WaitForMultipleObjects(2, startup, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
    HANDLE live[] = {resident.close, InterlockedCompareExchangePointer((PVOID volatile *)&resident.core, NULL, NULL)};
    DWORD event = WaitForMultipleObjects(2, live, FALSE, INFINITE);
    resident_close_reason(event == WAIT_OBJECT_0 + 1 ? RES_CLOSE_CORE : 0);
  }
  resident.timed_out = WaitForSingleObject(resident.cleared, resident_left(resident.start + 1500)) != WAIT_OBJECT_0;
  // A delayed supervisor can observe a signaled event whose work completed after the deadline.
  ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.cleanup_completed, 0, 0);
  if (!completed || completed >= resident.start + 1500) resident.timed_out = 1;
  // Windows child.kill(SIGTERM) also forces termination; stop only the owned Core/Job.
  // The Job exists before any Core creation, including a create/publication race.
  resident.core_stop_requested = GetTickCount64();
  TerminateJobObject(resident.job, 0);
  // A root exit alone does not prove descendants are gone, or that startup cannot still create Core.
  do {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
    resident.core_gone = WaitForSingleObject(resident.core_started, 0) == WAIT_OBJECT_0 &&
      QueryInformationJobObject(resident.job, JobObjectBasicAccountingInformation,
      &info, sizeof info, NULL) && !info.ActiveProcesses;
    if (resident.core_gone) { resident.core_confirmed = GetTickCount64(); break; }
    DWORD left = resident_left(resident.start + 2100);
    if (!left) break;
    // Catch a Core admitted after the first termination while startup was still in progress.
    TerminateJobObject(resident.job, 0);
    Sleep(left < 10 ? left : 10);
  } while (1);
  // A blocked diagnostic sink must leave the original 100 ms evidence slot before 2100 ms.
  WaitForSingleObject(resident.core_output_done, resident_left(resident.start + 2000));
  SetEvent(resident.report);
  // Give evidence a bounded chance before releasing the session callback, without renewing its deadline.
  DWORD evidence_budget = resident_left(resident.start + 2100);
  WaitForSingleObject(resident.reported, evidence_budget < 100 ? evidence_budget : 100);
  SetEvent(resident.finished);
  DWORD logged = WaitForSingleObject(resident.reported, resident_left(resident.start + 2200));
  if (resident.timed_out || !resident_load(&resident.clear_ok) || !resident.core_gone || logged != WAIT_OBJECT_0)
    TerminateProcess(GetCurrentProcess(), 42);
  PostThreadMessageW(resident.main_thread, WM_QUIT, 0, 0);
  // A stalled native window must not strand the process after cleanup has finished.
  WaitForSingleObject(GetCurrentProcess(), resident_left(resident.start + 2200));
  TerminateProcess(GetCurrentProcess(), 43);
  return 0;
}
static LRESULT CALLBACK resident_window(HWND window, UINT message, WPARAM w, LPARAM l) {
  if (message == WM_QUERYENDSESSION || message == WM_ENDSESSION) {
    InterlockedIncrement(message == WM_QUERYENDSESSION ? &resident.query_events : &resident.end_events);
    InterlockedOr(&resident.session_flags, (LONG)l);
    InterlockedOr(message == WM_QUERYENDSESSION ? &resident.query_flags : &resident.end_flags, (LONG)l);
    InterlockedCompareExchange64((LONG64 *)(message == WM_QUERYENDSESSION ? &resident.query_epoch : &resident.end_epoch),
      (LONG64)resident_epoch(), 0);
    if (message == WM_ENDSESSION && !w) return 0;
    resident_close_reason(message == WM_QUERYENDSESSION ? RES_CLOSE_QUERY : RES_CLOSE_END);
    if (!InterlockedCompareExchange(&resident.window_waiting, 1, 0)) {
      while (WaitForSingleObject(resident.close, 0) == WAIT_OBJECT_0 && resident_left(resident.start + 2100)) {
        DWORD waited = MsgWaitForMultipleObjectsEx(1, &resident.finished, resident_left(resident.start + 2100), QS_SENDMESSAGE, MWMO_INPUTAVAILABLE);
        if (waited != WAIT_OBJECT_0 + 1) break;
        MSG sent; PeekMessageW(&sent, NULL, 0, 0, PM_NOREMOVE);
      }
      InterlockedExchange(&resident.window_waiting, 0);
    }
    return message == WM_QUERYENDSESSION ? TRUE : 0;
  }
  return DefWindowProcW(window, message, w, l);
}
static int resident_main(int argc, wchar_t **argv) {
  resident.recovery_only = argc > 1 && !wcscmp(argv[1], L"recover-admitted");
  const wchar_t *log = NULL;
  for (int i = 2; i < argc; i += 2) {
    if (i + 1 >= argc) return usage(L"Missing resident option value");
    if (!wcscmp(argv[i], L"--core") && !resident.core_path) resident.core_path = argv[i + 1];
    else if (!wcscmp(argv[i], L"--data") && !resident.data_dir) resident.data_dir = argv[i + 1];
    else if (!wcscmp(argv[i], L"--log") && !log) log = argv[i + 1];
    else return usage(L"Invalid resident option");
  }
  if ((!resident.recovery_only && (!kuro_valid_log_path(resident.core_path) || !kuro_valid_log_path(resident.data_dir))) ||
      (resident.recovery_only && (resident.core_path || resident.data_dir)) || (log && !kuro_valid_log_path(log)))
    return usage(L"start requires --core/--data; recover-admitted permits only --log");
  g_log = log;
  if (resident_acquire()) return usage(L"Native ownership/provenance unavailable; no writes admitted");
  g_before_set = resident_admit;
  resident.main_thread = GetCurrentThreadId();
  resident.job = kuro_core_job();
  if (!resident.job) return 3;
#define RES_EVENT(field, manual) resident.field = CreateEventW(NULL, manual, FALSE, NULL); if (!resident.field) return 3
  RES_EVENT(close, TRUE); RES_EVENT(request, FALSE); RES_EVENT(cleared, TRUE);
  RES_EVENT(finished, TRUE); RES_EVENT(report, TRUE); RES_EVENT(reported, TRUE);
  RES_EVENT(core_ready, TRUE); RES_EVENT(core_started, TRUE);
  RES_EVENT(core_output_done, TRUE); SetEvent(resident.core_output_done);
  RES_EVENT(replay_started, TRUE); RES_EVENT(replay_finished, TRUE);
#undef RES_EVENT
  WNDCLASSW cls = {0}; cls.lpfnWndProc = resident_window; cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"ClashKuroResidentProxy";
  if (!RegisterClassW(&cls)) return 3;
  resident.window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
  if (!resident.window) return 3;
  if (resident.recovery_only) {
    // Recovery cannot create Core; a hung replay must not leave its startup barrier pending.
    SetEvent(resident.core_started);
    InterlockedCompareExchange64((LONG64 *)&resident.replay_start, (LONG64)GetTickCount64(), 0);
    resident_close_reason(RES_CLOSE_RECOVER);
  }
  LPTHREAD_START_ROUTINE starts[] = { resident_supervisor, resident_report, resident_worker, resident_reader };
  unsigned threads = resident.recovery_only ? 3 : sizeof starts / sizeof *starts;
  for (unsigned i = 0; i < threads; ++i) {
    HANDLE thread = CreateThread(NULL, 0, starts[i], NULL, 0, NULL);
    if (!thread) { resident_close(); TerminateProcess(GetCurrentProcess(), 3); return 3; }
    CloseHandle(thread);
  }
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
  return 0;
}
