#ifndef KURO_CORE_PROCESS_H
#define KURO_CORE_PROCESS_H
#include <windows.h>

/* The helper alone owns this handle. Never inherit or duplicate it into Core. */
static HANDLE kuro_core_job(void) {
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return NULL;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) {
    DWORD error = GetLastError();
    CloseHandle(job); SetLastError(error); return NULL;
  }
  return job;
}

/* Atomic job admission closes the create-then-assign orphan window (Windows 10+).
   Return suspended: publish the exact process handle before allowing Core to run.
   The caller must keep job alive through creation; on failure, never fall back to PID lookup. */
static BOOL kuro_create_core(HANDLE job, const wchar_t *exe, wchar_t *command,
    const wchar_t *cwd, HANDLE *inherited, SIZE_T inherited_count, PROCESS_INFORMATION *process) {
  if (!job || !exe || !command || !process || (inherited_count && !inherited)) {
    SetLastError(ERROR_INVALID_PARAMETER); return FALSE;
  }
  ZeroMemory(process, sizeof *process);
  SIZE_T size = 0;
  DWORD count = inherited_count ? 2 : 1;
  InitializeProcThreadAttributeList(NULL, count, 0, &size);
  STARTUPINFOEXW si = {0}; si.StartupInfo.cb = sizeof si;
  si.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, size);
  if (!si.lpAttributeList) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE; }
  BOOL initialized = InitializeProcThreadAttributeList(si.lpAttributeList, count, 0, &size);
  BOOL ok = initialized && UpdateProcThreadAttribute(si.lpAttributeList, 0,
    PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof job, NULL, NULL);
  if (ok && inherited_count) ok = UpdateProcThreadAttribute(si.lpAttributeList, 0,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, inherited_count * sizeof(HANDLE), NULL, NULL);
  if (ok) ok = CreateProcessW(exe, command, NULL, NULL, inherited_count != 0,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED,
    NULL, cwd, &si.StartupInfo, process);
  DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
  HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
  SetLastError(error);
  return ok;
}
#endif
