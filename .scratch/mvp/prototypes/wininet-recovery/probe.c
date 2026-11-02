/* Isolated real-WinINet experiment. Shares the shipping operations, never changes RunOnce. */
#define wmain shipping_cli_main
#include "../../../../apps/desktop/native/win/kuro-sysproxy.c"
#undef wmain
#include <assert.h>

#define MAX_BACKUP (8 * 1024 * 1024)
#define TEST_BYPASS L"localhost;127.0.0.1;[::1]"
static const char magic[8] = { 'K', 'S', 'P', 'B', '0', '0', '0', '1' };
typedef struct { ConnState *rows; DWORD count; } Backup;
static void bytes(Buf *b, const void *p, size_t n) { put(b, p, n); }
static void word(Buf *b, DWORD n) { bytes(b, &n, sizeof n); }
static int text(Buf *b, const wchar_t *s) {
  if (!s) { word(b, MAXDWORD); return 1; }
  size_t length = wcslen(s);
  if (length > 32767) return 0;
  word(b, (DWORD)length); bytes(b, s, length * sizeof *s); return 1;
}
static int snapshot(const wchar_t *path) {
  Connections c = connections();
  if (c.rasError || c.count > 256) return usage(L"Incomplete connection enumeration; no snapshot created");
  Buf b = {0}; bytes(&b, magic, sizeof magic); word(&b, c.count);
  for (DWORD i = 0; i < c.count; ++i) {
    ConnState st = {0};
    if (query(c.names[i], &st)) return usage(L"Connection query failed; no snapshot created");
    word(&b, st.flags);
    if (!text(&b, st.name) || !text(&b, st.server) || !text(&b, st.bypass) || !text(&b, st.pac))
      return usage(L"Snapshot field too large");
    release(&st);
  }
  bytes(&b, magic, sizeof magic); /* Complete-file marker rejects interrupted backups. */
  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return usage(L"Cannot create new snapshot file");
  DWORD written;
  int ok = b.len <= MAX_BACKUP && WriteFile(file, b.data, (DWORD)b.len, &written, NULL) &&
    written == b.len && FlushFileBuffers(file);
  CloseHandle(file); free(b.data); free(c.names); free(c.ras);
  if (!ok) return usage(L"Incomplete snapshot: do not write proxy settings");
  return cmd_get();
}
static int read_word(const BYTE **at, const BYTE *end, DWORD *value) {
  if ((size_t)(end - *at) < sizeof *value) return 0;
  memcpy(value, *at, sizeof *value); *at += sizeof *value; return 1;
}
static int read_text(const BYTE **at, const BYTE *end, wchar_t **value) {
  DWORD n;
  if (!read_word(at, end, &n)) return 0;
  if (n == MAXDWORD) { *value = NULL; return 1; }
  if (n > 32767 || (size_t)(end - *at) < n * sizeof(wchar_t)) return 0;
  *value = calloc(n + 1, sizeof(wchar_t));
  if (!*value) return 0;
  memcpy(*value, *at, n * sizeof(wchar_t)); *at += n * sizeof(wchar_t);
  return wcslen(*value) == n;
}
static int load_backup(const wchar_t *path, Backup *backup) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if (file == INVALID_HANDLE_VALUE) return 0;
  LARGE_INTEGER size;
  if (!GetFileSizeEx(file, &size) || size.QuadPart < 20 || size.QuadPart > MAX_BACKUP) { CloseHandle(file); return 0; }
  BYTE *buffer = malloc((size_t)size.QuadPart); DWORD got;
  int ok = buffer && ReadFile(file, buffer, (DWORD)size.QuadPart, &got, NULL) && got == size.QuadPart;
  CloseHandle(file);
  if (!ok || memcmp(buffer, magic, 8) || memcmp(buffer + size.QuadPart - 8, magic, 8)) { free(buffer); return 0; }
  const BYTE *at = buffer + 8, *end = buffer + size.QuadPart - 8;
  if (!read_word(&at, end, &backup->count) || !backup->count || backup->count > 256) { free(buffer); return 0; }
  backup->rows = calloc(backup->count, sizeof *backup->rows);
  if (!backup->rows) { free(buffer); return 0; }
  for (DWORD i = 0; i < backup->count; ++i) {
    ConnState *s = &backup->rows[i]; wchar_t *name;
    if (!read_word(&at, end, &s->flags) || !read_text(&at, end, &name) ||
        !read_text(&at, end, &s->server) || !read_text(&at, end, &s->bypass) || !read_text(&at, end, &s->pac)) {
      free(buffer); return 0;
    }
    s->name = name;
    if ((i == 0) != (name == NULL)) { free(buffer); return 0; }
  }
  ok = at == end; free(buffer); return ok;
}
static int equal_text(const wchar_t *a, const wchar_t *b) { return !wcscmp(a ? a : L"", b ? b : L""); }
static int equal_state(const ConnState *a, const ConnState *b) {
  return a->flags == b->flags && equal_text(a->server, b->server) &&
    equal_text(a->bypass, b->bypass) && equal_text(a->pac, b->pac);
}
static int allowed_current(const ConnState *now, const ConnState *saved, const wchar_t *endpoint) {
  if (equal_state(now, saved)) return 1;
  return endpoint && (now->flags == 1 || now->flags == 3) && equal_text(now->server, endpoint) &&
    equal_text(now->bypass, TEST_BYPASS) && equal_text(now->pac, saved->pac);
}
static int preflight(const Backup *backup, const wchar_t *endpoint) {
  Connections c = connections(); int ok = !c.rasError && c.count == backup->count;
  for (DWORD i = 0; ok && i < c.count; ++i) {
    ConnState now = {0}; const ConnState *saved = &backup->rows[i];
    ok = equal_text(c.names[i], saved->name) && !query(saved->name, &now) && allowed_current(&now, saved, endpoint);
    release(&now);
  }
  free(c.names); free(c.ras); return ok;
}
static int restore(const Backup *backup, const wchar_t *endpoint) {
  if (!preflight(backup, endpoint)) return usage(L"STOP: settings or connection list changed outside this fixture; no restore writes made");
  int ok = 1; Buf report = {0};
  for (DWORD i = 0; i < backup->count; ++i) {
    const ConnState *saved = &backup->rows[i]; ConnState now = {0};
    if (query(saved->name, &now) || !allowed_current(&now, saved, endpoint)) {
      release(&now); return usage(L"STOP: concurrent change detected during restore; keep the backup");
    }
    int unchanged = equal_state(&now, saved); release(&now);
    if (unchanged) continue;
    INTERNET_PER_CONN_OPTIONW options[4] = {0};
    options[0].dwOption = INTERNET_PER_CONN_FLAGS; options[0].Value.dwValue = saved->flags;
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER; options[1].Value.pszValue = saved->server ? saved->server : L"";
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS; options[2].Value.pszValue = saved->bypass ? saved->bypass : L"";
    options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL; options[3].Value.pszValue = saved->pac ? saved->pac : L"";
    if (write_options(saved->name, options, 4)) { ok = 0; break; }
  }
  puts_(&report, "{\"command\":\"restore\""); notify(&report, &ok);
  if (!preflight(backup, NULL)) ok = 0;
  putf(&report, ",\"ok\":%s}", ok ? "true" : "false"); emit(&report); free(report.data);
  return ok ? 0 : 2;
}
static int verify_fixture(const Backup *backup, const wchar_t *endpoint, DWORD flags) {
  if (!preflight(backup, endpoint)) return 0;
  for (DWORD i = 0; i < backup->count; ++i) {
    ConnState now = {0};
    int ok = !query(backup->rows[i].name, &now) && now.flags == flags &&
      equal_text(now.server, endpoint) && equal_text(now.bypass, TEST_BYPASS) &&
      equal_text(now.pac, backup->rows[i].pac);
    release(&now);
    if (!ok) return 0;
  }
  return 1;
}
int wmain(int argc, wchar_t **argv) {
  if (argc == 2 && !wcscmp(argv[1], L"self-test")) {
    ConnState base = { NULL, 9, L"other:3128", L"baseline", L"http://example.invalid/a.pac" };
    ConnState now = base;
    assert(allowed_current(&now, &base, NULL));
    now.flags = 3; now.server = L"127.0.0.1:48967"; now.bypass = TEST_BYPASS;
    assert(allowed_current(&now, &base, L"127.0.0.1:48967"));
    assert(!allowed_current(&now, &base, NULL));
    now.flags = 1; assert(allowed_current(&now, &base, L"127.0.0.1:48967"));
    now.flags = 5; assert(!allowed_current(&now, &base, L"127.0.0.1:48967"));
    now.flags = 3; now.pac = L"changed"; assert(!allowed_current(&now, &base, L"127.0.0.1:48967"));
    now.pac = base.pac; now.server = L"someone-else:48967";
    assert(!allowed_current(&now, &base, L"127.0.0.1:48967"));
    return 0;
  }
  if (argc == 2 && !wcscmp(argv[1], L"get")) return cmd_get();
  if (argc == 3 && !wcscmp(argv[1], L"snapshot")) return snapshot(argv[2]);
  if (argc < 3 || argc > 4) return usage(L"snapshot FILE | verify FILE | cycle FILE ENDPOINT | restore FILE ENDPOINT");
  Backup backup = {0};
  if (!load_backup(argv[2], &backup)) return usage(L"Invalid or incomplete snapshot");
  if (argc == 3 && !wcscmp(argv[1], L"verify")) {
    if (!preflight(&backup, NULL)) return usage(L"Snapshot does not match current LAN/RAS settings");
    return cmd_get();
  }
  if (argc != 4 || wcsncmp(argv[3], L"127.0.0.1:", 10) || !kuro_valid_server(argv[3])) return usage(L"Expected a loopback test endpoint");
  if (!wcscmp(argv[1], L"restore")) return restore(&backup, argv[3]);
  if (wcscmp(argv[1], L"cycle") || !preflight(&backup, NULL)) return usage(L"STOP: baseline changed before experiment");
  // Restoration is a SEPARATE supervised invocation, only after this writer's Job is empty.
  ULONGLONG started = GetTickCount64();
  if (set_connections(argv[3], TEST_BYPASS, 0)) return 2;
  ULONGLONG set_ms = GetTickCount64() - started;
  if (!verify_fixture(&backup, argv[3], 3)) return usage(L"Set returned success but queried fixture state differs");
  const wchar_t *expected[] = { argv[3] };
  started = GetTickCount64();
  if (clear_connections(expected, 1, 0)) return 2;
  ULONGLONG clear_ms = GetTickCount64() - started;
  if (!verify_fixture(&backup, argv[3], 1)) return usage(L"Clear returned success but queried fixture state differs");
  Buf report = {0};
  putf(&report, "{\"command\":\"cycle-verified\",\"connections\":%lu,\"setFlags\":3,\"clearFlags\":1,"
    "\"setMs\":%llu,\"clearMs\":%llu}", backup.count, set_ms, clear_ms);
  emit(&report); free(report.data);
  return 0;
}
