/* Rejected experiment: local HKCU TxR returns ERROR_RM_NOT_ACTIVE. Not shipping. */
#ifndef KURO_MIGRATION_RETIREMENT_H
#define KURO_MIGRATION_RETIREMENT_H
#include <ktmw32.h>

#ifndef KURO_RETIRE_AFTER_COMPARE
#define KURO_RETIRE_AFTER_COMPARE() ((void)0)
#endif

/* A non-transacted legacy writer must abort this comparison/deletion, not lose its newer value. */
static DWORD kuro_retire_legacy(const wchar_t *key_path, const wchar_t *value_name, const wchar_t *expected) {
  size_t length = wcslen(expected);
  if (!length || length >= 260) return ERROR_INVALID_PARAMETER;
  HANDLE transaction = CreateTransaction(NULL, NULL, 0, 0, 0, 2000, L"Kuro exact legacy retirement");
  if (transaction == INVALID_HANDLE_VALUE) return GetLastError();
  HKEY key = NULL;
  DWORD error = RegOpenKeyTransactedW(HKEY_CURRENT_USER, key_path, 0, KEY_QUERY_VALUE | KEY_SET_VALUE,
    &key, transaction, NULL);
  if (!error) {
    wchar_t current[260]; DWORD type = 0, bytes = sizeof current;
    error = RegQueryValueExW(key, value_name, NULL, &type, (BYTE *)current, &bytes);
    if (!error && (type != REG_SZ || bytes != (length + 1) * sizeof(wchar_t) ||
        memcmp(current, expected, bytes))) error = ERROR_INVALID_DATA;
    if (!error) {
      KURO_RETIRE_AFTER_COMPARE();
      error = RegDeleteValueW(key, value_name);
    }
    if (!error && !CommitTransaction(transaction)) error = GetLastError();
    RegCloseKey(key);
  }
  CloseHandle(transaction); /* An uncommitted transaction rolls back; no unsafe fallback. */
  return error;
}
#endif
