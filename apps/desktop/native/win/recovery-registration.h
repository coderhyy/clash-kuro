#ifndef KURO_RECOVERY_REGISTRATION_H
#define KURO_RECOVERY_REGISTRATION_H
#define KURO_RECOVERY_VALUE L"ClashKuroResidentCleanup"
static DWORD kuro_recovery_paths(wchar_t *exe, wchar_t *journal) {
  DWORD size = GetModuleFileNameW(NULL, exe, MAX_PATH);
  if (!size || size >= MAX_PATH) return ERROR_FILENAME_EXCED_RANGE;
  wcscpy(journal, exe);
  wchar_t *slash = wcsrchr(journal, L'\\');
  if (!slash || (size_t)(slash - journal) + 14 >= MAX_PATH) return ERROR_FILENAME_EXCED_RANGE;
  wcscpy(slash + 1, L"recovery.bin");
  return ERROR_SUCCESS;
}
static inline DWORD kuro_recovery_put_command(const wchar_t *exe, const wchar_t *verb) {
  wchar_t command[MAX_PATH];
  if (!kuro_valid_log_path(exe) || wcslen(exe) + wcslen(verb) + 4 > MAX_PATH) return ERROR_FILENAME_EXCED_RANGE;
  _snwprintf(command, MAX_PATH, L"\"%ls\" %ls", exe, verb);
  HKEY key;
  LSTATUS result = RegCreateKeyExW(HKEY_CURRENT_USER, RUNONCE_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
  if (result != ERROR_SUCCESS) return (DWORD)result;
  result = RegSetValueExW(key, KURO_RECOVERY_VALUE, 0, REG_SZ, (const BYTE *)command,
    (DWORD)((wcslen(command) + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return (DWORD)result;
}
static inline DWORD kuro_recovery_register(const wchar_t *path) {
  wchar_t exe[MAX_PATH], journal[MAX_PATH], canonical[MAX_PATH];
  DWORD error = kuro_recovery_paths(exe, journal);
  if (error) return error;
  DWORD size = GetFullPathNameW(path, MAX_PATH, canonical, NULL);
  if (!size || size >= MAX_PATH || _wcsicmp(journal, canonical)) return ERROR_INVALID_PARAMETER;
  // The copied immutable executable finds its journal beside itself, keeping RunOnce below 260 characters.
  if (wcslen(exe) + 11 >= MAX_PATH) return ERROR_FILENAME_EXCED_RANGE;
  return kuro_recovery_put_command(exe, L"recover");
}
/* exe is the native-verified retained helper, never a CLI-selected recovery root. */
static inline DWORD kuro_recovery_register_admitted(const wchar_t *exe) {
  return kuro_recovery_put_command(exe, L"recover-admitted");
}
static inline DWORD kuro_recovery_unregister(void) {
  HKEY key;
  LSTATUS result = RegOpenKeyExW(HKEY_CURRENT_USER, RUNONCE_KEY, 0, KEY_SET_VALUE, &key);
  if (result == ERROR_FILE_NOT_FOUND) return ERROR_SUCCESS;
  if (result != ERROR_SUCCESS) return (DWORD)result;
  result = RegDeleteValueW(key, KURO_RECOVERY_VALUE);
  RegCloseKey(key);
  return result == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : (DWORD)result;
}
#endif
