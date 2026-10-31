// Unit test for endpoint.h; built and run by `node scripts/build-sysproxy.mjs --test`.
#include <stdio.h>
#include <wchar.h>
#include "endpoint.h"

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #expr); failures++; } } while (0)

int main(void) {
  const wchar_t *ours = L"127.0.0.1:7890";
  CHECK(kuro_all_endpoints_equal(L"127.0.0.1:7890", ours));
  CHECK(kuro_all_endpoints_equal(L"http=127.0.0.1:7890;https=127.0.0.1:7890", ours));
  CHECK(kuro_all_endpoints_equal(L" http=127.0.0.1:7890 ; socks=127.0.0.1:7890 ;", ours));
  CHECK(!kuro_all_endpoints_equal(L"http=127.0.0.1:7890;https=corp.proxy:8080", ours));
  CHECK(!kuro_all_endpoints_equal(L"127.0.0.1:7891", ours));
  CHECK(!kuro_all_endpoints_equal(L"127.0.0.1:78900", ours));
  CHECK(!kuro_all_endpoints_equal(L"localhost:7890", ours));
  CHECK(!kuro_all_endpoints_equal(L"http://127.0.0.1:7890", ours));
  CHECK(!kuro_all_endpoints_equal(L"http=127.0.0.1:7890 https=127.0.0.1:7890", ours));
  CHECK(!kuro_all_endpoints_equal(L"=127.0.0.1:7890", ours));
  CHECK(!kuro_all_endpoints_equal(L"h2t=127.0.0.1:7890", ours));
  CHECK(!kuro_all_endpoints_equal(L"", ours));
  CHECK(!kuro_all_endpoints_equal(L";;", ours));
  CHECK(!kuro_all_endpoints_equal(NULL, ours));

  CHECK(kuro_valid_host(L"127.0.0.1"));
  CHECK(kuro_valid_host(L"[::1]"));
  CHECK(!kuro_valid_host(L"a;b"));
  CHECK(!kuro_valid_host(L"a b"));
  CHECK(!kuro_valid_host(L"http=a"));
  CHECK(!kuro_valid_host(L""));

  CHECK(kuro_parse_port(L"1") == 1);
  CHECK(kuro_parse_port(L"65535") == 65535);
  CHECK(kuro_parse_port(L"65536") == 0);
  CHECK(kuro_parse_port(L"0") == 0);
  CHECK(kuro_parse_port(L"07890") == 0);
  CHECK(kuro_parse_port(L"-1") == 0);
  CHECK(kuro_parse_port(L"99999999999") == 0);

  CHECK(kuro_valid_server(L"127.0.0.1:7890"));
  CHECK(!kuro_valid_server(L"127.0.0.1"));
  CHECK(!kuro_valid_server(L":7890"));
  CHECK(!kuro_valid_server(L"127.0.0.1:0"));

  CHECK(kuro_valid_bypass(L"localhost;127.0.0.1;::1;<local>"));
  CHECK(kuro_valid_bypass(L""));
  CHECK(!kuro_valid_bypass(L"a\nb"));

  {
    wchar_t cmd[260];
    const wchar_t *exe = L"C:\\Program Files\\Clash Kuro\\resources\\bin\\kuro-sysproxy.exe";
    size_t n = kuro_runonce_command(cmd, 260, exe, L"127.0.0.1:7891", NULL);
    CHECK(n == wcslen(cmd));
    CHECK(!wcscmp(cmd, L"\"C:\\Program Files\\Clash Kuro\\resources\\bin\\kuro-sysproxy.exe\" clear --expected-server 127.0.0.1:7891"));
    CHECK(kuro_runonce_command(cmd, 260, L"C:\\a\"b.exe", L"127.0.0.1:7891", NULL) == 0);
    CHECK(kuro_runonce_command(cmd, 260, L"", L"127.0.0.1:7891", NULL) == 0);
    CHECK(kuro_runonce_command(cmd, 260, exe, L"", NULL) == 0);
    // Exactly fits (len + terminator == cap), then one character too long.
    size_t need = n + 1;
    CHECK(kuro_runonce_command(cmd, need, exe, L"127.0.0.1:7891", NULL) == n);
    CHECK(kuro_runonce_command(cmd, need - 1, exe, L"127.0.0.1:7891", NULL) == 0);
    wchar_t longexe[300];
    for (int i = 0; i < 299; i++) longexe[i] = L'a';
    longexe[299] = 0;
    CHECK(kuro_runonce_command(cmd, 260, longexe, L"127.0.0.1:7891", NULL) == 0);

    // With --log: both paths quoted, spaces kept.
    const wchar_t *log = L"C:\\Users\\A B\\AppData\\Roaming\\Clash Kuro\\data\\runonce.log";
    n = kuro_runonce_command(cmd, 260, exe, L"127.0.0.1:7891", log);
    CHECK(n == wcslen(cmd));
    CHECK(!wcscmp(cmd, L"\"C:\\Program Files\\Clash Kuro\\resources\\bin\\kuro-sysproxy.exe\" clear --expected-server 127.0.0.1:7891"
                       L" --log \"C:\\Users\\A B\\AppData\\Roaming\\Clash Kuro\\data\\runonce.log\""));
    CHECK(kuro_runonce_command(cmd, n + 1, exe, L"127.0.0.1:7891", log) == n);
    CHECK(kuro_runonce_command(cmd, n, exe, L"127.0.0.1:7891", log) == 0);
    CHECK(kuro_runonce_command(cmd, 260, exe, L"127.0.0.1:7891", L"C:\\a\"b.log") == 0);
    CHECK(kuro_runonce_command(cmd, 260, exe, L"127.0.0.1:7891", L"") == 0);
  }

  CHECK(kuro_valid_log_path(L"C:\\Users\\A B\\AppData\\Roaming\\Clash Kuro\\data\\runonce.log"));
  CHECK(kuro_valid_log_path(L"d:\\x.log"));
  CHECK(!kuro_valid_log_path(L"runonce.log"));
  CHECK(!kuro_valid_log_path(L"\\\\server\\share\\x.log"));
  CHECK(!kuro_valid_log_path(L"C:x.log"));
  CHECK(!kuro_valid_log_path(L"C:\\a\"b.log"));
  CHECK(!kuro_valid_log_path(L"C:\\a\nb.log"));
  CHECK(!kuro_valid_log_path(L"C:\\dir\\"));
  CHECK(!kuro_valid_log_path(L""));
  CHECK(!kuro_valid_log_path(NULL));
  {
    wchar_t longlog[300];
    wcscpy(longlog, L"C:\\");
    for (int i = 3; i < 256; i++) longlog[i] = L'a';
    longlog[256] = 0;
    CHECK(!kuro_valid_log_path(longlog));
    longlog[255] = 0;
    CHECK(kuro_valid_log_path(longlog));
  }

  if (failures) return 1;
  puts("endpoint tests passed");
  return 0;
}
