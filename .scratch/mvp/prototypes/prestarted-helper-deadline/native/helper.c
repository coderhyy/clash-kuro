/* THROWAWAY: fake operations/Core only; no WinINet or registry operations. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static struct {
  HANDLE triggered, operation_start, operation_done, decision_ready, finished, report_start, report_done;
  HANDLE stop_core, core_ready, core;
  HANDLE window_ready;
  HANDLE shutdown_done;
  HWND window;
  const wchar_t *report;
  LONG closing, triggers, eof, decision, operations, stops, coordinator_done, window_triggers;
  LONG window_waiting, nested_queries, notification_in_wait;
  ULONGLONG start, deadline, operation_at, decided_at, stop_at, end_at;
  ULONGLONG start_epoch;
  DWORD core_pid, core_exit;
  int operation_hang, coordinator_hang, rescue_negative, core_hang;
  DWORD operation_delay;
  int core_forced, core_gone, forced_self;
  int query_plain, operation_notify, notification_hang;
} s;

static LONG load(LONG *p) { return InterlockedCompareExchange(p, 0, 0); }
static ULONGLONG epoch(void) {
  FILETIME ft; ULARGE_INTEGER value;
  GetSystemTimeAsFileTime(&ft); value.LowPart = ft.dwLowDateTime; value.HighPart = ft.dwHighDateTime;
  return value.QuadPart / 10000 - 11644473600000ULL;
}
static DWORD left(ULONGLONG end) {
  ULONGLONG now = GetTickCount64();
  return end > now ? (DWORD)(end - now) : 0;
}
static void ack(const char *text, DWORD length) {
  DWORD written;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, length, &written, NULL);
}
static int begin_close(void) {
  InterlockedIncrement(&s.triggers);
  if (InterlockedCompareExchange(&s.closing, 1, 0)) return 0;
  s.start = GetTickCount64(); s.deadline = s.start + 1500;
  s.start_epoch = epoch();
  SetEvent(s.triggered);
  return 1;
}
static void trigger(void) {
  /* A blocked/broken acknowledgement cannot block the supervisor or coordinator. */
  if (begin_close()) ack("triggered\n", 10);
}
static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_APP + 2) {
    if (load(&s.window_waiting)) InterlockedIncrement(&s.notification_in_wait);
    if (s.notification_hang) Sleep(INFINITE); /* Explicit test fault; supervision must end us. */
    return 1;
  }
  if (message == WM_APP + 1 || message == WM_QUERYENDSESSION ||
      (message == WM_ENDSESSION && wparam)) {
    InterlockedIncrement(&s.window_triggers);
    begin_close();
    if (InterlockedCompareExchange(&s.window_waiting, 1, 0)) {
      InterlockedIncrement(&s.nested_queries);
      return message == WM_QUERYENDSESSION ? TRUE : 0;
    }
    /* One original budget: clear 1500, Core stop through 2000, confirmation through 2100. */
    if (WaitForSingleObject(s.triggered, 0) == WAIT_OBJECT_0) {
      if (s.query_plain) WaitForSingleObject(s.shutdown_done, left(s.start + 2100));
      else while (left(s.start + 2100)) {
        DWORD waited = MsgWaitForMultipleObjectsEx(1, &s.shutdown_done, left(s.start + 2100),
          QS_SENDMESSAGE, MWMO_INPUTAVAILABLE);
        if (waited != WAIT_OBJECT_0 + 1) break;
        /* Only this helper's native procedures run here, never the Electron/JS pump. */
        MSG incoming;
        PeekMessageW(&incoming, NULL, 0, 0, PM_NOREMOVE);
      }
    }
    InterlockedExchange(&s.window_waiting, 0);
    return message == WM_QUERYENDSESSION ? TRUE : 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
static DWORD WINAPI window_thread(void *unused) {
  (void)unused;
  WNDCLASSW cls = {0};
  cls.lpfnWndProc = window_proc;
  cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"KuroIsolatedHelperProbe";
  if (!RegisterClassW(&cls)) { SetEvent(s.window_ready); return 1; }
  /* Hidden top-level window, not HWND_MESSAGE (which misses broadcast sessions). */
  s.window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"", WS_POPUP,
    0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
  SetEvent(s.window_ready);
  if (!s.window) return 2;
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return 0;
}
static DWORD WINAPI reader(void *unused) {
  (void)unused;
  char byte; DWORD count;
  while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), &byte, 1, &count, NULL) && count) {
    if (byte == 'C') trigger();
    if (byte == 'W') {
      if (!PostMessageW(s.window, WM_APP + 1, 0, 0)) return 1;
      if (WaitForSingleObject(s.triggered, 1000) != WAIT_OBJECT_0) return 2;
      ack("triggered\n", 10);
    }
  }
  InterlockedExchange(&s.eof, 1);
  trigger(); /* Losing the only controller closes this one-shot instance. No reconnect. */
  return 0;
}
static DWORD WINAPI operation(void *unused) {
  (void)unused;
  WaitForSingleObject(s.operation_start, INFINITE);
  InterlockedIncrement(&s.operations);
  if (s.operation_hang) Sleep(INFINITE);
  Sleep(s.operation_delay);
  if (s.operation_notify) {
    DWORD_PTR result;
    if (!s.query_plain && !s.notification_hang)
      SendMessageTimeoutW(s.window, WM_APP + 1, 0, 0, SMTO_BLOCK | SMTO_ABORTIFHUNG, 3000, &result);
    if (!SendMessageTimeoutW(s.window, WM_APP + 2, 0, 0, SMTO_BLOCK | SMTO_ABORTIFHUNG, 3000, &result)) return 1;
  }
  s.operation_at = GetTickCount64();
  SetEvent(s.operation_done);
  return 0;
}
static DWORD WINAPI write_report(void *unused) {
  (void)unused;
  WaitForSingleObject(s.report_start, INFINITE);
  FILE *f = _wfopen(s.report, L"wb");
  if (!f) return 1;
  fprintf(f, "{\"pid\":%lu,\"corePid\":%lu,\"decision\":\"%s\","
    "\"triggers\":%ld,\"operations\":%ld,\"stops\":%ld,\"eof\":%ld,\"windowTriggers\":%ld,"
    "\"nestedQueries\":%ld,\"notificationInWait\":%ld,"
    "\"decisionMs\":%llu,\"stopMs\":%llu,\"endMs\":%llu,"
    "\"deadlineMs\":%llu,\"startEpochMs\":%llu,\"reportEpochMs\":%llu,\"coreGone\":%s,\"coreForced\":%s,"
    "\"coreExit\":%lu,\"selfForced\":%s,\"coordinatorDone\":%ld}\n",
    GetCurrentProcessId(), s.core_pid, load(&s.decision) == 1 ? "cleared" : "timeout",
    load(&s.triggers), load(&s.operations), load(&s.stops), load(&s.eof), load(&s.window_triggers),
    load(&s.nested_queries), load(&s.notification_in_wait),
    s.decided_at - s.start, s.stop_at - s.start, s.end_at - s.start,
    s.deadline - s.start, s.start_epoch, epoch(), s.core_gone ? "true" : "false", s.core_forced ? "true" : "false",
    s.core_exit, s.forced_self ? "true" : "false", load(&s.coordinator_done));
  if (fclose(f)) return 2;
  SetEvent(s.report_done);
  return 0;
}
static DWORD WINAPI supervisor(void *unused) {
  (void)unused;
  WaitForSingleObject(s.triggered, INFINITE); /* Idle before a test trigger, not shutdown wait. */
  if (s.rescue_negative) Sleep(INFINITE);
  DWORD result = WaitForSingleObject(s.decision_ready, left(s.deadline));
  if (result != WAIT_OBJECT_0) {
    /* Sole decision consumer. Timeout never becomes success from a late operation. */
    InterlockedExchange(&s.decision, 2);
  }
  s.decided_at = GetTickCount64();
  s.stop_at = GetTickCount64();
  InterlockedIncrement(&s.stops); /* Only this thread owns Core stop, even if coordinator stalls. */
  SetEvent(s.stop_core);
  ULONGLONG stop_deadline = s.stop_at + 500;
  if (stop_deadline > s.start + 2000) stop_deadline = s.start + 2000;
  if (WaitForSingleObject(s.core, left(stop_deadline)) != WAIT_OBJECT_0) {
    s.core_forced = 1;
    TerminateProcess(s.core, 41); /* Exact child process handle retained since CreateProcess. */
    WaitForSingleObject(s.core, left(s.start + 2100));
  }
  s.core_gone = WaitForSingleObject(s.core, 0) == WAIT_OBJECT_0;
  GetExitCodeProcess(s.core, &s.core_exit);
  /* Uncertainty is a runtime outcome, not knowledge of the injected fault. */
  s.forced_self = load(&s.decision) != 1 || !s.core_gone;
  s.end_at = GetTickCount64();
  SetEvent(s.shutdown_done);
  SetEvent(s.report_start);
  /* Diagnostic filesystem I/O is outside shutdown work and cannot trap supervision. */
  DWORD logged = WaitForSingleObject(s.report_done, 100);
  if (logged != WAIT_OBJECT_0 || s.forced_self) {
    TerminateProcess(GetCurrentProcess(), logged != WAIT_OBJECT_0 ? 43 : 42);
    return 42;
  }
  SetEvent(s.finished);
  return 0;
}
static int launch_core(void) {
  SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
  s.stop_core = CreateEventW(&sa, TRUE, FALSE, NULL);
  s.core_ready = CreateEventW(&sa, TRUE, FALSE, NULL);
  if (!s.stop_core || !s.core_ready) return 0;
  wchar_t exe[32768], command[33000];
  if (!GetModuleFileNameW(NULL, exe, 32768)) return 0;
  _snwprintf(command, 33000, L"\"%ls\" --core %llu %llu %d", exe,
    (unsigned long long)(uintptr_t)s.stop_core, (unsigned long long)(uintptr_t)s.core_ready, s.core_hang);
  SIZE_T size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &size);
  STARTUPINFOEXW si = {0}; si.StartupInfo.cb = sizeof si;
  si.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, size);
  HANDLE inherited[] = { s.stop_core, s.core_ready };
  if (!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &size) ||
      !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        inherited, sizeof inherited, NULL, NULL)) return 0;
  PROCESS_INFORMATION pi = {0};
  BOOL ok = CreateProcessW(exe, command, NULL, NULL, TRUE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL, NULL, &si.StartupInfo, &pi);
  DeleteProcThreadAttributeList(si.lpAttributeList); HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
  if (!ok) return 0;
  CloseHandle(pi.hThread); s.core = pi.hProcess; s.core_pid = pi.dwProcessId;
  return WaitForSingleObject(s.core_ready, 3000) == WAIT_OBJECT_0;
}
int wmain(int argc, wchar_t **argv) {
  if (argc == 5 && !wcscmp(argv[1], L"--core")) {
    HANDLE stop = (HANDLE)(uintptr_t)_wcstoui64(argv[2], NULL, 10);
    HANDLE ready = (HANDLE)(uintptr_t)_wcstoui64(argv[3], NULL, 10);
    SetEvent(ready);
    if (_wtoi(argv[4])) Sleep(INFINITE);
    return WaitForSingleObject(stop, INFINITE) == WAIT_OBJECT_0 ? 0 : 90;
  }
  if (argc != 3) return 91;
  s.report = argv[2];
  s.operation_hang = !wcscmp(argv[1], L"operation-hang") || !wcscmp(argv[1], L"repeat");
  s.operation_delay = !wcscmp(argv[1], L"electron-exit") ? 400 : 40;
  if (!wcscmp(argv[1], L"late-operation")) s.operation_delay = 1900;
  s.coordinator_hang = !wcscmp(argv[1], L"coordinator-hang");
  s.rescue_negative = !wcscmp(argv[1], L"watchdog-negative");
  s.core_hang = !wcscmp(argv[1], L"core-hang");
  s.query_plain = !wcscmp(argv[1], L"query-plain");
  s.notification_hang = !wcscmp(argv[1], L"query-handler-hang");
  s.operation_notify = s.query_plain || s.notification_hang || !wcscmp(argv[1], L"query-aware");
#define EVENT(name) s.name = CreateEventW(NULL, TRUE, FALSE, NULL); if (!s.name) return 92
  EVENT(triggered); EVENT(operation_start); EVENT(operation_done); EVENT(decision_ready);
  EVENT(finished); EVENT(report_start); EVENT(report_done);
  EVENT(window_ready);
  EVENT(shutdown_done);
#undef EVENT
  HANDLE window = CreateThread(NULL, 0, window_thread, NULL, 0, NULL);
  if (!window) return 98;
  CloseHandle(window);
  if (WaitForSingleObject(s.window_ready, 3000) != WAIT_OBJECT_0 || !s.window) return 99;
  if (!launch_core()) return 93;
  HANDLE thread = CreateThread(NULL, 0, operation, NULL, 0, NULL);
  if (!thread) return 96;
  CloseHandle(thread);
  thread = CreateThread(NULL, 0, write_report, NULL, 0, NULL);
  if (!thread) return 97;
  CloseHandle(thread);
  thread = CreateThread(NULL, 0, supervisor, NULL, 0, NULL);
  if (!thread) return 94;
  CloseHandle(thread);
  thread = CreateThread(NULL, 0, reader, NULL, 0, NULL);
  if (!thread) return 95;
  CloseHandle(thread);
  ack("ready\n", 6);
  WaitForSingleObject(s.triggered, INFINITE);
  if (s.coordinator_hang || s.rescue_negative) Sleep(INFINITE);
  SetEvent(s.operation_start);
  DWORD waited = WaitForSingleObject(s.operation_done, left(s.deadline));
  int success = waited == WAIT_OBJECT_0 && s.operation_at <= s.deadline;
  /* Publish before signalling; after a supervisor timeout the outcome stays uncertain. */
  InterlockedCompareExchange(&s.decision, success ? 1 : 2, 0);
  InterlockedExchange(&s.coordinator_done, 1);
  SetEvent(s.decision_ready);
  WaitForSingleObject(s.finished, INFINITE); /* Supervisor owns exit if main/worker cannot finish. */
  return 0;
}
