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

// --log path: drive-absolute ("C:\..."), no quotes or control characters, and short enough that
// "<path>.1" (the rotated copy) still fits in MAX_PATH (260).
static int kuro_valid_log_path(const wchar_t *path) {
  size_t len = path ? wcslen(path) : 0;
  if (len < 4 || len > 255) return 0;
  if (!((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' || path[2] != L'\\') return 0;
  for (size_t i = 0; i < len; i++) if (path[i] < 0x20 || path[i] == L'"' || path[i] == 0x7f) return 0;
  return path[len - 1] != L'\\';
}

static size_t kuro_append(wchar_t *out, size_t at, const wchar_t *s) {
  size_t n = wcslen(s);
  wmemcpy(out + at, s, n);
  return at + n;
}

// RunOnce command line: "<exe>" clear --expected-server <server> [--log "<log>"]. Paths are quoted
// because they may contain spaces ("Clash Kuro"). `log` may be NULL. Returns the length, or 0 when a
// path holds a quote or the result would not fit in `cap` characters including the terminator
// (Run/RunOnce ignore command lines longer than 260).
static size_t kuro_runonce_command(wchar_t *out, size_t cap, const wchar_t *exe, const wchar_t *server, const wchar_t *log) {
  static const wchar_t middle[] = L"\" clear --expected-server ";
  static const wchar_t log_option[] = L" --log \"";
  if (!out || !exe || !*exe || !server || !*server || wcschr(exe, L'"')) return 0;
  if (log && (!*log || wcschr(log, L'"'))) return 0;
  size_t len = 1 + wcslen(exe) + wcslen(middle) + wcslen(server);
  if (log) len += wcslen(log_option) + wcslen(log) + 1;
  if (len + 1 > cap) return 0;
  size_t at = kuro_append(out, 0, L"\"");
  at = kuro_append(out, at, exe);
  at = kuro_append(out, at, middle);
  at = kuro_append(out, at, server);
  if (log) {
    at = kuro_append(out, at, log_option);
    at = kuro_append(out, at, log);
    at = kuro_append(out, at, L"\"");
  }
  out[at] = 0;
  return at;
}

#endif
