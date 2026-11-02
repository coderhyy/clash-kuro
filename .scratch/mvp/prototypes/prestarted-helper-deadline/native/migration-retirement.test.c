/* Retained failure reproducer, not an acceptance test or production dependency. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>

static HKEY outside;
static int race;
static void late_writer(void) {
  if (race) assert(RegSetValueExW(outside, L"Owned", 0, REG_SZ,
    (const BYTE *)L"newer", sizeof L"newer") == ERROR_SUCCESS);
}
#define KURO_RETIRE_AFTER_COMPARE late_writer
#include "migration-retirement.h"

int wmain(void) {
  wchar_t path[160], value[32]; DWORD disposition, type, bytes;
  _snwprintf(path, 160, L"Software\\ClashKuroTests\\MigrationRetirement-%lu", GetCurrentProcessId());
  assert(RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &outside, &disposition) == ERROR_SUCCESS);
  assert(disposition == REG_CREATED_NEW_KEY);
  assert(RegSetValueExW(outside, L"Other", 0, REG_SZ, (const BYTE *)L"keep", sizeof L"keep") == ERROR_SUCCESS);
  assert(RegSetValueExW(outside, L"Owned", 0, REG_SZ, (const BYTE *)L"old", sizeof L"old") == ERROR_SUCCESS);
  DWORD result = kuro_retire_legacy(path, L"Owned", L"different");
  fprintf(stderr, "mismatch result=%lu\n", result);
  assert(result == ERROR_INVALID_DATA);
  assert(kuro_retire_legacy(path, L"Missing", L"old") == ERROR_FILE_NOT_FOUND);
  race = 1;
  assert(kuro_retire_legacy(path, L"Owned", L"old") != ERROR_SUCCESS);
  bytes = sizeof value;
  assert(RegQueryValueExW(outside, L"Owned", NULL, &type, (BYTE *)value, &bytes) == ERROR_SUCCESS && !wcscmp(value, L"newer"));
  race = 0;
  assert(kuro_retire_legacy(path, L"Owned", L"newer") == ERROR_SUCCESS);
  bytes = sizeof value;
  assert(RegQueryValueExW(outside, L"Owned", NULL, &type, (BYTE *)value, &bytes) == ERROR_FILE_NOT_FOUND);
  assert(RegQueryValueExW(outside, L"Other", NULL, &type, (BYTE *)value, &bytes) == ERROR_SUCCESS && !wcscmp(value, L"keep"));
  RegCloseKey(outside);
  assert(RegDeleteKeyW(HKEY_CURRENT_USER, path) == ERROR_SUCCESS);
  puts("Exact retirement: mismatch/missing/conflicting writer/success; private registry only");
  return 0;
}
