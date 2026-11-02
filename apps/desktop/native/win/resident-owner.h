#ifndef KURO_RESIDENT_OWNER_H
#define KURO_RESIDENT_OWNER_H
#include <windows.h>
#include <sddl.h>
#include <shlobj.h>
#include <wchar.h>

/* Link Advapi32, Shell32, Ole32 and Uuid; no privileged helper is required. */
#define KURO_RESIDENT_OWNER_SID_CHARS 184

/* Include in one translation unit. These APIs run on the non-impersonating main
   thread, whose process token identifies the owner. Capacities are wchar_t counts.
   Helpers return ERROR_SUCCESS or a Win32 error; a writable output is empty on error. */
static inline DWORD kuro_resident_current_sid(wchar_t *out, size_t cap) {
  if (!out || !cap) return ERROR_INVALID_PARAMETER;
  out[0] = 0;
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return GetLastError();
  struct { TOKEN_USER user; BYTE sid[SECURITY_MAX_SID_SIZE]; } info;
  DWORD bytes;
  BOOL ok = GetTokenInformation(token, TokenUser, &info, sizeof info, &bytes);
  DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  CloseHandle(token);
  if (error) return error;
  wchar_t *sid = NULL;
  if (!ConvertSidToStringSidW(info.user.User.Sid, &sid)) return GetLastError();
  size_t length = wcslen(sid);
  if (length >= cap) error = ERROR_INSUFFICIENT_BUFFER;
  else wmemcpy(out, sid, length + 1);
  LocalFree(sid);
  return error;
}

/* Resolve only: no directory creation, environment/CLI root, or executable-relative
   fallback. This fixed path is shared by future reservation/replay/serve callers.
   It does not validate filesystem contents, ACLs, or reparse points. */
static inline DWORD kuro_resident_recovery_root(wchar_t *out, size_t cap) {
  if (!out || !cap) return ERROR_INVALID_PARAMETER;
  out[0] = 0;
  wchar_t *local = NULL;
  HRESULT result = SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DONT_VERIFY, NULL, &local);
  if (FAILED(result)) {
    CoTaskMemFree(local);
    return HRESULT_FACILITY(result) == FACILITY_WIN32 ? HRESULT_CODE(result) : ERROR_GEN_FAILURE;
  }
  static const wchar_t suffix[] = L"\\ClashKuro\\Recovery";
  size_t length = wcslen(local);
  while (length && local[length - 1] == L'\\') --length;
  DWORD error = ERROR_SUCCESS;
  if (length < 3 || local[1] != L':' || local[2] != L'\\') error = ERROR_BAD_PATHNAME;
  else if (length >= cap || (sizeof suffix / sizeof *suffix) > cap - length)
    error = ERROR_INSUFFICIENT_BUFFER;
  else {
    wmemcpy(out, local, length);
    wmemcpy(out + length, suffix, sizeof suffix / sizeof *suffix);
  }
  CoTaskMemFree(local);
  return error;
}

static volatile LONG kuro_resident_owner_claimed;
static HANDLE kuro_resident_owner_handle;

/* ERROR_SUCCESS means exclusive ownership; *abandoned distinguishes WAIT_ABANDONED.
   Neither ordinary nor abandoned acquisition proves clean recovery state/admission.
   ERROR_BUSY means contention (including this process/thread acquiring twice).
   Any other Win32 error denies ownership, including access/creation/wait errors.
   No retries: the only wait is zero. This bounds policy, not kernel/API latency.
   Keep the main thread alive and this non-inheritable handle until process exit;
   there is deliberately no production release/transfer API or local fallback. */
static inline DWORD kuro_resident_owner_acquire(BOOL *abandoned) {
  if (!abandoned) return ERROR_INVALID_PARAMETER;
  *abandoned = FALSE;
  /* Win32 mutexes are recursive, even through a newly opened handle. */
  if (InterlockedCompareExchange(&kuro_resident_owner_claimed, 1, 0)) return ERROR_BUSY;
  wchar_t sid[KURO_RESIDENT_OWNER_SID_CHARS], name[256];
  DWORD error = kuro_resident_current_sid(sid, KURO_RESIDENT_OWNER_SID_CHARS);
  HANDLE mutex = NULL;
  if (!error) {
    wcscpy(name, L"Global\\ClashKuro.ProxyOwner.");
    wcscat(name, sid);
    SetLastError(ERROR_SUCCESS);
#ifdef KURO_RESIDENT_OWNER_TEST
    /* The unit test always redirects creation to its private namespace. */
    mutex = kuro_resident_owner_test_mutex(NULL, TRUE, name);
#else
    mutex = CreateMutexW(NULL, TRUE, name);
#endif
    error = GetLastError();
    if (mutex) {
      /* Initial ownership is granted only for a newly created object. */
      DWORD waited = error == ERROR_ALREADY_EXISTS ? WaitForSingleObject(mutex, 0) : WAIT_OBJECT_0;
      if (waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED) {
        kuro_resident_owner_handle = mutex;
        *abandoned = waited == WAIT_ABANDONED;
        return ERROR_SUCCESS;
      }
      error = waited == WAIT_TIMEOUT ? ERROR_BUSY : GetLastError();
      CloseHandle(mutex);
    }
  }
  InterlockedExchange(&kuro_resident_owner_claimed, 0);
  return error;
}
#endif
