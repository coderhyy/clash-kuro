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
static KuroResidentJournalProvenance proof;

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
  assert(kuro_resident_journal_read(file, &proof.binding, &state) == ERROR_INVALID_DATA);
  KuroResidentJournalState empty = {0};
  assert(!memcmp(&state, &empty, sizeof state));
  assert(kuro_resident_journal_admit(file, &proof) == ERROR_INVALID_DATA);
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7893") == ERROR_INVALID_DATA);
  assert(kuro_resident_journal_reset_after_clear(file, &proof.binding) == ERROR_INVALID_DATA);
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
  (void)kuro_valid_log_path; (void)kuro_runonce_command;
  wchar_t temp[MAX_PATH], path[MAX_PATH];
  assert(GetTempPathW(MAX_PATH, temp) && GetTempFileNameW(temp, L"krV", 0, path));
  HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
    FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
  assert(file != INVALID_HANDLE_VALUE);
  hash_tests(file);
  wcscpy(proof.binding.sid, L"S-1-5-21-1-2-3-1001");
  assert(!kuro_resident_sha256("helper", 6, proof.binding.helper_sha256));
  assert(!kuro_resident_sha256("receipt", 7, proof.receipt_sha256));
  assert(!kuro_resident_sha256("evidence", 8, proof.evidence_sha256));
  KuroResidentJournalState state;
  assert(!kuro_resident_journal_read(file, &proof.binding, &state) && !state.initialized && !state.count);
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891") == ERROR_NOT_READY);
  assert(kuro_resident_journal_reset_after_clear(file, &proof.binding) == ERROR_NOT_READY);
  assert(kuro_resident_journal_admit(file, NULL) == ERROR_INVALID_PARAMETER);
  for (int field = 0; field < 3; ++field) {
    KuroResidentJournalProvenance invalid = proof;
    memset(field == 0 ? invalid.binding.helper_sha256 : field == 1 ? invalid.receipt_sha256 : invalid.evidence_sha256, 0, 32);
    assert(kuro_resident_journal_admit(file, &invalid) == ERROR_INVALID_PARAMETER);
  }
  KuroResidentJournalProvenance invalid = proof;
  wcscpy(invalid.binding.sid, L"BA");
  assert(kuro_resident_journal_admit(file, &invalid) == ERROR_INVALID_PARAMETER);
  wmemset(invalid.binding.sid, L'x', KURO_RESIDENT_JOURNAL_SID_CHARS);
  assert(kuro_resident_journal_admit(file, &invalid) == ERROR_INVALID_PARAMETER);
  BYTE saved[TEST_BYTES], changed[TEST_BYTES];
  assert(snapshot(file, saved) == 0);
  assert(!kuro_resident_journal_admit(file, &proof));
  assert(!kuro_resident_journal_admit(file, &proof));
  assert(!kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891"));
  assert(!kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7892"));
  assert(!kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891"));
  assert(FlushFileBuffers(file));
  /* Replace the caller handle, then reread the flushed bytes. */
  HANDLE reopened;
  assert(DuplicateHandle(GetCurrentProcess(), file, GetCurrentProcess(), &reopened, 0, FALSE, DUPLICATE_SAME_ACCESS));
  CloseHandle(file); file = reopened;
  assert(!kuro_resident_journal_read(file, &proof.binding, &state) && state.initialized && state.count == 2);
  assert(!memcmp(&state.provenance, &proof, sizeof proof));
  assert(!wcscmp(state.servers[0], L"127.0.0.1:7891") && !wcscmp(state.servers[1], L"127.0.0.1:7892"));
  DWORD length = snapshot(file, saved);
  for (int field = 0; field < 4; ++field) {
    invalid = proof;
    if (field == 0) wcscpy(invalid.binding.sid, L"S-1-5-21-1-2-3-1002");
    else (field == 1 ? invalid.binding.helper_sha256 : field == 2 ? invalid.receipt_sha256 : invalid.evidence_sha256)[0] ^= 1;
    assert(kuro_resident_journal_admit(file, &invalid) == (field < 2 ? ERROR_ACCESS_DENIED : ERROR_REVISION_MISMATCH));
    if (field < 2) {
      assert(kuro_resident_journal_read(file, &invalid.binding, &state) == ERROR_ACCESS_DENIED && !state.initialized && !state.count);
      assert(kuro_resident_journal_append(file, &invalid.binding, L"127.0.0.1:7893") == ERROR_ACCESS_DENIED);
      assert(kuro_resident_journal_reset_after_clear(file, &invalid.binding) == ERROR_ACCESS_DENIED);
    }
    unchanged(file, saved, length);
  }
  assert(kuro_resident_journal_append(file, &proof.binding, L"bad endpoint") == ERROR_INVALID_PARAMETER);
  unchanged(file, saved, length);

  const DWORD cuts[] = {1, 12, 479, 481, 1087, 1089};
  for (unsigned i = 0; i < sizeof cuts / sizeof *cuts; ++i) rejected(file, saved, cuts[i]);
  const unsigned flips[] = {0, 4, 8, 12, 380, 412, 444, 476, 480, 484, 488};
  for (unsigned i = 0; i < sizeof flips / sizeof *flips; ++i) {
    memcpy(changed, saved, length); changed[flips[i]] ^= 1;
    rejected(file, changed, length);
  }
  /* Zero/invalid provenance with a valid checksum must also be rejected. */
  const unsigned digest_offsets[] = {380, 412, 444};
  for (unsigned i = 0; i < 3; ++i) {
    memcpy(changed, saved, length); memset(changed + digest_offsets[i], 0, 32); rechecksum(changed);
    rejected(file, changed, length);
  }
  memcpy(changed, saved, length); changed[12] = 'X'; rechecksum(changed);
  rejected(file, changed, length);
  for (unsigned offset = 4; offset <= 8; offset += 4) {
    memcpy(changed, saved, length); changed[offset] ^= 1; rechecksum(changed);
    rejected(file, changed, length); /* Unknown version/size even with valid checksum. */
  }
  rejected(file, saved + 480, 608); /* Valid legacy608 endpoint is not authorization. */
  memset(changed, 0xa5, 480); rejected(file, changed, 480);
  memcpy(changed, saved, length); memcpy(changed + 1088, changed + 480, 608);
  rejected(file, changed, length); /* Duplicate records are invalid on disk. */

  replace_bytes(file, saved, length);
  for (unsigned i = 2; i < 8; ++i) {
    wchar_t server[64]; _snwprintf(server, 64, L"127.0.0.1:%u", 7891 + i);
    assert(!kuro_resident_journal_append(file, &proof.binding, server));
  }
  DWORD full = snapshot(file, changed);
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:9000") == ERROR_BUFFER_OVERFLOW);
  unchanged(file, changed, full);
  memcpy(changed + full, saved + 480, 608);
  rejected(file, changed, full + 608);
  replace_bytes(file, saved, length);
  assert(!kuro_resident_journal_reset_after_clear(file, &proof.binding));
  unchanged(file, saved, 480);
  assert(!kuro_resident_journal_read(file, &proof.binding, &state) && state.initialized && !state.count);
  assert(!memcmp(&state.provenance, &proof, sizeof proof));
  assert(!kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891"));

  /* I/O failures never report admission/set/reset success or silently repair data. */
  replace_bytes(file, NULL, 0); fail_write = 1;
  assert(kuro_resident_journal_admit(file, &proof) == ERROR_ACCESS_DENIED);
  assert(snapshot(file, changed) == 0); fail_write = 0; short_write = 1;
  assert(kuro_resident_journal_admit(file, &proof) == ERROR_WRITE_FAULT);
  DWORD torn = snapshot(file, changed); assert(torn == 240); short_write = 0;
  rejected(file, changed, torn);
  replace_bytes(file, NULL, 0); fail_flush = 1;
  assert(kuro_resident_journal_admit(file, &proof) == ERROR_WRITE_FAULT);
  fail_flush = 0; assert(!kuro_resident_journal_admit(file, &proof));
  short_write = 1;
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891") == ERROR_WRITE_FAULT);
  short_write = 0; torn = snapshot(file, changed); assert(torn == 480 + 304);
  rejected(file, changed, torn);
  replace_bytes(file, saved, length); fail_flush = 1;
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7891") == ERROR_WRITE_FAULT);
  assert(kuro_resident_journal_append(file, &proof.binding, L"127.0.0.1:7893") == ERROR_WRITE_FAULT);
  assert(kuro_resident_journal_reset_after_clear(file, &proof.binding) == ERROR_WRITE_FAULT);
  fail_flush = 0; unchanged(file, saved, 480);
  assert(!kuro_resident_journal_read(file, &proof.binding, &state) && state.initialized && !state.count);
  CloseHandle(file);
  puts("resident journal v2: SHA256, explicit admission, provenance, identity, A/B persistence, rejection/reset/I/O failures passed");
  return 0;
}
