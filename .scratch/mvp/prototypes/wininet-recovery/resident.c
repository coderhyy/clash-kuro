/* Isolated bridge: real shared WinINet clear in the existing helper coordination model. */
#define KURO_BACKUP_MAIN backup_probe_main
#include "probe.c"

static const wchar_t *real_endpoint;
static ULONGLONG real_clear_ms;
static int real_clear(void) {
  const wchar_t *expected[] = { real_endpoint };
  ULONGLONG started = GetTickCount64();
  int result = clear_connections(expected, 1, 0);
  real_clear_ms = GetTickCount64() - started;
  return result;
}
#define KURO_REAL_OPERATION real_clear
#define KURO_AUTO_QUERY 1
#define KURO_COORDINATION_MAIN coordination_main
#include "../prestarted-helper-deadline/native/helper.c"

int wmain(int argc, wchar_t **argv) {
  if (argc == 5 && !wcscmp(argv[1], L"--core")) return coordination_main(argc, argv);
  if (argc != 6 || wcscmp(argv[1], L"resident-cycle") ||
      (wcscmp(argv[5], L"plain") && wcscmp(argv[5], L"aware")))
    return usage(L"resident-cycle BACKUP ENDPOINT REPORT plain|aware");
  Backup backup = {0};
  if (!load_backup(argv[2], &backup) || !preflight(&backup, NULL))
    return usage(L"STOP: invalid backup or changed baseline");
  if (wcscmp(argv[3], L"127.0.0.1:48967")) return usage(L"Only the isolated fixture endpoint is allowed");
  real_endpoint = argv[3];
  ULONGLONG started = GetTickCount64();
  if (set_connections(real_endpoint, TEST_BYPASS, 0)) return 2;
  ULONGLONG set_ms = GetTickCount64() - started;
  if (!verify_fixture(&backup, real_endpoint, 3)) return usage(L"Set state verification failed");
  wchar_t *args[] = { argv[0], !wcscmp(argv[5], L"plain") ? L"real-plain" : L"real-aware", argv[4] };
  int result = coordination_main(3, args);
  if (result) return result;
  if (!verify_fixture(&backup, real_endpoint, 1)) return usage(L"Resident clear state verification failed");
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1,"
    "\"setMs\":%llu,\"clearMs\":%llu}", backup.count, set_ms, real_clear_ms);
  emit(&report); free(report.data);
  return 0;
}
