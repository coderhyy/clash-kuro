/* Only private kernel objects and exact test children. No proxy/RunOnce APIs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <wchar.h>

static wchar_t test_prefix[128], test_name[384];
static DWORD create_error;
static unsigned creates;
static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name);
#define KURO_RESIDENT_OWNER_TEST
#include "resident-owner.h"

static HANDLE kuro_resident_owner_test_mutex(LPSECURITY_ATTRIBUTES sa, BOOL initial, LPCWSTR name) {
  wchar_t sid[KURO_RESIDENT_OWNER_SID_CHARS], expected[256];
  assert(!kuro_resident_current_sid(sid, KURO_RESIDENT_OWNER_SID_CHARS));
  _snwprintf(expected, 256, L"Global\\ClashKuro.ProxyOwner.%ls", sid);
  assert(!wcscmp(name, expected) && !sa && initial);
  static const wchar_t prefix[] = L"Local\\ClashKuro.ProxyOwner.Test.";
  assert(!wcsncmp(test_prefix, prefix, wcslen(prefix)));
  assert(wcsspn(test_prefix + wcslen(prefix), L"0123456789.") == wcslen(test_prefix) - wcslen(prefix));
  assert(_snwprintf(test_name, 384, L"%ls%ls", test_prefix, sid) > 0);
  ++creates;
  if (create_error) { SetLastError(create_error); return NULL; }
  return CreateMutexW(sa, initial, test_name);
}

/* Test-only release; production keeps ownership/handle until process exit. */
static HANDLE release_owner(void) {
  HANDLE mutex = kuro_resident_owner_handle;
  assert(mutex && ReleaseMutex(mutex));
  kuro_resident_owner_handle = NULL;
  InterlockedExchange(&kuro_resident_owner_claimed, 0);
  return mutex;
}

static DWORD WINAPI duplicate_thread(void *unused) {
  (void)unused;
  BOOL abandoned = TRUE;
  assert(kuro_resident_owner_acquire(&abandoned) == ERROR_BUSY && !abandoned);
  return 0;
}

static DWORD WINAPI watchdog(void *finished) {
  if (WaitForSingleObject((HANDLE)finished, 8000) != WAIT_OBJECT_0)
    TerminateProcess(GetCurrentProcess(), 98);
  return 0;
}

static void child(const wchar_t *mode, DWORD expected_code) {
  wchar_t exe[32768], command[33000];
  DWORD length = GetModuleFileNameW(NULL, exe, 32768);
  assert(length && length < 32768);
  assert(_snwprintf(command, 33000, L"\"%ls\" %ls %ls", exe, mode, test_prefix) > 0);
  STARTUPINFOW startup = {0}; startup.cb = sizeof startup;
  PROCESS_INFORMATION process = {0};
  assert(CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process));
  DWORD waited = WaitForSingleObject(process.hProcess, 2000);
  if (waited != WAIT_OBJECT_0) {
    TerminateProcess(process.hProcess, 97);
    WaitForSingleObject(process.hProcess, 1000);
  }
  assert(waited == WAIT_OBJECT_0); /* Any watchdog/rescue is a failure. */
  DWORD code;
  assert(GetExitCodeProcess(process.hProcess, &code) && code == expected_code);
  CloseHandle(process.hThread); CloseHandle(process.hProcess);
}

static void identity_and_root(void) {
  wchar_t sid[KURO_RESIDENT_OWNER_SID_CHARS], root[32768], again[32768], small[1] = {L'x'};
  assert(kuro_resident_current_sid(NULL, 1) == ERROR_INVALID_PARAMETER);
  assert(kuro_resident_current_sid(small, 0) == ERROR_INVALID_PARAMETER);
  assert(kuro_resident_current_sid(small, 1) == ERROR_INSUFFICIENT_BUFFER && !small[0]);
  assert(!kuro_resident_current_sid(sid, KURO_RESIDENT_OWNER_SID_CHARS));
  HANDLE token;
  struct { TOKEN_USER user; BYTE sid[SECURITY_MAX_SID_SIZE]; } info;
  DWORD bytes;
  PSID parsed;
  assert(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token));
  assert(GetTokenInformation(token, TokenUser, &info, sizeof info, &bytes));
  assert(ConvertStringSidToSidW(sid, &parsed) && EqualSid(parsed, info.user.User.Sid));
  LocalFree(parsed); CloseHandle(token);

  assert(kuro_resident_recovery_root(NULL, 1) == ERROR_INVALID_PARAMETER);
  assert(kuro_resident_recovery_root(small, 0) == ERROR_INVALID_PARAMETER);
  small[0] = L'x';
  assert(kuro_resident_recovery_root(small, 1) == ERROR_INSUFFICIENT_BUFFER && !small[0]);
  assert(!kuro_resident_recovery_root(root, 32768));
  wchar_t *local;
  assert(SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DONT_VERIFY, NULL, &local)));
  assert(_snwprintf(again, 32768, L"%ls\\ClashKuro\\Recovery", local) > 0);
  CoTaskMemFree(local);
  assert(!wcscmp(root, again));
  size_t capacity = wcslen(root) + 1;
  assert(!kuro_resident_recovery_root(again, capacity) && !wcscmp(root, again));
  assert(kuro_resident_recovery_root(again, capacity - 1) == ERROR_INSUFFICIENT_BUFFER && !again[0]);

  wchar_t saved_env[32768], saved_cwd[32768], system[32768];
  DWORD env_length = GetEnvironmentVariableW(L"LOCALAPPDATA", saved_env, 32768);
  assert(env_length < 32768);
  assert(GetCurrentDirectoryW(32768, saved_cwd) && GetSystemDirectoryW(system, 32768));
  assert(SetEnvironmentVariableW(L"LOCALAPPDATA", L"Z:\\kuro-owner-test-not-real"));
  assert(SetCurrentDirectoryW(system));
  assert(!kuro_resident_recovery_root(again, 32768) && !wcscmp(root, again));
  assert(!kuro_resident_current_sid(again, 32768) && !wcscmp(sid, again));
  assert(SetCurrentDirectoryW(saved_cwd));
  assert(SetEnvironmentVariableW(L"LOCALAPPDATA", env_length ? saved_env : NULL));
}

int wmain(int argc, wchar_t **argv) {
  if (argc == 3) {
    assert(wcslen(argv[2]) < 128);
    wcscpy(test_prefix, argv[2]);
    BOOL abandoned = TRUE;
    DWORD error = kuro_resident_owner_acquire(&abandoned);
    if (!wcscmp(argv[1], L"--contend")) {
      assert(error == ERROR_BUSY && !abandoned && !kuro_resident_owner_handle);
      return 0;
    }
    assert(!error && !abandoned);
    if (!wcscmp(argv[1], L"--abandon")) {
      TerminateProcess(GetCurrentProcess(), 17);
      return 99;
    }
    assert(!wcscmp(argv[1], L"--release"));
    CloseHandle(release_owner());
    return 0;
  }
  assert(argc == 1);
  /* Children automatically join this private job. Parent death/assert/watchdog
     closes its sole handle, killing exact descendants without PID/name scans. */
  HANDLE job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  assert(job && SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits));
  assert(AssignProcessToJobObject(job, GetCurrentProcess()));
  HANDLE finished = CreateEventW(NULL, TRUE, FALSE, NULL);
  HANDLE watch = CreateThread(NULL, 0, watchdog, finished, 0, NULL);
  assert(finished && watch);
  assert(_snwprintf(test_prefix, 128, L"Local\\ClashKuro.ProxyOwner.Test.%lu.%llu.",
    GetCurrentProcessId(), (unsigned long long)GetTickCount64()) > 0);
  identity_and_root();

  BOOL abandoned = TRUE;
  assert(kuro_resident_owner_acquire(NULL) == ERROR_INVALID_PARAMETER);
  for (unsigned i = 0; i < 2; ++i) {
    create_error = i ? ERROR_NOT_ENOUGH_MEMORY : ERROR_ACCESS_DENIED;
    assert(kuro_resident_owner_acquire(&abandoned) == create_error && !abandoned);
    assert(!kuro_resident_owner_handle && !kuro_resident_owner_claimed);
  }
  create_error = 0;
  HANDLE conflict = CreateEventW(NULL, TRUE, FALSE, test_name);
  assert(conflict);
  assert(kuro_resident_owner_acquire(&abandoned) == ERROR_INVALID_HANDLE && !abandoned);
  assert(!kuro_resident_owner_handle && !kuro_resident_owner_claimed);
  CloseHandle(conflict);

  PSECURITY_DESCRIPTOR descriptor;
  assert(ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(D;;GA;;;WD)",
    SDDL_REVISION_1, &descriptor, NULL));
  SECURITY_ATTRIBUTES sa = { sizeof sa, descriptor, FALSE };
  HANDLE denied = CreateMutexW(&sa, FALSE, test_name);
  assert(denied);
  assert(kuro_resident_owner_acquire(&abandoned) == ERROR_ACCESS_DENIED && !abandoned);
  assert(!kuro_resident_owner_handle && !kuro_resident_owner_claimed);
  CloseHandle(denied); LocalFree(descriptor);

  assert(!kuro_resident_owner_acquire(&abandoned) && !abandoned);
  DWORD flags;
  assert(GetHandleInformation(kuro_resident_owner_handle, &flags) && !(flags & HANDLE_FLAG_INHERIT));
  unsigned before = creates;
  abandoned = TRUE;
  assert(kuro_resident_owner_acquire(&abandoned) == ERROR_BUSY && !abandoned);
  HANDLE thread = CreateThread(NULL, 0, duplicate_thread, NULL, 0, NULL);
  assert(thread && WaitForSingleObject(thread, 1000) == WAIT_OBJECT_0);
  CloseHandle(thread);
  assert(creates == before); /* No recursive Win32 acquisition on either thread. */
  child(L"--contend", 0);

  HANDLE keeper = release_owner();
  child(L"--release", 0); /* Existing, unowned object: not initial ownership. */
  assert(!kuro_resident_owner_acquire(&abandoned) && !abandoned);
  CloseHandle(release_owner());
  child(L"--abandon", 17);
  assert(!kuro_resident_owner_acquire(&abandoned) && abandoned);
  child(L"--contend", 0); /* Abandoned acquisition is still exclusive. */
  assert(kuro_resident_owner_acquire(&abandoned) == ERROR_BUSY && !abandoned);
  CloseHandle(release_owner()); CloseHandle(keeper);
  assert(!kuro_resident_owner_acquire(&abandoned) && !abandoned);
  /* Leave the last successful owner held through process exit, as in production. */
  assert(SetEvent(finished) && WaitForSingleObject(watch, 1000) == WAIT_OBJECT_0);
  CloseHandle(watch); CloseHandle(finished);
  puts("resident owner: native SID/root, failures, nonrecursive/cross-process exclusion, release/abandon passed");
  return 0;
}
