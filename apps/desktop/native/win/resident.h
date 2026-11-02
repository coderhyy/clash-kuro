/* One user process/Core lifetime. No reconnect, restart, elevation or service installation. */
#include "core-process.h"
#include "resident-protocol.h"
#include "resident-owner.h"
#include "resident-journal.h"
#include "recovery-journal.h"
#include "recovery-registration.h"
#ifndef KURO_RECOVERY_REGISTER
#define KURO_RECOVERY_REGISTER kuro_recovery_register
#define KURO_RECOVERY_UNREGISTER kuro_recovery_unregister
#endif
#ifndef KURO_RESIDENT_ROOT
#define KURO_RESIDENT_ROOT kuro_resident_recovery_root
#endif
#ifndef KURO_RECOVERY_REGISTER_ADMITTED
#define KURO_RECOVERY_REGISTER_ADMITTED kuro_recovery_register_admitted
#endif

#ifndef KURO_RESIDENT_EXEC
#define KURO_RESIDENT_EXEC command_main
#endif
#ifndef KURO_RESIDENT_CLEAR
#define KURO_RESIDENT_CLEAR clear_connections
#endif
#ifndef KURO_RESIDENT_WARM
#define KURO_RESIDENT_WARM cmd_get
#endif

static struct {
  HANDLE close, request, cleared, finished, report, reported, job, core, core_ready, core_started, core_output_done, recovery;
  HANDLE replay_started, replay_finished, source_exe, retained_exe, directories[MAX_PATH / 2];
  HWND window;
  DWORD main_thread;
  LONG core_pid;
  LONG gate, closing, window_waiting;
  LONG triggers, query_events, end_events, session_flags;
  ULONGLONG start, cleanup_completed;
  ULONGLONG replay_start, replay_completed, core_start_completed;
  LONG clear_ok;
  LONG admitted, admission_frame, serving, replay_ok;
  int core_gone, timed_out, recovery_only, protocol2, directory_count;
  const wchar_t *core_path, *data_dir, *recovery_path;
  wchar_t payload[KURO_REQUEST_BYTES / 2];
  DWORD bytes, kind;
  wchar_t fixed_journal[MAX_PATH], retained_path[MAX_PATH];
  KuroResidentJournalBinding binding;
  KuroResidentJournalState prior;
  BYTE nonce[32], journal_sha256[32];
  wchar_t initial_servers[KURO_RESIDENT_JOURNAL_ENDPOINTS][300];
  unsigned initial_count;
  wchar_t servers[MAX_EXPECTED][300];
  int server_count;
  Buf response;
} resident;

static LONG resident_load(LONG *p) { return InterlockedCompareExchange(p, 0, 0); }
static DWORD resident_left(ULONGLONG deadline) {
  ULONGLONG now = GetTickCount64();
  return now < deadline ? (DWORD)(deadline - now) : 0;
}
enum { RES_CLOSE_FAILURE = 1, RES_CLOSE_IPC = 2, RES_CLOSE_EOF = 4,
  RES_CLOSE_CORE = 8, RES_CLOSE_QUERY = 16, RES_CLOSE_END = 32, RES_CLOSE_RECOVER = 64 };
static void resident_close_reason(LONG reason) {
  InterlockedOr(&resident.triggers, reason);
  InterlockedOr(&resident.gate, 2);
  ULONGLONG origin = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.replay_start, 0, 0);
  if (!resident.protocol2 || resident_load(&resident.serving) || !origin) origin = GetTickCount64();
  InterlockedCompareExchange64((LONG64 *)&resident.start, (LONG64)origin, 0);
  InterlockedExchange(&resident.closing, 1);
  SetEvent(resident.close); /* Any caller may publish the first trigger; no single-owner handoff. */
}
static void resident_close(void) { resident_close_reason(RES_CLOSE_FAILURE); }
static void resident_write(const char *data, size_t size) {
  while (size) {
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), data, (DWORD)size, &written, NULL) || !written) {
      resident_close(); return;
    }
    data += written; size -= written;
  }
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
    if (kind == 3) {
      if (!resident.protocol2 || InterlockedCompareExchange(&resident.admission_frame, 1, 0)) { resident_close(); break; }
    } else if (resident.protocol2 && !resident_load(&resident.serving)) { resident_close(); break; }
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
static int resident_initial_server(const wchar_t *server) {
  if (resident.initial_count == KURO_RESIDENT_JOURNAL_ENDPOINTS || !kuro_valid_server(server)) return 0;
  for (unsigned i = 0; i < resident.initial_count; ++i)
    if (!wcscmp(server, resident.initial_servers[i])) return 0;
  wcscpy(resident.initial_servers[resident.initial_count++], server);
  return 1;
}
static int resident_admit(const wchar_t *server) {
  // Persist the union before a new endpoint can reach WinINet; the lock survives all timeout paths.
  if (resident.protocol2) return resident_load(&resident.admitted) && resident_load(&resident.serving) &&
    !kuro_resident_journal_append(resident.recovery, &resident.binding, server) &&
    !KURO_RECOVERY_REGISTER_ADMITTED(resident.retained_path) && resident_remember(server);
  return !kuro_recovery_admit(resident.recovery, server) &&
    !KURO_RECOVERY_REGISTER(resident.recovery_path) && resident_remember(server);
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
static DWORD resident_reserve(void) {
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
  _snwprintf(resident.fixed_journal, MAX_PATH, L"%ls\\recovery.bin", root);
  resident.recovery_path = resident.fixed_journal;
  resident.recovery = CreateFileW(resident.recovery_path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
    resident.recovery_only ? OPEN_EXISTING : OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (resident.recovery == INVALID_HANDLE_VALUE) return GetLastError();
  FILE_ATTRIBUTE_TAG_INFO info;
  if (!GetFileInformationByHandleEx(resident.recovery, FileAttributeTagInfo, &info, sizeof info)) return GetLastError();
  if (info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
  error = kuro_resident_journal_read(resident.recovery, &resident.binding, &resident.prior);
  if (error) return error;
  if (resident.recovery_only && !resident.prior.initialized) return ERROR_INVALID_DATA;
  if (resident.prior.initialized) resident.initial_count = 0; /* Candidates can never reseed existing provenance. */
  error = kuro_resident_sha256_file(resident.recovery, resident.journal_sha256);
  if (error) return error;
  HCRYPTPROV provider;
  if (!CryptAcquireContextW(&provider, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) return GetLastError();
  BOOL ok = CryptGenRandom(provider, sizeof resident.nonce, resident.nonce);
  error = ok ? ERROR_SUCCESS : GetLastError(); CryptReleaseContext(provider, 0);
  return error;
}
static void resident_reservation(void) {
  Buf result = {0}; char nonce[65], helper[65], journal[65], receipt[65];
  resident_hex(resident.nonce, nonce); resident_hex(resident.binding.helper_sha256, helper);
  resident_hex(resident.journal_sha256, journal);
  putf(&result, "{\"reserved\":true,\"protocol\":2,\"pid\":%lu,\"nonce\":\"%s\",\"userSid\":", GetCurrentProcessId(), nonce);
  put_json_string(&result, resident.binding.sid);
  putf(&result, ",\"helperDigest\":\"%s\",\"journalDigest\":\"%s\",\"admissionReceiptDigest\":", helper, journal);
  if (resident.prior.initialized) {
    resident_hex(resident.prior.provenance.receipt_sha256, receipt); putf(&result, "\"%s\"", receipt);
  } else puts_(&result, "null");
  puts_(&result, ",\"priorEndpoints\":[");
  for (unsigned i = 0; i < resident.prior.count; ++i) {
    if (i) puts_(&result, ",");
    put_json_string(&result, resident.prior.servers[i]);
  }
  puts_(&result, "],\"initialEndpoints\":[");
  for (unsigned i = 0; i < resident.initial_count; ++i) {
    if (i) puts_(&result, ",");
    put_json_string(&result, resident.initial_servers[i]);
  }
  puts_(&result, "]}\n"); resident_write(result.data, result.len); free(result.data);
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
  if (resident_load(&resident.closing) || (resident.protocol2 && !resident_left(resident.replay_start + 1500))) return 0;
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
  if (!resident_load(&resident.closing) && (!resident.protocol2 || resident_left(resident.replay_start + 1500)))
    resumed = ResumeThread(core.hThread);
  else TerminateProcess(core.hProcess, 0);
  CloseHandle(core.hThread);
  return resumed != (DWORD)-1;
}
/* Publish a seeded fresh image header last. A crash cannot turn a valid prefix
   into initialized provenance that silently forgets the remaining seed union. */
static DWORD resident_initialize(const KuroResidentJournalProvenance *proof) {
  if (!resident.initial_count) return kuro_resident_journal_admit(resident.recovery, proof);
  KuroResidentJournalHeader header = {0};
  header.magic = KURO_RESIDENT_JOURNAL_MAGIC; header.version = 2; header.bytes = sizeof header;
  header.provenance = *proof;
  header.checksum = kuro_resident_journal_checksum(&header, offsetof(KuroResidentJournalHeader, checksum));
  KuroResidentJournalRecord records[KURO_RESIDENT_JOURNAL_ENDPOINTS] = {0};
  for (unsigned i = 0; i < resident.initial_count; ++i) {
    records[i].magic = 0x3152504bu; wcscpy(records[i].server, resident.initial_servers[i]);
    records[i].checksum = kuro_resident_journal_checksum(records[i].server, sizeof records[i].server);
  }
  DWORD bytes = resident.initial_count * sizeof records[0], written;
  DWORD invalid_magic = 0;
  LARGE_INTEGER position = {0};
  if (!resident_left(resident.replay_start + 1500)) return ERROR_TIMEOUT;
  if (!SetFilePointerEx(resident.recovery, position, NULL, FILE_BEGIN) ||
      !WriteFile(resident.recovery, &invalid_magic, sizeof invalid_magic, &written, NULL)) return GetLastError();
  if (written != sizeof invalid_magic) return ERROR_WRITE_FAULT;
  if (!FlushFileBuffers(resident.recovery)) return GetLastError();
  position.QuadPart = sizeof header + bytes;
  if (!resident_left(resident.replay_start + 1500)) return ERROR_TIMEOUT;
  if (!SetFilePointerEx(resident.recovery, position, NULL, FILE_BEGIN) ||
      !SetEndOfFile(resident.recovery) || !FlushFileBuffers(resident.recovery)) return GetLastError();
  position.QuadPart = sizeof header;
  if (!resident_left(resident.replay_start + 1500)) return ERROR_TIMEOUT;
  if (!SetFilePointerEx(resident.recovery, position, NULL, FILE_BEGIN) ||
      !WriteFile(resident.recovery, records, bytes, &written, NULL)) return GetLastError();
  if (written != bytes) return ERROR_WRITE_FAULT;
  if (!FlushFileBuffers(resident.recovery)) return GetLastError();
  position.QuadPart = 0;
  if (!resident_left(resident.replay_start + 1500)) return ERROR_TIMEOUT;
  if (!SetFilePointerEx(resident.recovery, position, NULL, FILE_BEGIN) ||
      !WriteFile(resident.recovery, &header, sizeof header, &written, NULL)) return GetLastError();
  if (written != sizeof header) return ERROR_WRITE_FAULT;
  if (!FlushFileBuffers(resident.recovery)) return GetLastError();
  return kuro_resident_journal_read(resident.recovery, &resident.binding, &resident.prior);
}
static int resident_accept_admission(void) {
  const BYTE *fields = (const BYTE *)resident.payload;
  if (resident.kind != 3 || resident.bytes != KURO_ADMISSION_BYTES ||
      memcmp(fields, resident.nonce, 32) || memcmp(fields + 32, resident.journal_sha256, 32) ||
      !kuro_resident_digest_present(fields + 64) || !kuro_resident_digest_present(fields + 96) ||
      (resident.prior.initialized && memcmp(fields + 64, resident.prior.provenance.receipt_sha256, 32))) return 0;
  BYTE current[32];
  if (kuro_resident_sha256_file(resident.recovery, current) || memcmp(current, resident.journal_sha256, 32)) return 0;
  if (InterlockedCompareExchange(&resident.gate, 5, 1) != 1 || resident_load(&resident.closing)) return 0;
  InterlockedCompareExchange64((LONG64 *)&resident.replay_start, (LONG64)GetTickCount64(), 0);
  SetEvent(resident.replay_started);
  if (!resident.prior.initialized) {
    KuroResidentJournalProvenance proof = {0}; proof.binding = resident.binding;
    memcpy(proof.receipt_sha256, fields + 64, 32); memcpy(proof.evidence_sha256, fields + 96, 32);
    if (resident_initialize(&proof)) return 0;
  }
  /* Existing origin evidence remains immutable; this admission's fresh evidence
     is checked by trusted main, not substituted into the journal header. */
  InterlockedExchange(&resident.admitted, 1);
  InterlockedAnd(&resident.gate, ~5L);
  return 1;
}
static int resident_replay(void) {
  const wchar_t *expected[KURO_RESIDENT_JOURNAL_ENDPOINTS];
  for (unsigned i = 0; i < resident.prior.count; ++i) expected[i] = resident.prior.servers[i];
  ULONGLONG deadline = resident.replay_start + 1500;
  int ok = resident_left(deadline) && (!resident.prior.count ||
    KURO_RESIDENT_CLEAR(expected, (int)resident.prior.count, 0) == 0);
  /* A failed/stalled unregister retains the frozen endpoints for the next owner. */
  if (ok && resident.prior.initialized) ok = resident_left(deadline) && !KURO_RECOVERY_UNREGISTER();
  if (ok && resident.prior.count) ok = resident_left(deadline) &&
    !kuro_resident_journal_reset_after_clear(resident.recovery, &resident.binding);
  if (ok && !resident.recovery_only && !resident_load(&resident.closing))
    ok = resident_left(deadline) && !KURO_RESIDENT_WARM();
  ULONGLONG completed = GetTickCount64();
  InterlockedExchange(&resident.replay_ok, ok && completed < deadline);
  InterlockedExchange64((LONG64 *)&resident.replay_completed, (LONG64)completed);
  SetEvent(resident.replay_finished);
  return resident_load(&resident.replay_ok);
}
static DWORD WINAPI resident_worker(void *unused) {
  (void)unused;
  g_capture = &resident.response;
  if (resident.protocol2) {
    if (!resident.recovery_only) {
      resident_reservation();
      HANDLE admission_events[] = {resident.close, resident.request};
      DWORD event = WaitForMultipleObjects(2, admission_events, FALSE, INFINITE);
      if (event != WAIT_OBJECT_0 + 1 || (resident_load(&resident.gate) & 2)) goto cleanup;
      if (!resident_accept_admission()) { resident_close(); goto cleanup; }
    }
    if (!resident_replay()) resident_close();
    if (resident.recovery_only || resident_load(&resident.closing)) goto cleanup;
  }
  if (resident.recovery_only) {
    SetEvent(resident.core_started);
    goto cleanup;
  }
  if (!resident.protocol2 && KURO_RESIDENT_WARM()) resident_close();
  resident.response.len = 0;
  int started = !resident_load(&resident.closing) && resident_start_core();
  ULONGLONG core_completed = GetTickCount64();
  InterlockedExchange64((LONG64 *)&resident.core_start_completed, (LONG64)core_completed);
  if (!started || (resident.protocol2 && core_completed >= resident.replay_start + 1500)) resident_close();
  SetEvent(resident.core_started);
  if (!resident_load(&resident.closing)) {
    InterlockedExchange(&resident.serving, 1);
    const char *ready = resident.protocol2 ? "{\"ready\":true,\"protocol\":2,\"recoveryVerified\":true}\n" :
      "{\"ready\":true,\"protocol\":1}\n";
    resident_write(ready, strlen(ready));
  }
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
  if (resident.protocol2 && !resident_load(&resident.serving)) {
    SetEvent(resident.core_started);
    ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.replay_completed, 0, 0);
    if (!resident_load(&resident.admitted)) {
      completed = GetTickCount64();
      /* No admission means no replay: pending authority is still unverified. */
      InterlockedExchange(&resident.clear_ok, !resident.prior.count && !resident.initial_count &&
        !(resident_load(&resident.triggers) & RES_CLOSE_FAILURE));
    } else InterlockedExchange(&resident.clear_ok, resident_load(&resident.replay_ok) &&
      !(resident_load(&resident.triggers) & RES_CLOSE_FAILURE));
    InterlockedExchange64((LONG64 *)&resident.cleanup_completed, (LONG64)completed);
    SetEvent(resident.cleared);
    return 0; /* Never replay twice or clean a merely proposed endpoint. */
  }
  const wchar_t *expected[MAX_EXPECTED];
  for (int i = 0; i < resident.server_count; ++i) expected[i] = resident.servers[i];
  resident.response.len = 0;
  // RunOnce discourages key edits during invocation: failed replay retains the journal for app/manual
  // recovery, not a guaranteed next-logon retry. Do not self-register another invocation here.
  const ULONGLONG deadline = resident.start + 1500;
  int cleared = resident_left(deadline) &&
    (!resident.server_count || KURO_RESIDENT_CLEAR(expected, resident.server_count, 0) == 0);
  if (cleared && resident.protocol2) cleared = resident_left(deadline) && !KURO_RECOVERY_UNREGISTER();
  if (cleared) cleared = resident_left(deadline) && !(resident.protocol2 ?
    kuro_resident_journal_reset_after_clear(resident.recovery, &resident.binding) : kuro_recovery_reset_after_clear(resident.recovery));
  if (cleared && !resident.protocol2) cleared = resident_left(deadline) && !KURO_RECOVERY_UNREGISTER();
  ULONGLONG completed = GetTickCount64();
  InterlockedExchange(&resident.clear_ok, cleared && completed < deadline);
  InterlockedExchange64((LONG64 *)&resident.cleanup_completed, (LONG64)completed);
  SetEvent(resident.cleared);
  return 0;
}
static DWORD WINAPI resident_report(void *unused) {
  (void)unused;
  WaitForSingleObject(resident.report, INFINITE);
  Buf report = {0};
  SYSTEMTIME time; GetSystemTime(&time);
  ULONGLONG completed = (ULONGLONG)InterlockedCompareExchange64((LONG64 *)&resident.cleanup_completed, 0, 0);
  char cleanup_duration[32] = "null";
  if (completed) snprintf(cleanup_duration, sizeof cleanup_duration, "%llu", completed - resident.start);
  putf(&report, "{\"command\":\"shutdown\",\"ok\":%s,\"timedOut\":%s,\"coreGone\":%s,\"corePid\":%lu,\"durationMs\":%llu,\"cleanupDurationMs\":%s,"
    "\"pid\":%lu,\"timestamp\":\"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\","
    "\"triggerMask\":%lu,\"queryEvents\":%lu,\"endEvents\":%lu,\"sessionFlags\":%lu}\n",
    resident_load(&resident.clear_ok) && !resident.timed_out && resident.core_gone ? "true" : "false",
    resident.timed_out ? "true" : "false", resident.core_gone ? "true" : "false",
    (unsigned long)resident_load(&resident.core_pid), GetTickCount64() - resident.start, cleanup_duration,
    GetCurrentProcessId(), time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond, time.wMilliseconds,
    (unsigned long)resident_load(&resident.triggers), (unsigned long)resident_load(&resident.query_events),
    (unsigned long)resident_load(&resident.end_events), (unsigned long)resident_load(&resident.session_flags));
  log_append(report.data, report.len);
  resident_write(report.data, report.len);
  free(report.data);
  SetEvent(resident.reported);
  return 0;
}
static DWORD WINAPI resident_supervisor(void *unused) {
  (void)unused;
  if (resident.protocol2 && !resident.recovery_only) {
    HANDLE admission[] = {resident.close, resident.replay_started};
    if (WaitForMultipleObjects(2, admission, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
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
  // The Job exists before any Core creation, including a create/publication race.
  TerminateJobObject(resident.job, 0);
  // A root exit alone does not prove descendants are gone, or that startup cannot still create Core.
  do {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
    resident.core_gone = WaitForSingleObject(resident.core_started, 0) == WAIT_OBJECT_0 &&
      QueryInformationJobObject(resident.job, JobObjectBasicAccountingInformation,
      &info, sizeof info, NULL) && !info.ActiveProcesses;
    if (resident.core_gone) break;
    DWORD left = resident_left(resident.start + 2100);
    if (!left) break;
    // Catch a Core admitted after the first termination while startup was still in progress.
    TerminateJobObject(resident.job, 0);
    Sleep(left < 10 ? left : 10);
  } while (1);
  // Preserve startup failures when possible, but never extend the original Core/exit deadline for logs.
  WaitForSingleObject(resident.core_output_done, resident_left(resident.start + 2100));
  SetEvent(resident.finished);
  SetEvent(resident.report);
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
  if (message == WM_QUERYENDSESSION || (message == WM_ENDSESSION && w)) {
    InterlockedIncrement(message == WM_QUERYENDSESSION ? &resident.query_events : &resident.end_events);
    InterlockedOr(&resident.session_flags, (LONG)l);
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
  resident.protocol2 = argc > 1 && (!wcscmp(argv[1], L"reserve") || !wcscmp(argv[1], L"recover-admitted"));
  resident.recovery_only = argc > 1 && (!wcscmp(argv[1], L"recover") || !wcscmp(argv[1], L"recover-admitted"));
  int proposed = 0;
  const wchar_t *log = NULL, *recovery_path = NULL;
  wchar_t default_exe[MAX_PATH], default_journal[MAX_PATH], default_log[MAX_PATH];
  if (!resident.protocol2 && resident.recovery_only && argc == 2) {
    if (kuro_recovery_paths(default_exe, default_journal)) return usage(L"Recovery path unavailable");
    recovery_path = default_journal;
    DWORD length = GetEnvironmentVariableW(L"APPDATA", default_log, MAX_PATH);
    if (!length || length + 35 >= MAX_PATH) return usage(L"Recovery log path unavailable");
    wcscat(default_log, L"\\Clash Kuro\\data\\runonce.log");
    log = default_log;
  }
  for (int i = 2; i < argc; i += 2) {
    if (i + 1 >= argc) return usage(L"Missing serve option value");
    if (!wcscmp(argv[i], L"--core") && !resident.core_path) resident.core_path = argv[i + 1];
    else if (!wcscmp(argv[i], L"--data") && !resident.data_dir) resident.data_dir = argv[i + 1];
    else if (!wcscmp(argv[i], L"--log") && !log) log = argv[i + 1];
    else if (!resident.protocol2 && !wcscmp(argv[i], L"--recovery") && !recovery_path) recovery_path = argv[i + 1];
    else if (resident.protocol2 && !resident.recovery_only && !wcscmp(argv[i], L"--initial-server") &&
        resident_initial_server(argv[i + 1])) { }
    else if (!wcscmp(argv[i], L"--expected-server") && (resident.protocol2 ?
        proposed < MAX_EXPECTED && kuro_valid_server(argv[i + 1]) : resident_remember(argv[i + 1]))) { ++proposed; }
    else return usage(L"Invalid serve option");
  }
  if ((!resident.recovery_only && (!kuro_valid_log_path(resident.core_path) || !kuro_valid_log_path(resident.data_dir) || !proposed)) ||
      (resident.recovery_only && (resident.core_path || resident.data_dir || proposed)) ||
      (!resident.protocol2 && !kuro_valid_log_path(recovery_path)) || (log && !kuro_valid_log_path(log)))
    return usage(L"serve requires --core/--data/--recovery/--expected-server; recover permits only --recovery/--log");
  g_log = log;
  if (resident.protocol2) {
    if (resident_reserve()) return usage(L"Native reservation/provenance unavailable; no writes admitted");
  } else {
    resident.recovery_path = recovery_path;
    resident.recovery = kuro_recovery_lock(recovery_path);
    if (resident.recovery == INVALID_HANDLE_VALUE) return usage(L"Recovery ownership unavailable; no writes admitted");
    KuroRecoveryState prior;
    if (kuro_recovery_read(resident.recovery, &prior)) return usage(L"Invalid recovery journal; manual review required");
    for (unsigned i = 0; i < prior.count; ++i)
      if (!resident_remember(prior.servers[i])) return usage(L"Recovery endpoint capacity exceeded");
    // Compatibility only: disable legacy dispatch before delivering protocol2.
    if (prior.count && !resident.recovery_only) return usage(L"Prior recovery pending; new Core and proxy writes refused");
  }
  g_before_set = resident_admit;
  g_manage_recovery = 0; /* Resident registration is independent of the legacy endpoint-only value. */
  resident.main_thread = GetCurrentThreadId();
  resident.job = kuro_core_job();
  if (!resident.job) return 3;
#define RES_EVENT(field, manual) resident.field = CreateEventW(NULL, manual, FALSE, NULL); if (!resident.field) return 3
  RES_EVENT(close, TRUE); RES_EVENT(request, FALSE); RES_EVENT(cleared, TRUE);
  RES_EVENT(finished, TRUE); RES_EVENT(report, TRUE); RES_EVENT(reported, TRUE);
  RES_EVENT(core_ready, TRUE); RES_EVENT(core_started, TRUE);
  RES_EVENT(core_output_done, TRUE); SetEvent(resident.core_output_done);
  if (resident.protocol2) { RES_EVENT(replay_started, TRUE); RES_EVENT(replay_finished, TRUE); }
#undef RES_EVENT
  WNDCLASSW cls = {0}; cls.lpfnWndProc = resident_window; cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"ClashKuroResidentProxy";
  if (!RegisterClassW(&cls)) return 3;
  resident.window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
  if (!resident.window) return 3;
  if (resident.recovery_only) {
    if (resident.protocol2) {
      InterlockedExchange(&resident.admitted, 1);
      InterlockedCompareExchange64((LONG64 *)&resident.replay_start, (LONG64)GetTickCount64(), 0);
      SetEvent(resident.replay_started);
    }
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
