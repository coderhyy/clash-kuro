#include "resident-protocol.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
  _Static_assert(sizeof(wchar_t) == 2, "Windows UTF-16 required");
  unsigned char header[8] = {1, 0, 0, 0, 8, 0, 0, 0};
  uint32_t kind, bytes;
  assert(kuro_request_header(header, &kind, &bytes) && kind == 1 && bytes == 8);
  wchar_t get[] = L"get", empty[] = L"", missing[] = { L'g', L'e', L't' };
  wchar_t *argv[KURO_REQUEST_ARGS]; size_t argc;
  assert(kuro_request_args(get, sizeof get, argv, &argc) && argc == 1 && !wcscmp(argv[0], L"get"));
  assert(!kuro_request_args(empty, sizeof empty, argv, &argc));
  assert(!kuro_request_args(missing, sizeof missing, argv, &argc));
  assert(!kuro_request_args(get, 7, argv, &argc));
  wchar_t arguments[] = L"set\0--bypass\0";
  assert(kuro_request_args(arguments, sizeof arguments, argv, &argc) && argc == 3 && !*argv[2]);
  wchar_t excess[34]; for (size_t i = 0; i < 34; ++i) excess[i] = 0; excess[0] = L'x';
  assert(!kuro_request_args(excess, sizeof excess, argv, &argc));
  header[0] = 2;
  assert(!kuro_request_header(header, &kind, &bytes));
  header[4] = 0;
  assert(kuro_request_header(header, &kind, &bytes) && kind == 2 && bytes == 0);
  header[0] = 3;
  assert(!kuro_request_header(header, &kind, &bytes));
  header[0] = 1; header[6] = 2;
  assert(!kuro_request_header(header, &kind, &bytes));
  puts("resident protocol: bounded argv and separate close framing passed");
  return 0;
}
