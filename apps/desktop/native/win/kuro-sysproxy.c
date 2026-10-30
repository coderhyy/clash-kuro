// kuro-sysproxy: per-user WinINet System Proxy helper for Clash Kuro (issue 08, ADR-0011).
//
//   kuro-sysproxy get
//   kuro-sysproxy set --host <host> --port <port> [--bypass <a;b;c>]
//   kuro-sysproxy clear --expected-server <host:port> [--expected-server ...]
//
// Applies to the LAN settings (pszConnection = NULL) and every RAS/VPN phonebook entry.
// Prints one UTF-8 JSON object on stdout. Exit codes: 0 all succeeded, 1 usage error,
// 2 at least one connection or the change notification failed.
// Runs as the calling user; never elevates, never writes the registry directly.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <raserror.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "endpoint.h"

#ifndef INTERNET_PER_CONN_FLAGS_UI
#define INTERNET_PER_CONN_FLAGS_UI 10
#endif

#define MAX_EXPECTED 8

// ---- JSON output -------------------------------------------------------------------------

typedef struct { char *data; size_t len, cap; } Buf;

static void put(Buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 1024;
    while (b->len + n + 1 > cap) cap *= 2;
    char *next = realloc(b->data, cap);
    if (!next) ExitProcess(3);
    b->data = next;
    b->cap = cap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void puts_(Buf *b, const char *s) { put(b, s, strlen(s)); }

static void putf(Buf *b, const char *fmt, ...) {
  char tmp[128];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n > 0) put(b, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
}

static void put_json_string(Buf *b, const wchar_t *w) {
  if (!w) { puts_(b, "null"); return; }
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  char *utf8 = n > 0 ? malloc((size_t)n) : NULL;
  if (!utf8 || !WideCharToMultiByte(CP_UTF8, 0, w, -1, utf8, n, NULL, NULL)) {
    free(utf8);
    puts_(b, "null");
    return;
  }
  puts_(b, "\"");
  for (const unsigned char *p = (const unsigned char *)utf8; *p; p++) {
    if (*p == '"') puts_(b, "\\\"");
    else if (*p == '\\') puts_(b, "\\\\");
    else if (*p < 0x20) putf(b, "\\u%04x", *p);
    else put(b, (const char *)p, 1);
  }
  puts_(b, "\"");
  free(utf8);
}

static void put_error(Buf *b, DWORD code, const wchar_t *fallback) {
  wchar_t *message = NULL;
  if (code) {
    // WinINet codes (12000-12999) live in wininet.dll's message table.
    HMODULE wininet = GetModuleHandleW(L"wininet.dll");
    DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS
      | (wininet && code >= 12000 && code < 13000 ? FORMAT_MESSAGE_FROM_HMODULE : 0);
    FormatMessageW(flags, wininet, code, 0, (LPWSTR)&message, 0, NULL);
    if (message) {
      size_t len = wcslen(message);
      while (len && (message[len - 1] == L'\r' || message[len - 1] == L'\n' || message[len - 1] == L' ')) message[--len] = 0;
    }
  }
  putf(b, "{\"code\":%lu,\"message\":", (unsigned long)code);
  put_json_string(b, message && *message ? message : fallback ? fallback : L"Unknown error");
  puts_(b, "}");
  if (message) LocalFree(message);
}

static void emit(Buf *b) {
  puts_(b, "\n");
  HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD written;
  for (size_t done = 0; done < b->len; done += written) {
    if (!WriteFile(out, b->data + done, (DWORD)(b->len - done), &written, NULL) || !written) break;
  }
}

static int usage(const wchar_t *message) {
  Buf b = {0};
  putf(&b, "{\"ok\":false,\"error\":{\"code\":%lu,\"message\":", (unsigned long)ERROR_INVALID_PARAMETER);
  put_json_string(&b, message);
  puts_(&b, "}}");
  emit(&b);
  return 1;
}

// ---- Connections -------------------------------------------------------------------------

typedef struct {
  const wchar_t *name; // NULL = LAN
  DWORD flags;
  wchar_t *server, *bypass, *pac;
} ConnState;

static wchar_t *take(LPWSTR value) {
  if (!value) return NULL;
  wchar_t *copy = _wcsdup(value);
  GlobalFree(value);
  return copy;
}

static void release(ConnState *st) {
  free(st->server);
  free(st->bypass);
  free(st->pac);
  st->server = st->bypass = st->pac = NULL;
}

static DWORD query(const wchar_t *name, ConnState *st) {
  INTERNET_PER_CONN_OPTIONW opt[4] = {0};
  opt[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  opt[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  opt[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  opt[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LISTW list = { sizeof list, (LPWSTR)name, 4, 0, opt };
  DWORD size = sizeof list;
  // FLAGS_UI (Windows 7+) reports the auto-detect bit as the user set it; fall back for older stacks.
  if (!InternetQueryOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) {
    opt[0].dwOption = INTERNET_PER_CONN_FLAGS;
    size = sizeof list;
    if (!InternetQueryOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size)) return GetLastError();
  }
  st->name = name;
  st->flags = opt[0].Value.dwValue;
  st->server = take(opt[1].Value.pszValue);
  st->bypass = take(opt[2].Value.pszValue);
  st->pac = take(opt[3].Value.pszValue);
  return ERROR_SUCCESS;
}

static DWORD write_options(const wchar_t *name, INTERNET_PER_CONN_OPTIONW *opt, DWORD count) {
  INTERNET_PER_CONN_OPTION_LISTW list = { sizeof list, (LPWSTR)name, count, 0, opt };
  return InternetSetOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof list) ? ERROR_SUCCESS : GetLastError();
}

// LAN first, then every RAS phonebook entry visible to this user (user + AllUsers phonebooks).
typedef struct { const wchar_t **names; DWORD count; RASENTRYNAMEW *ras; DWORD rasError; } Connections;

static Connections connections(void) {
  Connections c = {0};
  DWORD cb = sizeof(RASENTRYNAMEW), n = 0;
  RASENTRYNAMEW *entries = calloc(1, cb);
  if (entries) {
    entries[0].dwSize = sizeof(RASENTRYNAMEW);
    DWORD r = RasEnumEntriesW(NULL, NULL, entries, &cb, &n);
    if (r == ERROR_BUFFER_TOO_SMALL) {
      free(entries);
      entries = calloc(1, cb);
      if (entries) {
        entries[0].dwSize = sizeof(RASENTRYNAMEW);
        r = RasEnumEntriesW(NULL, NULL, entries, &cb, &n);
      } else r = ERROR_NOT_ENOUGH_MEMORY;
    }
    if (r != ERROR_SUCCESS) { c.rasError = r; n = 0; }
  } else c.rasError = ERROR_NOT_ENOUGH_MEMORY;
  c.ras = entries;
  c.names = calloc(n + 1, sizeof *c.names);
  if (!c.names) ExitProcess(3);
  c.names[c.count++] = NULL;
  for (DWORD i = 0; i < n; i++) c.names[c.count++] = entries[i].szEntryName;
  return c;
}

static void put_connection_name(Buf *b, const wchar_t *name) {
  puts_(b, "{\"name\":");
  put_json_string(b, name);
}

// Tell running WinINet clients to re-read proxy settings (75 -> 95 -> 37).
static void notify(Buf *b, int *ok) {
  DWORD error = ERROR_SUCCESS;
  if (!InternetSetOptionW(NULL, INTERNET_OPTION_PROXY_SETTINGS_CHANGED, NULL, 0)) error = GetLastError();
  if (!InternetSetOptionW(NULL, INTERNET_OPTION_REFRESH, NULL, 0) && !error) error = GetLastError();
  if (error) {
    *ok = 0;
    puts_(b, ",\"notifyError\":");
    put_error(b, error, NULL);
  }
}

static void finish(Buf *b, const Connections *c, int ok) {
  if (c->rasError) {
    puts_(b, ",\"rasError\":");
    put_error(b, c->rasError, NULL);
  }
  putf(b, ",\"ok\":%s}", ok ? "true" : "false");
}

// ---- Commands ----------------------------------------------------------------------------

static int cmd_get(void) {
  Connections c = connections();
  Buf b = {0};
  int ok = 1;
  puts_(&b, "{\"command\":\"get\",\"connections\":[");
  for (DWORD i = 0; i < c.count; i++) {
    if (i) puts_(&b, ",");
    put_connection_name(&b, c.names[i]);
    ConnState st = {0};
    DWORD error = query(c.names[i], &st);
    if (error) {
      ok = 0;
      puts_(&b, ",\"error\":");
      put_error(&b, error, NULL);
    } else {
      putf(&b, ",\"flags\":%lu,\"proxyServer\":", (unsigned long)st.flags);
      put_json_string(&b, st.server);
      puts_(&b, ",\"bypass\":");
      put_json_string(&b, st.bypass);
      puts_(&b, ",\"autoConfigUrl\":");
      put_json_string(&b, st.pac);
    }
    puts_(&b, "}");
    release(&st);
  }
  puts_(&b, "]");
  finish(&b, &c, ok);
  emit(&b);
  return ok ? 0 : 2;
}

static int cmd_set(const wchar_t *server, const wchar_t *bypass) {
  Connections c = connections();
  Buf b = {0};
  int ok = 1;
  puts_(&b, "{\"command\":\"set\",\"connections\":[");
  for (DWORD i = 0; i < c.count; i++) {
    if (i) puts_(&b, ",");
    put_connection_name(&b, c.names[i]);
    INTERNET_PER_CONN_OPTIONW opt[3] = {0};
    // Manual proxy only: auto-detect/PAC would take precedence, so they are turned off (URL kept).
    opt[0].dwOption = INTERNET_PER_CONN_FLAGS;
    opt[0].Value.dwValue = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
    opt[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    opt[1].Value.pszValue = (LPWSTR)server;
    opt[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    opt[2].Value.pszValue = (LPWSTR)bypass;
    DWORD error = write_options(c.names[i], opt, 3);
    ConnState st = {0};
    // Read back: a policy or another agent may silently override what we wrote.
    if (!error && !(error = query(c.names[i], &st))
        && (!(st.flags & PROXY_TYPE_PROXY) || !st.server || wcscmp(st.server, server) != 0)) {
      ok = 0;
      puts_(&b, ",\"status\":\"error\",\"error\":");
      put_error(&b, 0, L"Proxy setting did not persist (read back differs); it may be locked by policy");
    } else if (error) {
      ok = 0;
      puts_(&b, ",\"status\":\"error\",\"error\":");
      put_error(&b, error, NULL);
    } else puts_(&b, ",\"status\":\"set\"");
    puts_(&b, "}");
    release(&st);
  }
  puts_(&b, "]");
  notify(&b, &ok);
  finish(&b, &c, ok);
  emit(&b);
  return ok ? 0 : 2;
}

static int cmd_clear(const wchar_t **expected, int expected_count) {
  Connections c = connections();
  Buf b = {0};
  int ok = 1, changed = 0;
  puts_(&b, "{\"command\":\"clear\",\"connections\":[");
  for (DWORD i = 0; i < c.count; i++) {
    if (i) puts_(&b, ",");
    put_connection_name(&b, c.names[i]);
    ConnState st = {0};
    DWORD error = query(c.names[i], &st);
    int ours = 0;
    for (int e = 0; !error && e < expected_count && !ours; e++) ours = kuro_all_endpoints_equal(st.server, expected[e]);
    if (error) {
      ok = 0;
      puts_(&b, ",\"status\":\"error\",\"error\":");
      put_error(&b, error, NULL);
    } else if (!(st.flags & PROXY_TYPE_PROXY)) {
      puts_(&b, ",\"status\":\"unchanged\"");
    } else if (!ours) {
      puts_(&b, ",\"status\":\"notOurs\"");
    } else {
      // Only drop the manual-proxy bit; PAC/WPAD flags, server string and bypass stay as they are.
      INTERNET_PER_CONN_OPTIONW opt[1] = {0};
      opt[0].dwOption = INTERNET_PER_CONN_FLAGS;
      opt[0].Value.dwValue = (st.flags & ~(DWORD)PROXY_TYPE_PROXY) | PROXY_TYPE_DIRECT;
      error = write_options(c.names[i], opt, 1);
      ConnState after = {0};
      if (!error && !(error = query(c.names[i], &after)) && (after.flags & PROXY_TYPE_PROXY)) {
        ok = 0;
        puts_(&b, ",\"status\":\"error\",\"error\":");
        put_error(&b, 0, L"Manual proxy is still enabled after clearing; it may be locked by policy");
      } else if (error) {
        ok = 0;
        puts_(&b, ",\"status\":\"error\",\"error\":");
        put_error(&b, error, NULL);
      } else puts_(&b, ",\"status\":\"cleared\"");
      changed = 1;
      release(&after);
    }
    puts_(&b, "}");
    release(&st);
  }
  puts_(&b, "]");
  if (changed) notify(&b, &ok);
  finish(&b, &c, ok);
  emit(&b);
  return ok ? 0 : 2;
}

int wmain(int argc, wchar_t **argv) {
  if (argc < 2) return usage(L"Usage: kuro-sysproxy get | set --host H --port P [--bypass B] | clear --expected-server H:P");
  const wchar_t *command = argv[1], *host = NULL, *port = NULL, *bypass = L"";
  const wchar_t *expected[MAX_EXPECTED];
  int expected_count = 0;
  for (int i = 2; i < argc; i += 2) {
    if (i + 1 >= argc) return usage(L"Missing option value");
    if (!wcscmp(argv[i], L"--host") && !host) host = argv[i + 1];
    else if (!wcscmp(argv[i], L"--port") && !port) port = argv[i + 1];
    else if (!wcscmp(argv[i], L"--bypass")) bypass = argv[i + 1];
    else if (!wcscmp(argv[i], L"--expected-server") && expected_count < MAX_EXPECTED) expected[expected_count++] = argv[i + 1];
    else return usage(L"Unknown, repeated or excess option");
  }
  if (!wcscmp(command, L"get")) {
    if (argc != 2) return usage(L"get takes no options");
    return cmd_get();
  }
  if (!wcscmp(command, L"set")) {
    if (!host || !port || expected_count) return usage(L"set requires --host and --port");
    if (!kuro_valid_host(host)) return usage(L"Invalid --host");
    unsigned p = kuro_parse_port(port);
    if (!p) return usage(L"Invalid --port: expected 1-65535");
    if (!kuro_valid_bypass(bypass)) return usage(L"Invalid --bypass");
    wchar_t server[300];
    _snwprintf(server, sizeof server / sizeof *server, L"%ls:%u", host, p);
    server[299] = 0;
    return cmd_set(server, bypass);
  }
  if (!wcscmp(command, L"clear")) {
    if (!expected_count || host || port) return usage(L"clear requires --expected-server");
    for (int i = 0; i < expected_count; i++) if (!kuro_valid_server(expected[i])) return usage(L"Invalid --expected-server");
    return cmd_clear(expected, expected_count);
  }
  return usage(L"Unknown command");
}
