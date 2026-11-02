/* One user process/Core lifetime. No reconnect, restart, elevation or service installation. */
#include "core-process.h"
#include "resident-protocol.h"
#include "recovery-journal.h"
#include "recovery-registration.h"
#ifndef KURO_RECOVERY_REGISTER
#define KURO_RECOVERY_REGISTER kuro_recovery_register
#define KURO_RECOVERY_UNREGISTER kuro_recovery_unregister
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
  HWND window;
  DWORD main_thread;
  LONG core_pid;
  LONG gate, closing, window_waiting;
  LONG triggers, query_events, end_events, session_flags;
  ULONGLONG start;
  LONG clear_ok;
  int core_gone, timed_out, recovery_only;
  const wchar_t *core_path, *data_dir, *recovery_path;
  wchar_t payload[KURO_REQUEST_BYTES / 2];
  DWORD bytes;
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
  InterlockedCompareExchange64((LONG64 *)&resident.start, (LONG64)GetTickCount64(), 0);
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
    if (!kuro_request_header(header, &kind, &bytes)) break;
    if (kind == 2) { resident_close_reason(RES_CLOSE_IPC); continue; }
    if (InterlockedCompareExchange(&resident.gate, 1, 0) != 0) break;
    if (!resident_read(resident.payload, bytes)) break;
    resident.bytes = bytes;
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
  // Persist the union before a new endpoint can reach WinINet; the lock survives all timeout paths.
  return !kuro_recovery_admit(resident.recovery, server) &&
    !KURO_RECOVERY_REGISTER(resident.recovery_path) && resident_remember(server);
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
  DWORD resumed = ResumeThread(core.hThread);
  CloseHandle(core.hThread);
  return resumed != (DWORD)-1;
}
static DWORD WINAPI resident_worker(void *unused) {
  (void)unused;
  g_capture = &resident.response;
  if (resident.recovery_only) {
    SetEvent(resident.core_started);
    goto cleanup;
  }
  if (KURO_RESIDENT_WARM()) resident_close(); /* Initialize before shutdown; a failed warmup closes admission. */
  resident.response.len = 0;
  int started = !resident_load(&resident.closing) && resident_start_core();
  SetEvent(resident.core_started);
  if (!started) resident_close();
  if (!resident_load(&resident.closing)) {
    static const char ready[] = "{\"ready\":true,\"protocol\":1}\n";
    resident_write(ready, sizeof ready - 1);
  }
  HANDLE events[] = {resident.close, resident.request};
  for (;;) {
    DWORD event = WaitForMultipleObjects(2, events, FALSE, INFINITE);
    if (event != WAIT_OBJECT_0 + 1 || (resident_load(&resident.gate) & 2)) {
      resident_close_reason(event == WAIT_FAILED ? RES_CLOSE_FAILURE : 0); break;
    }
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
  const wchar_t *expected[MAX_EXPECTED];
  for (int i = 0; i < resident.server_count; ++i) expected[i] = resident.servers[i];
  resident.response.len = 0;
  // RunOnce discourages key edits during invocation: failed replay retains the journal for app/manual
  // recovery, not a guaranteed next-logon retry. Do not self-register another invocation here.
  int cleared = !resident.server_count || KURO_RESIDENT_CLEAR(expected, resident.server_count, 0) == 0;
  if (cleared && kuro_recovery_reset_after_clear(resident.recovery)) cleared = 0;
  if (cleared && KURO_RECOVERY_UNREGISTER()) cleared = 0;
  InterlockedExchange(&resident.clear_ok, cleared);
  SetEvent(resident.cleared);
  return 0;
}
static DWORD WINAPI resident_report(void *unused) {
  (void)unused;
  WaitForSingleObject(resident.report, INFINITE);
  Buf report = {0};
  SYSTEMTIME time; GetSystemTime(&time);
  putf(&report, "{\"command\":\"shutdown\",\"ok\":%s,\"timedOut\":%s,\"coreGone\":%s,\"corePid\":%lu,\"durationMs\":%llu,"
    "\"pid\":%lu,\"timestamp\":\"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\","
    "\"triggerMask\":%lu,\"queryEvents\":%lu,\"endEvents\":%lu,\"sessionFlags\":%lu}\n",
    resident_load(&resident.clear_ok) && !resident.timed_out && resident.core_gone ? "true" : "false",
    resident.timed_out ? "true" : "false", resident.core_gone ? "true" : "false",
    (unsigned long)resident_load(&resident.core_pid), GetTickCount64() - resident.start,
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
  HANDLE startup[] = {resident.close, resident.core_ready};
  if (WaitForMultipleObjects(2, startup, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) {
    HANDLE live[] = {resident.close, InterlockedCompareExchangePointer((PVOID volatile *)&resident.core, NULL, NULL)};
    DWORD event = WaitForMultipleObjects(2, live, FALSE, INFINITE);
    resident_close_reason(event == WAIT_OBJECT_0 + 1 ? RES_CLOSE_CORE : 0);
  }
  resident.timed_out = WaitForSingleObject(resident.cleared, resident_left(resident.start + 1500)) != WAIT_OBJECT_0;
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
  resident.recovery_only = argc > 1 && !wcscmp(argv[1], L"recover");
  const wchar_t *log = NULL, *recovery_path = NULL;
  wchar_t default_exe[MAX_PATH], default_journal[MAX_PATH], default_log[MAX_PATH];
  if (resident.recovery_only && argc == 2) {
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
    else if (!wcscmp(argv[i], L"--recovery") && !recovery_path) recovery_path = argv[i + 1];
    else if (!wcscmp(argv[i], L"--expected-server") && resident_remember(argv[i + 1])) { }
    else return usage(L"Invalid serve option");
  }
  if ((!resident.recovery_only && (!kuro_valid_log_path(resident.core_path) || !kuro_valid_log_path(resident.data_dir) || !resident.server_count)) ||
      (resident.recovery_only && (resident.core_path || resident.data_dir || resident.server_count)) ||
      !kuro_valid_log_path(recovery_path) || (log && !kuro_valid_log_path(log)))
    return usage(L"serve requires --core/--data/--recovery/--expected-server; recover permits only --recovery/--log");
  g_log = log;
  resident.recovery_path = recovery_path;
  resident.recovery = kuro_recovery_lock(recovery_path);
  if (resident.recovery == INVALID_HANDLE_VALUE) return usage(L"Recovery ownership unavailable; no writes admitted");
  KuroRecoveryState prior;
  if (kuro_recovery_read(resident.recovery, &prior)) return usage(L"Invalid recovery journal; manual review required");
  for (unsigned i = 0; i < prior.count; ++i)
    if (!resident_remember(prior.servers[i])) return usage(L"Recovery endpoint capacity exceeded");
  // Until migration/replay is implemented, never start a new owner over unresolved prior settings.
  if (prior.count && !resident.recovery_only) return usage(L"Prior recovery pending; new Core and proxy writes refused");
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
#undef RES_EVENT
  WNDCLASSW cls = {0}; cls.lpfnWndProc = resident_window; cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"ClashKuroResidentProxy";
  if (!RegisterClassW(&cls)) return 3;
  resident.window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
  if (!resident.window) return 3;
  if (resident.recovery_only) resident_close_reason(RES_CLOSE_RECOVER);
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
