/* Real journal replay under the existing backup/restore harness; no registry writes. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static DWORD no_registration(const wchar_t *path) { (void)path; return ERROR_ACCESS_DENIED; }
static DWORD no_unregister(void) { return ERROR_SUCCESS; }
#define KURO_RECOVERY_REGISTER no_registration
#define KURO_RECOVERY_UNREGISTER no_unregister
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"

int wmain(int argc, wchar_t **argv) {
  if (argc != 6 || wcscmp(argv[1], L"resident-cycle") || wcscmp(argv[5], L"recover")) return 1;
  Backup backup = {0};
  if (!load_backup(argv[2], &backup) || !preflight(&backup, NULL)) return 2;
  if (wcscmp(argv[3], L"127.0.0.1:48967")) return 2;
  wchar_t journal[MAX_PATH];
  if (wcslen(argv[4]) + 5 >= MAX_PATH) return 2;
  _snwprintf(journal, MAX_PATH, L"%ls.bin", argv[4]);
  HANDLE owned = kuro_recovery_lock(journal);
  if (owned == INVALID_HANDLE_VALUE) return 2;
  DWORD error = kuro_recovery_admit(owned, argv[3]);
  CloseHandle(owned);
  if (error || set_connections(argv[3], TEST_BYPASS, 0) || !verify_fixture(&backup, argv[3], 3)) return 2;
  wchar_t *args[] = { argv[0], L"recover", L"--recovery", journal, L"--log", argv[4] };
  int result = resident_main(6, args);
  if (result || !verify_fixture(&backup, argv[3], 1)) return 2;
  KuroRecoveryState state;
  if (kuro_recovery_read(resident.recovery, &state) || state.count) return 2;
  g_capture = NULL; g_log = NULL;
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1}", backup.count);
  emit(&report); free(report.data);
  return 0;
}
