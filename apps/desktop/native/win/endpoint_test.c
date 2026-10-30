// Unit test for endpoint.h; built and run by `node scripts/build-sysproxy.mjs --test`.
#include <stdio.h>
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

  if (failures) return 1;
  puts("endpoint tests passed");
  return 0;
}
