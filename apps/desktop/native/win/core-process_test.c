#define WIN32_LEAN_AND_MEAN
#include "core-process.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int wmain(int argc, wchar_t **argv) {
  if (argc == 3 && !wcscmp(argv[1], L"--child")) {
    HANDLE ready = (HANDLE)(uintptr_t)_wcstoui64(argv[2], NULL, 10);
    if (ready) assert(SetEvent(ready));
    Sleep(INFINITE);
    return 90;
  }
  wchar_t exe[32768];
  assert(GetModuleFileNameW(NULL, exe, 32768));
  for (int resume = 0; resume != 2; ++resume) {
    HANDLE job = kuro_core_job(), other_job = kuro_core_job();
    assert(job && other_job);
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    HANDLE ready = CreateEventW(&sa, TRUE, FALSE, NULL);
    assert(ready);
    wchar_t command[33000], other_command[33000];
    _snwprintf(command, 33000, L"\"%ls\" --child %llu", exe, (unsigned long long)(uintptr_t)ready);
    _snwprintf(other_command, 33000, L"\"%ls\" --child 0", exe);
    PROCESS_INFORMATION core = {0}, other = {0};
    assert(kuro_create_core(job, exe, command, NULL, &ready, 1, &core));
    assert(kuro_create_core(other_job, exe, other_command, NULL, NULL, 0, &other));
    BOOL member = FALSE;
    assert(IsProcessInJob(core.hProcess, job, &member) && member);
    assert(IsProcessInJob(other.hProcess, job, &member) && !member);
    assert(ResumeThread(other.hThread) == 1);
    if (resume) {
      assert(ResumeThread(core.hThread) == 1);
      assert(WaitForSingleObject(ready, 3000) == WAIT_OBJECT_0);
    } else assert(WaitForSingleObject(ready, 0) == WAIT_TIMEOUT);
    /* Model helper death before handle publication, and after Core starts.
       If Core inherited the job handle, closing the parent's copy would not kill it. */
    assert(CloseHandle(job));
    assert(WaitForSingleObject(core.hProcess, 1000) == WAIT_OBJECT_0);
    assert(WaitForSingleObject(other.hProcess, 0) == WAIT_TIMEOUT);
    assert(CloseHandle(other_job));
    assert(WaitForSingleObject(other.hProcess, 1000) == WAIT_OBJECT_0);
    CloseHandle(core.hThread); CloseHandle(core.hProcess);
    CloseHandle(other.hThread); CloseHandle(other.hProcess); CloseHandle(ready);
  }
  HANDLE job = kuro_core_job();
  PROCESS_INFORMATION missing = {0};
  wchar_t command[] = L"missing";
  assert(!kuro_create_core(job, L"?:\\kuro-no-executable", command, NULL, NULL, 0, &missing));
  assert(!missing.hProcess && !missing.hThread && GetLastError() != ERROR_SUCCESS);
  CloseHandle(job);
  puts("core-process: atomic membership, suspended/running job loss, isolation, failed creation passed");
  return 0;
}
