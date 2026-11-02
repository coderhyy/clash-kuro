/* THROWAWAY: fake operations only. No WinINet, registry, filesystem or Core APIs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <node_api.h>
#include <math.h>
#include <tlhelp32.h>
#include "bindings.h"

/* One owner/environment per process. Pinning retains this bounded state until process exit.
 * It deliberately does NOT support unloading/reinitializing the native service. */
static struct {
  HANDLE wake, ready, done, set_gate, clear_gate, lock_gate, log_gate, init_gate;
  LONG initialized, closing, stopped, ready_flag, set_accepted, set_requested, clear_requested;
  LONG set_started, set_done, clear_started, clear_done, thread_exited, cleanup_called;
  LONG trace[16], trace_count, timeout_latched;
  LONG set_delay, clear_delay, log_hang, lock_hang, init_hang;
  LARGE_INTEGER frequency;
  LONGLONG deadline;
  volatile LONG64 completed_at;
  HWND private_window, base_window;
  LONG aware, notify, foreign_message, flood, handler_stall;
  LONG waiting, reentry_rejected, message_count, send_ok, foreign_ok, pump_calls;
} state;

#define FAKE_MESSAGE (WM_APP + 73)

/* This handler is bounded EXCEPT for the explicitly named diagnostic fault.
 * It takes no locks and never calls Node, JS or another window. */
static LRESULT CALLBACK private_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
  if (message == FAKE_MESSAGE) {
    InterlockedIncrement(&state.message_count);
    if (state.handler_stall) Sleep(2100);
    return 73;
  }
  return DefWindowProcW(window, message, w, l);
}

enum { SET_START = 1, SET_DONE, CLEAR_START, CLEAR_DONE, LOG_START, THREAD_EXIT };

static LONG read_flag(LONG *value) { return InterlockedCompareExchange(value, 0, 0); }
static LONGLONG ticks(void) { LARGE_INTEGER t; QueryPerformanceCounter(&t); return t.QuadPart; }
static void trace(LONG code) {
  /* Only the worker writes the trace. Publish each entry atomically for snapshots. */
  LONG index = read_flag(&state.trace_count);
  if (index < 16) {
    InterlockedExchange(&state.trace[index], code);
    InterlockedExchange(&state.trace_count, index + 1);
  }
}
static void fake_operation(LONG delay, HANDLE gate) {
  if (delay < 0) WaitForSingleObject(gate, INFINITE); /* Intentional fault, worker only. */
  else Sleep((DWORD)delay);
}
static DWORD WINAPI worker(void *unused) {
  (void)unused;
  if (state.init_hang) WaitForSingleObject(state.init_gate, INFINITE);
  InterlockedExchange(&state.ready_flag, 1);
  SetEvent(state.ready);
  for (;;) {
    WaitForSingleObject(state.wake, INFINITE);
    if (read_flag(&state.stopped)) break;
    if (InterlockedExchange(&state.set_requested, 0)) {
      InterlockedExchange(&state.set_started, 1);
      trace(SET_START);
      fake_operation(state.set_delay, state.set_gate);
      InterlockedExchange(&state.set_done, 1);
      trace(SET_DONE);
    }
    if (read_flag(&state.stopped)) break;
    if (InterlockedExchange(&state.clear_requested, 0)) {
      InterlockedExchange(&state.clear_started, 1);
      trace(CLEAR_START);
      if (state.foreign_message) {
        DWORD_PTR result = 0;
        InterlockedExchange(&state.foreign_ok, SendMessageTimeoutW(state.base_window, WM_CLOSE, 0, 0,
          SMTO_BLOCK | SMTO_ABORTIFHUNG, 3500, &result) != 0);
      }
      if (state.notify) {
        int count = state.flood ? 1000000 : 1;
        for (int i = 0; i < count && !read_flag(&state.stopped); ++i) {
          DWORD_PTR result = 0;
          LRESULT sent = SendMessageTimeoutW(state.private_window, FAKE_MESSAGE, 0, 0,
            SMTO_BLOCK | SMTO_ABORTIFHUNG, 3500, &result);
          InterlockedExchange(&state.send_ok, sent != 0 && result == 73);
          if (!sent) break;
        }
      }
      if (state.lock_hang) WaitForSingleObject(state.lock_gate, INFINITE);
      fake_operation(state.clear_delay, state.clear_gate);
      InterlockedExchange64(&state.completed_at, ticks());
      InterlockedExchange(&state.clear_done, 1);
      trace(CLEAR_DONE);
      SetEvent(state.done); /* No Node/JS call, even while JS is synchronously waiting. */
      trace(LOG_START);
      if (state.log_hang) WaitForSingleObject(state.log_gate, INFINITE);
    }
    if (read_flag(&state.stopped)) break;
  }
  trace(THREAD_EXIT);
  InterlockedExchange(&state.thread_exited, 1);
  return 0;
}
static void cleanup(void *unused) {
  (void)unused;
  InterlockedExchange(&state.cleanup_called, 1);
  InterlockedExchange(&state.closing, 1);
  InterlockedExchange(&state.stopped, 1);
  SetEvent(state.wake);
  /* Never join, unload, free active storage, or call Node from the native thread. */
}

static napi_value fail(napi_env env, const char *message) {
  napi_throw_error(env, NULL, message);
  return NULL;
}
static napi_value boolean(napi_env env, int value) {
  napi_value result; napi_get_boolean(env, value != 0, &result); return result;
}
static void number_property(napi_env env, napi_value result, const char *name, double value) {
  napi_value n; napi_create_double(env, value, &n); napi_set_named_property(env, result, name, n);
}
static napi_value snapshot(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result, events;
  napi_create_object(env, &result);
#define FIELD(name) number_property(env, result, #name, read_flag(&state.name))
  FIELD(closing); FIELD(ready_flag); FIELD(set_started); FIELD(set_done);
  FIELD(clear_started); FIELD(clear_done); FIELD(thread_exited); FIELD(cleanup_called);
  FIELD(timeout_latched);
  FIELD(waiting); FIELD(reentry_rejected); FIELD(message_count); FIELD(send_ok);
  FIELD(foreign_ok); FIELD(pump_calls);
#undef FIELD
  number_property(env, result, "deadlineTicks", (double)state.deadline);
  number_property(env, result, "completedTicks", (double)InterlockedCompareExchange64(&state.completed_at, 0, 0));
  napi_create_array(env, &events);
  LONG count = read_flag(&state.trace_count);
  for (LONG i = 0; i < count; ++i) {
    napi_value code; napi_create_int32(env, read_flag(&state.trace[i]), &code);
    napi_set_element(env, events, (uint32_t)i, code);
  }
  napi_set_named_property(env, result, "trace", events);
  return result;
}
static napi_value init(napi_env env, napi_callback_info info) {
  napi_value args[5]; size_t argc = 5; int32_t values[5];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc != 5) return fail(env, "init(setDelay, clearDelay, logHang, lockHang, initHang)");
  for (size_t i = 0; i < 5; ++i) {
    if (napi_get_value_int32(env, args[i], &values[i]) != napi_ok ||
        values[i] < (i < 2 ? -1 : 0) || values[i] > (i < 2 ? 10000 : 1))
      return fail(env, "invalid fault configuration");
  }
  if (InterlockedCompareExchange(&state.initialized, 1, 0)) return fail(env, "one init per process only");
  HMODULE module;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                         (LPCWSTR)&state, &module)) return fail(env, "module pin failed");
  if (!QueryPerformanceFrequency(&state.frequency)) return fail(env, "clock init failed");
  state.set_delay = values[0]; state.clear_delay = values[1]; state.log_hang = values[2];
  state.lock_hang = values[3]; state.init_hang = values[4];
#define EVENT(name, manual) state.name = CreateEventW(NULL, manual, FALSE, NULL); if (!state.name) return fail(env, "event init failed")
  EVENT(wake, FALSE); EVENT(ready, TRUE); EVENT(done, TRUE);
  EVENT(set_gate, TRUE); EVENT(clear_gate, TRUE); EVENT(lock_gate, TRUE);
  EVENT(log_gate, TRUE); EVENT(init_gate, TRUE);
#undef EVENT
  if (napi_add_env_cleanup_hook(env, cleanup, NULL) != napi_ok) return fail(env, "cleanup registration failed");
  HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
  if (!thread) return fail(env, "worker creation failed");
  CloseHandle(thread);
  DWORD wait = WaitForSingleObject(state.ready, 250);
  if (wait == WAIT_FAILED) return fail(env, "ready wait failed");
  return boolean(env, wait == WAIT_OBJECT_0);
}
static napi_value start_set(napi_env env, napi_callback_info info) {
  (void)info;
  if (!read_flag(&state.ready_flag) || read_flag(&state.closing)) return boolean(env, 0);
  if (InterlockedCompareExchange(&state.set_accepted, 1, 0)) return boolean(env, 0);
  InterlockedExchange(&state.set_requested, 1);
  SetEvent(state.wake);
  return boolean(env, 1);
}
static napi_value clear(napi_env env, napi_callback_info info) {
  napi_value arg; size_t argc = 1; bool force_early_timeout = false;
  napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
  if (argc && napi_get_value_bool(env, arg, &force_early_timeout) != napi_ok)
    return fail(env, "expected fake early-timeout boolean");
  if (!read_flag(&state.initialized)) return fail(env, "initialize first");
  if (InterlockedCompareExchange(&state.waiting, 1, 0)) {
    InterlockedIncrement(&state.reentry_rejected);
    napi_value result = snapshot(env, info);
    napi_set_named_property(env, result, "ok", boolean(env, 0));
    napi_set_named_property(env, result, "busy", boolean(env, 1));
    return result;
  }
  LONGLONG start = ticks();
  if (!state.deadline) {
    state.deadline = start + state.frequency.QuadPart * 3 / 2;
    InterlockedExchange(&state.closing, 1);
    InterlockedExchange(&state.clear_requested, 1);
    SetEvent(state.wake);
  }
  LONGLONG remaining = state.deadline - ticks();
  DWORD wait = WAIT_TIMEOUT;
  int did_wait = !read_flag(&state.timeout_latched) && read_flag(&state.ready_flag);
  if (did_wait) {
    DWORD milliseconds = remaining > 0 ? (DWORD)ceil((double)remaining * 1000 / state.frequency.QuadPart) : 0;
    if (force_early_timeout) wait = WAIT_TIMEOUT;
    else if (!state.aware) wait = WaitForSingleObject(state.done, milliseconds);
    else {
      for (;;) {
        remaining = state.deadline - ticks();
        if (remaining <= 0) { wait = WAIT_TIMEOUT; break; }
        milliseconds = (DWORD)ceil((double)remaining * 1000 / state.frequency.QuadPart);
        wait = MsgWaitForMultipleObjectsEx(1, &state.done, milliseconds, QS_SENDMESSAGE, MWMO_INPUTAVAILABLE);
        if (wait != WAIT_OBJECT_0 + 1) break;
        MSG message;
        InterlockedIncrement(&state.pump_calls);
        /* Important: HWND/message filters do NOT constrain dispatch of incoming SENT messages.
         * The foreign-window tests probe this known limitation; this is not a safe production pump. */
        PeekMessageW(&message, state.private_window, FAKE_MESSAGE, FAKE_MESSAGE, PM_NOREMOVE);
      }
    }
  }
  LONGLONG completed = InterlockedCompareExchange64(&state.completed_at, 0, 0);
  int ok = wait == WAIT_OBJECT_0 && completed && completed <= state.deadline && !read_flag(&state.timeout_latched);
  /* The OS wait clock can expire before the next QPC sample reaches our deadline. */
  if (!ok && ((did_wait && wait == WAIT_TIMEOUT) || ticks() >= state.deadline))
    InterlockedExchange(&state.timeout_latched, 1);
  InterlockedExchange(&state.waiting, 0);
  napi_value result = snapshot(env, info);
  napi_set_named_property(env, result, "ok", boolean(env, ok));
  napi_set_named_property(env, result, "uncertain", boolean(env, !ok));
  number_property(env, result, "waitCode", wait);
  number_property(env, result, "nativeMs", (double)(ticks() - start) * 1000 / state.frequency.QuadPart);
  return result;
}
static napi_value configure_window(napi_env env, napi_callback_info info) {
  napi_value args[6]; size_t argc = 6; void *data; size_t length; int32_t flags[5];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);
  if (argc != 6 || napi_get_buffer_info(env, args[0], &data, &length) != napi_ok || length != sizeof(HWND))
    return fail(env, "configureWindow(HWND buffer, aware, notify, foreign, flood, handlerStall)");
  if (read_flag(&state.initialized)) return fail(env, "configure window before init");
  for (int i = 0; i < 5; ++i)
    if (napi_get_value_int32(env, args[i + 1], &flags[i]) != napi_ok || flags[i] < 0 || flags[i] > 1)
      return fail(env, "invalid window fault flag");
  state.base_window = *(HWND *)data;
  if (GetWindowThreadProcessId(state.base_window, NULL) != GetCurrentThreadId())
    return fail(env, "BaseWindow must belong to this GUI thread");
  state.aware = flags[0]; state.notify = flags[1]; state.foreign_message = flags[2];
  state.flood = flags[3]; state.handler_stall = flags[4];
  WNDCLASSW cls = {0}; cls.lpfnWndProc = private_proc; cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"KuroDeadlinePrototypeOnly";
  if (!RegisterClassW(&cls)) return fail(env, "private class registration failed");
  /* Private message-only window is a TEST recipient, not a session-end receiver.
   * The hidden Electron BaseWindow remains the session-window stand-in. */
  state.private_window = CreateWindowExW(0, cls.lpszClassName, L"", 0, 0, 0, 0, 0,
    HWND_MESSAGE, NULL, cls.hInstance, NULL);
  if (!state.private_window) return fail(env, "private window creation failed");
  return boolean(env, 1);
}
static napi_value modules(napi_env env, napi_callback_info info) {
  (void)info;
  HANDLE handle = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
  if (handle == INVALID_HANDLE_VALUE) return fail(env, "module snapshot failed");
  MODULEENTRY32W entry = { .dwSize = sizeof entry };
  napi_value result; napi_create_array(env, &result); uint32_t index = 0;
  if (Module32FirstW(handle, &entry)) do {
    napi_value path;
    napi_create_string_utf16(env, (const char16_t *)entry.szExePath, NAPI_AUTO_LENGTH, &path);
    napi_set_element(env, result, index++, path);
  } while (Module32NextW(handle, &entry));
  CloseHandle(handle);
  return result;
}
static napi_value release(napi_env env, napi_callback_info info) {
  napi_value arg; size_t argc = 1; int32_t mask = 31;
  napi_get_cb_info(env, info, &argc, &arg, NULL, NULL);
  if (argc && (napi_get_value_int32(env, arg, &mask) != napi_ok || mask < 0 || mask > 31))
    return fail(env, "invalid gate mask");
  if (!read_flag(&state.initialized)) return fail(env, "initialize first");
  if (mask & 1) SetEvent(state.set_gate);
  if (mask & 2) SetEvent(state.clear_gate);
  if (mask & 4) SetEvent(state.lock_gate);
  if (mask & 8) SetEvent(state.log_gate);
  if (mask & 16) SetEvent(state.init_gate);
  return boolean(env, 1);
}
static napi_value exports_init(napi_env env, napi_value exports) {
  if (!load_bindings()) return NULL;
  napi_property_descriptor methods[] = {
    {"configureWindow", NULL, configure_window, NULL, NULL, NULL, napi_default, NULL},
    {"modules", NULL, modules, NULL, NULL, NULL, napi_default, NULL},
    {"init", NULL, init, NULL, NULL, NULL, napi_default, NULL},
    {"startSet", NULL, start_set, NULL, NULL, NULL, napi_default, NULL},
    {"clear", NULL, clear, NULL, NULL, NULL, napi_default, NULL},
    {"snapshot", NULL, snapshot, NULL, NULL, NULL, napi_default, NULL},
    {"release", NULL, release, NULL, NULL, NULL, napi_default, NULL}
  };
  napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, exports_init)
