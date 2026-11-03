/* Isolated manual session experiment: probe.c operations + resident.c's helper bridge. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"

static struct {
  Backup backup;
  const wchar_t *core, *data, *report;
  HANDLE initialized;
  CRITICAL_SECTION report_lock;
  Buf set_result, clear_result, readback;
  const char *source;
  LONG set_attempted, set_done, set_verified, clear_done, clear_verified, ready;
  LONG query_session, end_session, end_session_true, test_trigger;
  DWORD startup_error, stop_error;
  LPARAM query_flags, end_flags;
  ULONGLONG started, core_started, core_ready, set_started, set_finished, ready_at;
  ULONGLONG clear_started, clear_finished, readback_finished, stop_requested;
  ULONGLONG query_at, end_at;
} session;
#ifndef KURO_SESSION_FAKE
static const wchar_t session_endpoint[] = L"127.0.0.1:48967";
#endif

static int session_launch_core(void);
static void session_stop_core(void);
static void session_initialize(void);
static int session_clear(void);
static void session_ready(void);
static void session_message(UINT message, WPARAM wparam, LPARAM lparam);
static void session_close_started(const char *source);
static void session_report_fields(FILE *f);
static FILE *session_report_open(void);
static int session_report_close(FILE *f);
#define KURO_LAUNCH_CORE session_launch_core
#define KURO_REQUEST_CORE_STOP session_stop_core
#define KURO_OPERATION_INIT session_initialize
#define KURO_REAL_OPERATION session_clear
#define KURO_HELPER_READY session_ready
#define KURO_WINDOW_MESSAGE session_message
#define KURO_CLOSE_STARTED session_close_started
#define KURO_REPORT_FIELDS session_report_fields
#define KURO_REPORT_OPEN session_report_open
#define KURO_REPORT_CLOSE session_report_close
#define KURO_REPORT_BEFORE_RETURN 1
#define KURO_COORDINATION_MAIN coordination_main
#include "../prestarted-helper-deadline/native/helper.c"

static void session_close_started(const char *source) { session.source = source; }
static void session_message(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_QUERYENDSESSION) {
    if (InterlockedIncrement(&session.query_session) == 1) session.query_at = epoch();
    session.query_flags = lparam;
  } else if (message == WM_ENDSESSION) {
    InterlockedIncrement(&session.end_session);
    if (wparam) InterlockedIncrement(&session.end_session_true);
    if (!session.end_at) session.end_at = epoch();
    session.end_flags = lparam;
  } else if (message == WM_APP + 1) InterlockedIncrement(&session.test_trigger);
}

static int session_command(wchar_t *out, size_t cap, const wchar_t *core, const wchar_t *data) {
  if (!kuro_valid_log_path(core) || !kuro_valid_log_path(data)) return 0;
  int n = _snwprintf(out, cap, L"\"%ls\" -d \"%ls\\.\" -f \"%ls\\runtime.yaml\"", core, data, data);
  return n > 0 && (size_t)n < cap;
}
static struct sockaddr_in session_address(void) {
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET; addr.sin_port = htons(48967);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  return addr;
}
static int session_launch_core(void) {
  /* Refuse an occupied fixture port before launching; never probe a production listener. */
  SOCKET port = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  BOOL exclusive = TRUE;
  struct sockaddr_in addr = session_address();
  int available = port != INVALID_SOCKET &&
    !setsockopt(port, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof exclusive) &&
    !bind(port, (const struct sockaddr *)&addr, sizeof addr);
  if (!available) session.startup_error = WSAGetLastError();
  if (port != INVALID_SOCKET) closesocket(port);
  if (!available) return 0;
  s.core_job = kuro_core_job();
  if (!s.core_job) { session.startup_error = GetLastError(); return 0; }
  SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
    &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  wchar_t log[512], command[2048];
  _snwprintf(log, 512, L"%ls\\session-core.log", session.data);
  HANDLE output = CreateFileW(log, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
    &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (nul == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE ||
      !session_command(command, 2048, session.core, session.data)) {
    session.startup_error = ERROR_INVALID_PARAMETER;
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    return 0;
  }
  STARTUPINFOW stdio = {0};
  stdio.hStdInput = nul; stdio.hStdOutput = stdio.hStdError = output;
  HANDLE inherited[] = { nul, output };
  PROCESS_INFORMATION pi = {0};
  BOOL ok = kuro_create_core(s.core_job, session.core, command, session.data, inherited, 2, &pi, &stdio);
  session.startup_error = ok ? 0 : GetLastError();
  CloseHandle(nul); CloseHandle(output);
  if (!ok) return 0;
  s.core = pi.hProcess; s.core_pid = pi.dwProcessId;
  session.core_started = epoch();
  DWORD resumed = ResumeThread(pi.hThread);
  if (resumed == (DWORD)-1) session.startup_error = GetLastError();
  CloseHandle(pi.hThread);
  return resumed != (DWORD)-1;
}
static void session_stop_core(void) {
  session.stop_requested = epoch();
  s.core_forced = 1; /* Mihomo has no inherited fake-Core stop event; this is termination, not graceful exit. */
  session.stop_error = TerminateProcess(s.core, 41) ? 0 : GetLastError();
}

static int session_socket_wait(SOCKET sock, int writing, ULONGLONG deadline) {
  while (left(deadline) && !load(&s.closing) && WaitForSingleObject(s.core, 0) == WAIT_TIMEOUT) {
    fd_set ready, failed; FD_ZERO(&ready); FD_ZERO(&failed);
    FD_SET(sock, &ready); FD_SET(sock, &failed);
    DWORD ms = left(deadline); if (ms > 50) ms = 50;
    struct timeval timeout = { 0, (long)ms * 1000 };
    int n = select(0, writing ? NULL : &ready, writing ? &ready : NULL, &failed, &timeout);
    if (n == SOCKET_ERROR || FD_ISSET(sock, &failed)) return 0;
    if (n > 0) return 1;
  }
  return 0;
}
static int session_socks_ready(void) {
  ULONGLONG deadline = GetTickCount64() + 5000;
  while (left(deadline) && !load(&s.closing) && WaitForSingleObject(s.core, 0) == WAIT_TIMEOUT) {
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return 0;
    u_long nonblocking = 1;
    struct sockaddr_in addr = session_address();
    int ok = !ioctlsocket(sock, FIONBIO, &nonblocking);
    if (ok && connect(sock, (const struct sockaddr *)&addr, sizeof addr) == SOCKET_ERROR)
      ok = WSAGetLastError() == WSAEWOULDBLOCK && session_socket_wait(sock, 1, deadline);
    int error = 0, bytes = sizeof error;
    if (ok) ok = !getsockopt(sock, SOL_SOCKET, SO_ERROR, (char *)&error, &bytes) && !error;
    const char hello[] = { 5, 1, 0 }; char reply[2] = {0};
    for (int at = 0; ok && at < 3;) {
      if (!session_socket_wait(sock, 1, deadline)) { ok = 0; break; }
      int n = send(sock, hello + at, 3 - at, 0);
      if (n == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) continue;
      if (n <= 0) { ok = 0; break; } at += n;
    }
    for (int at = 0; ok && at < 2;) {
      if (!session_socket_wait(sock, 0, deadline)) { ok = 0; break; }
      int n = recv(sock, reply + at, 2 - at, 0);
      if (n == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) continue;
      if (n <= 0) { ok = 0; break; } at += n;
    }
    closesocket(sock);
    if (ok && reply[0] == 5 && reply[1] == 0) { session.core_ready = epoch(); return 1; }
    Sleep(20);
  }
  return 0;
}

static void session_initialize(void) {
  if (!session_socks_ready()) session.startup_error = ERROR_NOT_READY;
#ifndef KURO_SESSION_FAKE
  else if (!preflight(&session.backup, NULL)) session.startup_error = ERROR_INVALID_DATA;
#endif
  else if (!load(&s.closing)) {
    session.set_started = epoch();
    InterlockedExchange(&session.set_attempted, 1);
#ifdef KURO_SESSION_FAKE
    puts_(&session.set_result, "{\"fake\":true,\"ok\":true}");
    InterlockedExchange(&session.set_verified, 1);
#else
    g_capture = &session.set_result;
    int result = set_connections(session_endpoint, TEST_BYPASS, 0);
    g_capture = NULL;
    if (!result && verify_fixture(&session.backup, session_endpoint, 3))
      InterlockedExchange(&session.set_verified, 1);
    else session.startup_error = ERROR_WRITE_FAULT;
#endif
    session.set_finished = epoch();
    InterlockedExchange(&session.set_done, 1);
  }
  if (!load(&session.set_verified)) begin_close("startup-failure");
  SetEvent(session.initialized);
}
static int session_clear(void) {
  session.clear_started = epoch();
  int result = 0;
  if (load(&session.set_attempted)) {
#ifdef KURO_SESSION_FAKE
    /* Faults only exist in the no-proxy build; keep the real Core and supervisor. */
    if (wcsstr(session.data, L"clear-hang")) Sleep(INFINITE);
    result = wcsstr(session.data, L"clear-error") ? 2 : 0;
    puts_(&session.clear_result, result ? "{\"fake\":true,\"ok\":false}" : "{\"fake\":true,\"ok\":true}");
    session.clear_finished = epoch();
    puts_(&session.readback, "{\"fake\":true,\"flags\":1}");
    if (wcsstr(session.data, L"readback-hang")) Sleep(INFINITE);
    InterlockedExchange(&session.clear_verified, !result);
#else
    if (!preflight(&session.backup, session_endpoint)) result = 2;
    else {
      const wchar_t *expected[] = { session_endpoint };
      g_capture = &session.clear_result;
      result = clear_connections(expected, 1, 0);
      g_capture = NULL;
    }
    session.clear_finished = epoch();
    g_capture = &session.readback;
    int readback_result = cmd_get();
    g_capture = NULL;
    if (!readback_result && verify_fixture(&session.backup, session_endpoint, 1))
      InterlockedExchange(&session.clear_verified, 1);
    if (!load(&session.clear_verified)) result = 2;
#endif
  } else session.clear_finished = epoch();
  session.readback_finished = epoch();
  InterlockedExchange(&session.clear_done, 1);
  return result;
}

static FILE *session_report_open(void) {
  EnterCriticalSection(&session.report_lock);
  FILE *f = _wfopen(session.report, L"wb");
  if (!f) LeaveCriticalSection(&session.report_lock);
  return f;
}
static int session_report_close(FILE *f) {
  int failed = ferror(f);
  int result = fclose(f);
  LeaveCriticalSection(&session.report_lock);
  return failed ? EOF : result;
}
static void session_report_fields(FILE *f) {
  int set_done = load(&session.set_done), clear_done = load(&session.clear_done);
  fprintf(f, ",\"experiment\":\"real-logoff\",\"fakeProxy\":%s,\"runOnceManaged\":false,\"endpoint\":\"127.0.0.1:48967\","
    "\"phase\":\"%s\",\"firstTriggerSource\":\"%s\",\"querySession\":%ld,\"endSession\":%ld,\"endSessionTrue\":%ld,"
    "\"testTriggers\":%ld,\"querySessionFlags\":%llu,\"endSessionFlags\":%llu,"
    "\"querySessionEpochMs\":%llu,\"endSessionEpochMs\":%llu,\"processStartEpochMs\":%llu,"
    "\"coreStartEpochMs\":%llu,\"coreReadyEpochMs\":%llu,\"setStartEpochMs\":%llu,\"setEndEpochMs\":%llu,"
    "\"readyEpochMs\":%llu,\"clearStartEpochMs\":%llu,\"clearEndEpochMs\":%llu,\"readbackEndEpochMs\":%llu,"
    "\"coreStopRequestEpochMs\":%llu,\"startupError\":%lu,\"coreStopError\":%lu,"
    "\"setAttempted\":%s,\"setVerified\":%s,\"cleanupReadbackVerified\":%s,\"coreStopMethod\":\"TerminateProcess-exact-handle\","
    "\"setResult\":%s,\"clearResult\":%s,\"cleanupReadback\":%s",
#ifdef KURO_SESSION_FAKE
    "true",
#else
    "false",
#endif
    load(&s.closing) ? (load(&session.ready) ? "shutdown-complete" : "startup-failed") : "armed",
    session.source ? session.source : "none", load(&session.query_session), load(&session.end_session),
    load(&session.end_session_true), load(&session.test_trigger),
    (unsigned long long)(ULONG_PTR)session.query_flags, (unsigned long long)(ULONG_PTR)session.end_flags,
    session.query_at, session.end_at, session.started, session.core_started, session.core_ready,
    session.set_started, set_done ? session.set_finished : 0, session.ready_at,
    session.clear_started, clear_done ? session.clear_finished : 0, clear_done ? session.readback_finished : 0,
    session.stop_requested, session.startup_error, session.stop_error,
    load(&session.set_attempted) ? "true" : "false", load(&session.set_verified) ? "true" : "false",
    clear_done && load(&session.clear_verified) ? "true" : "false",
    set_done && session.set_result.data ? session.set_result.data : "null",
    clear_done && session.clear_result.data ? session.clear_result.data : "null",
    clear_done && session.readback.data ? session.readback.data : "null");
  fprintf(f, ",\"cleanupWithinBudget\":%s,\"decisionEpochMs\":%llu,\"coreStopConfirmedEpochMs\":%llu",
    clear_done && s.operation_at && s.operation_at <= s.deadline && load(&session.clear_verified) ? "true" : "false",
    s.decided_at ? s.start_epoch + s.decided_at - s.start : 0,
    s.core_gone ? s.start_epoch + s.end_at - s.start : 0);
}
static int session_checkpoint(const char *phase) {
  FILE *f = session_report_open();
  if (!f) return 0;
  /* A final shutdown report must never be overwritten by a late startup checkpoint. */
  fprintf(f, "{\"pid\":%lu,\"corePid\":%lu,\"checkpoint\":\"%s\",\"reportEpochMs\":%llu",
    GetCurrentProcessId(), s.core_pid, phase, epoch());
  session_report_fields(f); fputs("}\n", f);
  return session_report_close(f) == 0;
}
static void session_ready(void) {
  HANDLE events[] = { session.initialized, s.triggered };
  WaitForMultipleObjects(2, events, FALSE, INFINITE);
  if (load(&s.closing) || !load(&session.set_verified)) return;
  if (WaitForSingleObject(s.core, 0) != WAIT_TIMEOUT) {
    session.startup_error = ERROR_NOT_READY; begin_close("startup-core-exit"); return;
  }
  EnterCriticalSection(&session.report_lock);
  if (!load(&s.closing)) {
    session.ready_at = epoch();
    InterlockedExchange(&session.ready, 1);
    if (session_checkpoint("ready")) {
      if (!load(&s.closing)) ack("ready\n", 6);
      else InterlockedExchange(&session.ready, 0);
    }
    else {
      InterlockedExchange(&session.ready, 0);
      session.startup_error = ERROR_WRITE_FAULT; begin_close("startup-report-failure");
    }
  }
  LeaveCriticalSection(&session.report_lock);
}

int wmain(int argc, wchar_t **argv) {
  if (argc == 2 && !wcscmp(argv[1], L"self-test")) {
    wchar_t command[2048];
    assert(session_command(command, 2048, L"C:\\core path\\mihomo.exe", L"C:\\isolated data"));
    assert(!wcscmp(command, L"\"C:\\core path\\mihomo.exe\" -d \"C:\\isolated data\\.\" -f \"C:\\isolated data\\runtime.yaml\""));
    assert(!session_command(command, 2048, L"relative.exe", L"C:\\data"));
    assert(!session_command(command, 8, L"C:\\core.exe", L"C:\\data"));
    session_message(WM_APP + 1, 0, 0);
    assert(session.test_trigger == 1 && !session.query_session && !session.end_session);
    session_message(WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF);
    session_message(WM_ENDSESSION, FALSE, ENDSESSION_LOGOFF);
    session_message(WM_ENDSESSION, TRUE, ENDSESSION_LOGOFF);
    assert(session.query_session == 1 && session.end_session == 2 && session.end_session_true == 1);
    assert(session.query_at && session.end_at && session.query_flags == ENDSESSION_LOGOFF);
    wchar_t *args[] = { argv[0], L"self-test" };
    return backup_probe_main(2, args);
  }
  if (argc != 6 || wcscmp(argv[1], L"arm")) return usage(L"arm BACKUP REPORT CORE DATA | self-test");
  for (int i = 2; i < 6; ++i) if (!kuro_valid_log_path(argv[i])) return usage(L"Use absolute drive paths without trailing slashes");
  DWORD core_attr = GetFileAttributesW(argv[4]), data_attr = GetFileAttributesW(argv[5]);
  wchar_t config[512]; _snwprintf(config, 512, L"%ls\\runtime.yaml", argv[5]);
  if (core_attr == INVALID_FILE_ATTRIBUTES || (core_attr & FILE_ATTRIBUTE_DIRECTORY) ||
      data_attr == INVALID_FILE_ATTRIBUTES || !(data_attr & FILE_ATTRIBUTE_DIRECTORY) ||
      GetFileAttributesW(config) == INVALID_FILE_ATTRIBUTES) return usage(L"Require supplied Core and isolated DATA/runtime.yaml");
#ifndef KURO_SESSION_FAKE
  if (!load_backup(argv[2], &session.backup)) return usage(L"Invalid or incomplete snapshot");
#endif
  HANDLE report = CreateFileW(argv[3], GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
  if (report == INVALID_HANDLE_VALUE) return usage(L"REPORT must be a new file");
  CloseHandle(report);
  session.core = argv[4]; session.data = argv[5]; session.report = argv[3]; session.started = epoch();
  InitializeCriticalSection(&session.report_lock);
  session.initialized = CreateEventW(NULL, TRUE, FALSE, NULL);
  WSADATA network;
  if (!session.initialized || WSAStartup(MAKEWORD(2, 2), &network)) return usage(L"Native startup initialization failed");
  wchar_t *args[] = { argv[0], L"real-aware", argv[3] };
  int result = coordination_main(3, args);
  /* Startup failures also close the private kill-on-close Job, including suspended Core. */
  if (s.core_job) { CloseHandle(s.core_job); s.core_job = NULL; }
  if (s.core) {
    WaitForSingleObject(s.core, 100);
    s.core_gone = WaitForSingleObject(s.core, 0) == WAIT_OBJECT_0;
  }
  if (result) {
    if (!session.startup_error) session.startup_error = ERROR_NOT_READY;
    begin_close("startup-failure");
    session_checkpoint("startup-failed");
  }
  WSACleanup();
  return result ? result : load(&session.ready) && !session.startup_error ? 0 : 2;
}
