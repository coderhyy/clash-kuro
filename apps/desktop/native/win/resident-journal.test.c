/* Private temporary file only: no shipping engine, ownership, proxy, or registry. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int short_write, fail_write, fail_flush;
static BOOL WINAPI test_write(HANDLE file, LPCVOID data, DWORD bytes, LPDWORD written, LPOVERLAPPED overlapped) {
  if (fail_write) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
  return WriteFile(file, data, short_write ? bytes / 2 : bytes, written, overlapped);
}
static BOOL WINAPI test_flush(HANDLE file) {
  if (fail_flush) { SetLastError(ERROR_WRITE_FAULT); return FALSE; }
  return FlushFileBuffers(file);
}
#define WriteFile test_write
#define FlushFileBuffers test_flush
#include "resident-journal.h"
#undef WriteFile
#undef FlushFileBuffers

#define TEST_BYTES (sizeof(KuroResidentJournalHeader) + 9 * sizeof(KuroResidentJournalRecord))
static KuroResidentJournalBinding proof;

static DWORD snapshot(HANDLE file, BYTE *data) {
  LARGE_INTEGER size, zero = {0}; DWORD bytes;
  assert(GetFileSizeEx(file, &size) && size.QuadPart >= 0 && size.QuadPart <= (LONGLONG)TEST_BYTES);
  assert(SetFilePointerEx(file, zero, NULL, FILE_BEGIN));
  assert(ReadFile(file, data, (DWORD)size.QuadPart, &bytes, NULL) && bytes == size.QuadPart);
  return bytes;
}
static void replace_bytes(HANDLE file, const void *data, DWORD bytes) {
  LARGE_INTEGER zero = {0}; DWORD written;
  assert(SetFilePointerEx(file, zero, NULL, FILE_BEGIN));
  assert(WriteFile(file, data, bytes, &written, NULL) && written == bytes);
  assert(SetEndOfFile(file));
}
static void unchanged(HANDLE file, const BYTE *data, DWORD bytes) {
  BYTE actual[TEST_BYTES];
  assert(snapshot(file, actual) == bytes && !memcmp(actual, data, bytes));
}
static void rejected(HANDLE file, const BYTE *data, DWORD bytes) {
  KuroResidentJournalState state;
  replace_bytes(file, data, bytes);
  memset(&state, 0x55, sizeof state);
  assert(kuro_resident_journal_read(file, &proof, &state) == ERROR_INVALID_DATA);
  KuroResidentJournalState empty = {0};
  assert(!memcmp(&state, &empty, sizeof state));
  assert(kuro_resident_journal_initialize(file, &proof) == ERROR_INVALID_DATA);
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:7893") == ERROR_INVALID_DATA);
  assert(kuro_resident_journal_reset_after_clear(file, &proof) == ERROR_INVALID_DATA);
  assert(kuro_resident_journal_read_owner(file, &proof, &state) == ERROR_INVALID_DATA);
  unchanged(file, data, bytes);
}
static void rechecksum(BYTE *data) {
  KuroResidentJournalHeader header;
  memcpy(&header, data, sizeof header);
  header.checksum = kuro_resident_journal_checksum(&header, offsetof(KuroResidentJournalHeader, checksum));
  memcpy(data, &header, sizeof header);
}

static void hash_tests(HANDLE file) {
  static const BYTE abc[32] = {
    0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
    0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad
  };
  static const BYTE empty[32] = {
    0xe3,0xb0,0xc4,0x42,0x98,0xfc,0x1c,0x14,0x9a,0xfb,0xf4,0xc8,0x99,0x6f,0xb9,0x24,
    0x27,0xae,0x41,0xe4,0x64,0x9b,0x93,0x4c,0xa4,0x95,0x99,0x1b,0x78,0x52,0xb8,0x55
  };
  BYTE digest[32], zero_digest[32] = {0};
  assert(!kuro_resident_sha256("abc", 3, digest) && !memcmp(digest, abc, 32));
  assert(!kuro_resident_sha256(NULL, 0, digest) && !memcmp(digest, empty, 32));
  assert(kuro_resident_sha256(NULL, 1, digest) == ERROR_INVALID_PARAMETER && !memcmp(digest, zero_digest, 32));
  assert(kuro_resident_sha256("abc", 3, NULL) == ERROR_INVALID_PARAMETER);
  assert(kuro_resident_sha256_file(INVALID_HANDLE_VALUE, digest) == ERROR_INVALID_HANDLE);
  assert(!memcmp(digest, zero_digest, 32));
  replace_bytes(file, "abc", 3);
  LARGE_INTEGER at; at.QuadPart = 1;
  assert(SetFilePointerEx(file, at, NULL, FILE_BEGIN));
  assert(!kuro_resident_sha256_file(file, digest) && !memcmp(digest, abc, 32));
  LARGE_INTEGER zero = {0}, position;
  assert(SetFilePointerEx(file, zero, &position, FILE_CURRENT) && position.QuadPart == 1);
  BYTE large[20000], expected[32]; memset(large, 0xa5, sizeof large);
  replace_bytes(file, large, sizeof large);
  assert(!kuro_resident_sha256(large, sizeof large, expected));
  assert(!kuro_resident_sha256_file(file, digest) && !memcmp(digest, expected, 32));
  assert(SetFilePointerEx(file, zero, &position, FILE_CURRENT) && position.QuadPart == sizeof large);
  HANDLE write_only;
  assert(DuplicateHandle(GetCurrentProcess(), file, GetCurrentProcess(), &write_only, GENERIC_WRITE, FALSE, 0));
  assert(kuro_resident_sha256_file(write_only, digest) == ERROR_ACCESS_DENIED);
  assert(!memcmp(digest, zero_digest, 32));
  assert(SetFilePointerEx(file, zero, &position, FILE_CURRENT) && position.QuadPart == sizeof large);
  CloseHandle(write_only);
  replace_bytes(file, NULL, 0);
}

int wmain(void) {
  /* endpoint.h also supplies these pure helpers to the shipping engine. */
  (void)kuro_all_endpoints_equal; (void)kuro_valid_bypass;
  (void)kuro_valid_log_path;
  wchar_t temp[MAX_PATH], path[MAX_PATH];
  assert(GetTempPathW(MAX_PATH, temp) && GetTempFileNameW(temp, L"krV", 0, path));
  HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
    FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
  assert(file != INVALID_HANDLE_VALUE);
  hash_tests(file);
  wcscpy(proof.sid, L"S-1-5-21-1-2-3-1001");
  assert(!kuro_resident_sha256("helper", 6, proof.helper_sha256));
  KuroResidentJournalState state;
  assert(!kuro_resident_journal_read(file, &proof, &state) && !state.initialized && !state.count);
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891") == ERROR_NOT_READY);
  assert(kuro_resident_journal_reset_after_clear(file, &proof) == ERROR_NOT_READY);
  assert(kuro_resident_journal_initialize(file, NULL) == ERROR_INVALID_PARAMETER);
  KuroResidentJournalBinding invalid = proof;
  memset(invalid.helper_sha256, 0, 32);
  assert(kuro_resident_journal_initialize(file, &invalid) == ERROR_INVALID_PARAMETER);
  invalid = proof;
  wcscpy(invalid.sid, L"BA");
  assert(kuro_resident_journal_initialize(file, &invalid) == ERROR_INVALID_PARAMETER);
  wmemset(invalid.sid, L'x', KURO_RESIDENT_JOURNAL_SID_CHARS);
  assert(kuro_resident_journal_initialize(file, &invalid) == ERROR_INVALID_PARAMETER);
  BYTE saved[TEST_BYTES], changed[TEST_BYTES];
  assert(snapshot(file, saved) == 0);
  assert(!kuro_resident_journal_initialize(file, &proof));
  assert(!kuro_resident_journal_initialize(file, &proof));
  assert(!kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891"));
  assert(!kuro_resident_journal_append(file, &proof, L"127.0.0.1:7892"));
  assert(!kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891"));
  assert(FlushFileBuffers(file));
  /* Replace the caller handle, then reread the flushed bytes. */
  HANDLE reopened;
  assert(DuplicateHandle(GetCurrentProcess(), file, GetCurrentProcess(), &reopened, 0, FALSE, DUPLICATE_SAME_ACCESS));
  CloseHandle(file); file = reopened;
  assert(!kuro_resident_journal_read(file, &proof, &state) && state.initialized && state.count == 2);
  assert(!memcmp(&state.binding, &proof, sizeof proof));
  assert(!wcscmp(state.servers[0], L"127.0.0.1:7891") && !wcscmp(state.servers[1], L"127.0.0.1:7892"));
  DWORD length = snapshot(file, saved);
  KuroResidentJournalBinding current = proof;
  assert(!kuro_resident_sha256("new helper", 10, current.helper_sha256));
  assert(!kuro_resident_journal_read_owner(file, &current, &state) && state.initialized && state.count == 2);
  assert(!memcmp(&state.binding, &proof, sizeof proof));
  assert(kuro_resident_journal_rebind(file, &proof, &current) == ERROR_NOT_READY);
  unchanged(file, saved, length);
  invalid = current; wcscpy(invalid.sid, L"S-1-5-21-1-2-3-1002");
  assert(kuro_resident_journal_read_owner(file, &invalid, &state) == ERROR_ACCESS_DENIED && !state.initialized);
  assert(kuro_resident_journal_rebind(file, &proof, &invalid) == ERROR_INVALID_PARAMETER);
  assert(kuro_resident_journal_rebind(file, NULL, &current) == ERROR_INVALID_PARAMETER);
  invalid = current; memset(invalid.helper_sha256, 0, 32);
  assert(kuro_resident_journal_rebind(file, &proof, &invalid) == ERROR_INVALID_PARAMETER);
  unchanged(file, saved, length);
  assert(!kuro_resident_journal_reset_after_clear(file, &proof));
  fail_write = 1;
  assert(kuro_resident_journal_rebind(file, &proof, &current) == ERROR_ACCESS_DENIED);
  fail_write = 0; unchanged(file, saved, 416);
  short_write = 1;
  assert(kuro_resident_journal_rebind(file, &proof, &current) == ERROR_WRITE_FAULT);
  short_write = 0;
  replace_bytes(file, saved, 416);
  fail_flush = 1;
  assert(kuro_resident_journal_rebind(file, &proof, &current) == ERROR_WRITE_FAULT);
  fail_flush = 0;
  assert(!kuro_resident_journal_read(file, &current, &state) && !state.count);
  assert(kuro_resident_journal_read(file, &proof, &state) == ERROR_ACCESS_DENIED && !state.initialized);
  replace_bytes(file, saved, 416);
  assert(!kuro_resident_journal_rebind(file, &proof, &current));
  assert(!kuro_resident_journal_read(file, &current, &state) && state.initialized && !state.count);
  assert(kuro_resident_journal_read(file, &proof, &state) == ERROR_ACCESS_DENIED && !state.initialized);
  replace_bytes(file, NULL, 0);
  assert(kuro_resident_journal_rebind(file, &proof, &current) == ERROR_NOT_READY);
  replace_bytes(file, saved, length);
  for (int field = 0; field < 2; ++field) {
    invalid = proof;
    if (field == 0) wcscpy(invalid.sid, L"S-1-5-21-1-2-3-1002");
    else invalid.helper_sha256[0] ^= 1;
    assert(kuro_resident_journal_initialize(file, &invalid) == ERROR_ACCESS_DENIED);
    assert(kuro_resident_journal_read(file, &invalid, &state) == ERROR_ACCESS_DENIED && !state.initialized && !state.count);
    assert(kuro_resident_journal_append(file, &invalid, L"127.0.0.1:7893") == ERROR_ACCESS_DENIED);
    assert(kuro_resident_journal_reset_after_clear(file, &invalid) == ERROR_ACCESS_DENIED);
    unchanged(file, saved, length);
  }
  assert(kuro_resident_journal_append(file, &proof, L"bad endpoint") == ERROR_INVALID_PARAMETER);
  unchanged(file, saved, length);

  const DWORD cuts[] = {1, 12, 415, 417, 1023, 1025};
  for (unsigned i = 0; i < sizeof cuts / sizeof *cuts; ++i) rejected(file, saved, cuts[i]);
  const unsigned flips[] = {0, 4, 8, 12, 380, 412, 416, 420, 424};
  for (unsigned i = 0; i < sizeof flips / sizeof *flips; ++i) {
    memcpy(changed, saved, length); changed[flips[i]] ^= 1;
    rejected(file, changed, length);
  }
  /* Zero/invalid provenance with a valid checksum must also be rejected. */
  const unsigned digest_offsets[] = {380};
  for (unsigned i = 0; i < 1; ++i) {
    memcpy(changed, saved, length); memset(changed + digest_offsets[i], 0, 32); rechecksum(changed);
    rejected(file, changed, length);
  }
  memcpy(changed, saved, length); changed[12] = 'X'; rechecksum(changed);
  rejected(file, changed, length);
  for (unsigned offset = 4; offset <= 8; offset += 4) {
    memcpy(changed, saved, length); changed[offset] ^= 1; rechecksum(changed);
    rejected(file, changed, length); /* Unknown version/size even with valid checksum. */
  }
  rejected(file, saved + 416, 608); /* Valid legacy608 endpoint is not authorization. */
  memset(changed, 0xa5, 416); rejected(file, changed, 416);
  memcpy(changed, saved, length); memcpy(changed + 1024, changed + 416, 608);
  rejected(file, changed, length); /* Duplicate records are invalid on disk. */

  replace_bytes(file, saved, length);
  for (unsigned i = 2; i < 8; ++i) {
    wchar_t server[64]; _snwprintf(server, 64, L"127.0.0.1:%u", 7891 + i);
    assert(!kuro_resident_journal_append(file, &proof, server));
  }
  DWORD full = snapshot(file, changed);
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:9000") == ERROR_BUFFER_OVERFLOW);
  unchanged(file, changed, full);
  memcpy(changed + full, saved + 416, 608);
  rejected(file, changed, full + 608);
  replace_bytes(file, saved, length);
  assert(!kuro_resident_journal_reset_after_clear(file, &proof));
  unchanged(file, saved, 416);
  assert(!kuro_resident_journal_read(file, &proof, &state) && state.initialized && !state.count);
  assert(!memcmp(&state.binding, &proof, sizeof proof));
  assert(!kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891"));

  /* I/O failures never report admission/set/reset success or silently repair data. */
  replace_bytes(file, NULL, 0); fail_write = 1;
  assert(kuro_resident_journal_initialize(file, &proof) == ERROR_ACCESS_DENIED);
  assert(snapshot(file, changed) == 0); fail_write = 0; short_write = 1;
  assert(kuro_resident_journal_initialize(file, &proof) == ERROR_WRITE_FAULT);
  DWORD torn = snapshot(file, changed); assert(torn == 208); short_write = 0;
  rejected(file, changed, torn);
  replace_bytes(file, NULL, 0); fail_flush = 1;
  assert(kuro_resident_journal_initialize(file, &proof) == ERROR_WRITE_FAULT);
  fail_flush = 0; assert(!kuro_resident_journal_initialize(file, &proof));
  short_write = 1;
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891") == ERROR_WRITE_FAULT);
  short_write = 0; torn = snapshot(file, changed); assert(torn == 416 + 304);
  rejected(file, changed, torn);
  replace_bytes(file, saved, length); fail_flush = 1;
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:7891") == ERROR_WRITE_FAULT);
  assert(kuro_resident_journal_append(file, &proof, L"127.0.0.1:7893") == ERROR_WRITE_FAULT);
  assert(kuro_resident_journal_reset_after_clear(file, &proof) == ERROR_WRITE_FAULT);
  fail_flush = 0; unchanged(file, saved, 416);
  assert(!kuro_resident_journal_read(file, &proof, &state) && state.initialized && !state.count);
  CloseHandle(file);
  puts("resident journal v3: SHA256, native initialization, provenance, identity, A/B persistence, rejection/reset/I/O failures passed");
  return 0;
}
