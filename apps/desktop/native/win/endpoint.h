// Pure parsing helpers shared by kuro-sysproxy.c and its unit test; no Win32 calls here.
#ifndef KURO_ENDPOINT_H
#define KURO_ENDPOINT_H

#include <stddef.h>
#include <wchar.h>
#include <wctype.h>

// Returns 1 only when every endpoint in a WinINet ProxyServer value equals `expected` exactly.
// Accepts "host:port" and "scheme=host:port;scheme=host:port". Anything else (other endpoints,
// URLs, whitespace-separated lists, empty values) returns 0 so the caller keeps the setting.
static int kuro_all_endpoints_equal(const wchar_t *server, const wchar_t *expected) {
  if (!server || !expected || !*expected) return 0;
  size_t expected_len = wcslen(expected);
  int count = 0;
  const wchar_t *p = server;
  for (;;) {
    const wchar_t *end = wcschr(p, L';');
    const wchar_t *s = p;
    const wchar_t *e = end ? end : p + wcslen(p);
    while (s < e && iswspace(*s)) s++;
    while (e > s && iswspace(e[-1])) e--;
    if (s < e) {
      const wchar_t *value = s;
      for (const wchar_t *q = s; q < e; q++) {
        if (*q == L'=') { value = q + 1; break; }
      }
      if (value != s) {
        if (value - 1 == s) return 0;
        for (const wchar_t *q = s; q < value - 1; q++) if (!iswalpha(*q)) return 0;
      }
      if ((size_t)(e - value) != expected_len || wcsncmp(value, expected, expected_len) != 0) return 0;
      count++;
    }
    if (!end) break;
    p = end + 1;
  }
  return count > 0;
}

// host is an IPv4/IPv6 literal or DNS name; no separators WinINet would interpret.
static int kuro_valid_host(const wchar_t *host) {
  size_t len = host ? wcslen(host) : 0;
  if (len == 0 || len > 253) return 0;
  for (size_t i = 0; i < len; i++) {
    wchar_t c = host[i];
    if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9')
          || c == L'.' || c == L'-' || c == L':' || c == L'[' || c == L']')) return 0;
  }
  return 1;
}

// Decimal 1..65535 without sign, spaces or leading zeros; returns 0 when invalid.
static unsigned kuro_parse_port(const wchar_t *text) {
  if (!text || !*text || *text == L'0') return 0;
  unsigned value = 0;
  for (const wchar_t *p = text; *p; p++) {
    if (*p < L'0' || *p > L'9') return 0;
    value = value * 10 + (unsigned)(*p - L'0');
    if (value > 65535) return 0;
  }
  return value;
}

// "host:port" as written by `set`; splits at the last colon.
static int kuro_valid_server(const wchar_t *server) {
  if (!server) return 0;
  const wchar_t *colon = wcsrchr(server, L':');
  if (!colon || colon == server || (size_t)(colon - server) > 253) return 0;
  wchar_t host[256];
  wmemcpy(host, server, (size_t)(colon - server));
  host[colon - server] = 0;
  return kuro_valid_host(host) && kuro_parse_port(colon + 1) != 0;
}

// Bypass list: printable, bounded, no control characters.
static int kuro_valid_bypass(const wchar_t *bypass) {
  size_t len = bypass ? wcslen(bypass) : 0;
  if (len > 4096) return 0;
  for (size_t i = 0; i < len; i++) if (bypass[i] < 0x20 || bypass[i] == 0x7f) return 0;
  return 1;
}

// RunOnce command line: "<exe>" clear --expected-server <server>. The exe path is quoted because
// it may contain spaces ("Clash Kuro"). Returns the length, or 0 when the path holds a quote or the
// result would not fit in `cap` characters including the terminator (Run/RunOnce ignore > 260).
static size_t kuro_runonce_command(wchar_t *out, size_t cap, const wchar_t *exe, const wchar_t *server) {
  static const wchar_t middle[] = L"\" clear --expected-server ";
  if (!out || !exe || !*exe || !server || !*server || wcschr(exe, L'"')) return 0;
  size_t exe_len = wcslen(exe), middle_len = sizeof middle / sizeof *middle - 1, server_len = wcslen(server);
  size_t len = 1 + exe_len + middle_len + server_len;
  if (len + 1 > cap) return 0;
  out[0] = L'"';
  wmemcpy(out + 1, exe, exe_len);
  wmemcpy(out + 1 + exe_len, middle, middle_len);
  wmemcpy(out + 1 + exe_len + middle_len, server, server_len);
  out[len] = 0;
  return len;
}

#endif
