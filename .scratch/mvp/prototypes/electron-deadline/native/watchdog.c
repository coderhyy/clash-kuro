/* Test-only supervisor. Never finds or kills processes by name. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static ULONG_PTR seen[256];
static int seen_count;
static unsigned long long epoch_ms(void) {
  FILETIME ft; GetSystemTimeAsFileTime(&ft); ULARGE_INTEGER epoch;
  epoch.LowPart = ft.dwLowDateTime; epoch.HighPart = ft.dwHighDateTime;
  return epoch.QuadPart / 10000 - 11644473600000ULL;
}
static DWORD active_count(HANDLE job) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
  if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof info, NULL)) return MAXDWORD;
  return info.ActiveProcesses;
}
static void record_members(HANDLE job) {
  BYTE bytes[sizeof(JOBOBJECT_BASIC_PROCESS_ID_LIST) + sizeof(ULONG_PTR) * 256];
  JOBOBJECT_BASIC_PROCESS_ID_LIST *list = (void *)bytes;
  if (!QueryInformationJobObject(job, JobObjectBasicProcessIdList, list, sizeof bytes, NULL)) return;
  for (DWORD i = 0; i < list->NumberOfProcessIdsInList; ++i) {
    int found = 0;
    for (int j = 0; j < seen_count; ++j) if (seen[j] == list->ProcessIdList[i]) found = 1;
    if (!found && seen_count < 256) seen[seen_count++] = list->ProcessIdList[i];
  }
}
int wmain(int argc, wchar_t **argv) {
  if (argc != 5) return 90; /* milliseconds, report, exe, complete quoted command line */
  DWORD budget = wcstoul(argv[1], NULL, 10);
  if (budget < 1000 || budget > 30000) return 91;
  HANDLE job = CreateJobObjectW(NULL, NULL);
  if (!job) return 92;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) return 93;
  STARTUPINFOW start = { .cb = sizeof start };
  PROCESS_INFORMATION process = {0};
  wchar_t *command = _wcsdup(argv[4]);
  if (!command || !CreateProcessW(argv[3], command, NULL, NULL, FALSE, CREATE_SUSPENDED,
                                NULL, NULL, &start, &process)) return 94;
  free(command);
  if (!AssignProcessToJobObject(job, process.hProcess)) {
    /* This exact process was created suspended by us; it cannot have children yet. */
    TerminateProcess(process.hProcess, 95);
    WaitForSingleObject(process.hProcess, 2000);
    return 95;
  }
  ULONGLONG began = GetTickCount64();
  int forced = 0, lingering = 0;
  if (ResumeThread(process.hThread) == (DWORD)-1) { TerminateJobObject(job, 96); return 96; }
  CloseHandle(process.hThread);
  for (;;) {
    record_members(job);
    if (WaitForSingleObject(process.hProcess, 10) == WAIT_OBJECT_0) break;
    if (GetTickCount64() - began >= budget) {
      forced = 1;
      TerminateJobObject(job, 124);
      WaitForSingleObject(process.hProcess, 2000);
      break;
    }
  }
  ULONGLONG root_end = GetTickCount64();
  unsigned long long root_epoch = epoch_ms();
  DWORD code = STILL_ACTIVE; GetExitCodeProcess(process.hProcess, &code);
  ULONGLONG until = GetTickCount64() + 1000;
  while (active_count(job) && GetTickCount64() < until) { record_members(job); Sleep(10); }
  DWORD remaining_before_kill = active_count(job);
  if (remaining_before_kill) {
    lingering = 1;
    TerminateJobObject(job, 125);
    until = GetTickCount64() + 2000;
    while (active_count(job) && GetTickCount64() < until) Sleep(10);
  }
  DWORD remaining = active_count(job);
  FILE *report = _wfopen(argv[2], L"wb");
  if (!report) return 97;
  fprintf(report, "{\"rootPid\":%lu,\"rootExitCode\":%lu,\"watchdogKilled\":%s,\"lingeringChildren\":%s,"
    "\"remainingBeforeKill\":%lu,\"remaining\":%lu,\"processMs\":%llu,\"rootExitEpochMs\":",
    process.dwProcessId, code, forced ? "true" : "false", lingering ? "true" : "false",
    remaining_before_kill, remaining, root_end - began);
  fprintf(report, "%llu,\"jobEmptyEpochMs\":%llu,\"observedPids\":[", root_epoch, epoch_ms());
  for (int i = 0; i < seen_count; ++i) fprintf(report, "%s%llu", i ? "," : "", (unsigned long long)seen[i]);
  fprintf(report, "]}\n"); fclose(report);
  CloseHandle(process.hProcess); CloseHandle(job);
  return forced || lingering || remaining || code != 0 ? 1 : 0;
}
