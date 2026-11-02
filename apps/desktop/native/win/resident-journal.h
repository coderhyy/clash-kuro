#ifndef KURO_RESIDENT_JOURNAL_H
#define KURO_RESIDENT_JOURNAL_H
#include <windows.h>
#include <wincrypt.h>
#include <sddl.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "endpoint.h"

#define KURO_RESIDENT_JOURNAL_ENDPOINTS 8
#define KURO_RESIDENT_JOURNAL_SID_CHARS 184
#define KURO_RESIDENT_JOURNAL_MAGIC 0x324a524bu

typedef struct {
  wchar_t sid[KURO_RESIDENT_JOURNAL_SID_CHARS];
  BYTE helper_sha256[32];
} KuroResidentJournalBinding;
typedef struct {
  KuroResidentJournalBinding binding;
  BYTE receipt_sha256[32], evidence_sha256[32];
} KuroResidentJournalProvenance;
typedef struct {
  BOOL initialized;
  KuroResidentJournalProvenance provenance;
  unsigned count;
  wchar_t servers[KURO_RESIDENT_JOURNAL_ENDPOINTS][300];
} KuroResidentJournalState;

/* Windows little-endian UTF-16; the endpoint record retains the existing encoding.
   Checksums detect corruption, not hostile same-user edits. Link only Advapi32. */
typedef struct {
  uint32_t magic, version, bytes;
  KuroResidentJournalProvenance provenance;
  uint32_t checksum;
} KuroResidentJournalHeader;
typedef struct { uint32_t magic, checksum; wchar_t server[300]; } KuroResidentJournalRecord;
_Static_assert(sizeof(wchar_t) == 2 && sizeof(KuroResidentJournalHeader) == 480 &&
  offsetof(KuroResidentJournalHeader, checksum) == 476, "Fixed v2 header layout");
_Static_assert(sizeof(KuroResidentJournalRecord) == 608, "Existing endpoint encoding");

static inline DWORD kuro_resident_hash_begin(HCRYPTPROV *provider, HCRYPTHASH *hash) {
  *provider = 0; *hash = 0;
  if (!CryptAcquireContextW(provider, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) return GetLastError();
  if (CryptCreateHash(*provider, CALG_SHA_256, 0, 0, hash)) return ERROR_SUCCESS;
  DWORD error = GetLastError();
  CryptReleaseContext(*provider, 0); *provider = 0;
  return error;
}
static inline DWORD kuro_resident_hash_end(HCRYPTPROV provider, HCRYPTHASH hash, BYTE out[32], DWORD error) {
  DWORD bytes = 32;
  if (!error && !CryptGetHashParam(hash, HP_HASHVAL, out, &bytes, 0)) error = GetLastError();
  if (hash) CryptDestroyHash(hash);
  if (provider) CryptReleaseContext(provider, 0);
  if (error) ZeroMemory(out, 32);
  return error;
}
/* Return Win32 errors; hashes are zero on error. NULL data is valid only for zero bytes.
   CRYPT_VERIFYCONTEXT creates no persisted key container. */
static inline DWORD kuro_resident_sha256(const void *data, size_t bytes, BYTE out[32]) {
  if (!out) return ERROR_INVALID_PARAMETER;
  ZeroMemory(out, 32);
  if (!data && bytes) return ERROR_INVALID_PARAMETER;
  HCRYPTPROV provider; HCRYPTHASH hash;
  DWORD error = kuro_resident_hash_begin(&provider, &hash);
  const BYTE *next = data;
  while (!error && bytes) {
    DWORD chunk = bytes > MAXDWORD ? MAXDWORD : (DWORD)bytes;
    if (!CryptHashData(hash, next, chunk, 0)) error = GetLastError();
    next += chunk; bytes -= chunk;
  }
  return kuro_resident_hash_end(provider, hash, out, error);
}
/* Hash the entire seekable file, restoring its original position even on failure.
   Caller excludes concurrent changes and pointer use for the whole operation. */
static inline DWORD kuro_resident_sha256_file(HANDLE file, BYTE out[32]) {
  if (!out) return ERROR_INVALID_PARAMETER;
  ZeroMemory(out, 32);
  LARGE_INTEGER zero = {0}, position;
  if (!SetFilePointerEx(file, zero, &position, FILE_CURRENT)) return GetLastError();
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return GetLastError();
  HCRYPTPROV provider; HCRYPTHASH hash;
  DWORD error = kuro_resident_hash_begin(&provider, &hash);
  BYTE buffer[8192];
  while (!error) {
    DWORD bytes;
    if (!ReadFile(file, buffer, sizeof buffer, &bytes, NULL)) { error = GetLastError(); break; }
    if (!bytes) break;
    if (!CryptHashData(hash, buffer, bytes, 0)) error = GetLastError();
  }
  error = kuro_resident_hash_end(provider, hash, out, error);
  if (!SetFilePointerEx(file, position, NULL, FILE_BEGIN) && !error) error = GetLastError();
  if (error) ZeroMemory(out, 32);
  return error;
}

static inline uint32_t kuro_resident_journal_checksum(const void *data, size_t bytes) {
  uint32_t hash = 2166136261u;
  const BYTE *next = data;
  for (size_t i = 0; i < bytes; ++i) hash = (hash ^ next[i]) * 16777619u;
  return hash;
}
static inline BOOL kuro_resident_digest_present(const BYTE digest[32]) {
  BYTE bits = 0;
  for (unsigned i = 0; i < 32; ++i) bits |= digest[i];
  return bits != 0;
}
static inline BOOL kuro_resident_journal_binding_valid(const KuroResidentJournalBinding *binding) {
  if (!binding || !wmemchr(binding->sid, 0, KURO_RESIDENT_JOURNAL_SID_CHARS) ||
      wcsncmp(binding->sid, L"S-1-", 4) || !kuro_resident_digest_present(binding->helper_sha256)) return FALSE;
  PSID sid = NULL;
  if (!ConvertStringSidToSidW(binding->sid, &sid)) return FALSE;
  wchar_t *canonical = NULL;
  BOOL valid = ConvertSidToStringSidW(sid, &canonical) && !wcscmp(binding->sid, canonical);
  LocalFree(canonical); LocalFree(sid);
  return valid;
}

/* Existing synchronous disk handle, externally held native owner, no concurrent I/O.
   expected MUST be genuinely native-derived by the caller; this module does not
   authenticate main, acquire ownership, resolve paths, or authorize proxy writes.
   All operations return Win32 errors. Reads clear state on failure. Empty read is
   initialized=FALSE, not authorization. Invalid/legacy bytes are never repaired.
   Parsing/identity rejection leaves bytes intact; I/O failures may leave torn data. */
static inline DWORD kuro_resident_journal_read(HANDLE file,
    const KuroResidentJournalBinding *expected, KuroResidentJournalState *state) {
  if (!state) return ERROR_INVALID_PARAMETER;
  ZeroMemory(state, sizeof *state);
  if (!kuro_resident_journal_binding_valid(expected)) return ERROR_INVALID_PARAMETER;
  LARGE_INTEGER size, zero = {0};
  if (!GetFileSizeEx(file, &size)) return GetLastError();
  if (!size.QuadPart) return ERROR_SUCCESS;
  if (size.QuadPart < (LONGLONG)sizeof(KuroResidentJournalHeader) ||
      size.QuadPart > (LONGLONG)(sizeof(KuroResidentJournalHeader) +
        KURO_RESIDENT_JOURNAL_ENDPOINTS * sizeof(KuroResidentJournalRecord)) ||
      (size.QuadPart - sizeof(KuroResidentJournalHeader)) % sizeof(KuroResidentJournalRecord)) return ERROR_INVALID_DATA;
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return GetLastError();
  KuroResidentJournalHeader header; DWORD bytes;
  if (!ReadFile(file, &header, sizeof header, &bytes, NULL)) return GetLastError();
  if (bytes != sizeof header || header.magic != KURO_RESIDENT_JOURNAL_MAGIC || header.version != 2 ||
      header.bytes != sizeof header || header.checksum != kuro_resident_journal_checksum(&header,
        offsetof(KuroResidentJournalHeader, checksum)) ||
      !kuro_resident_journal_binding_valid(&header.provenance.binding) ||
      !kuro_resident_digest_present(header.provenance.receipt_sha256) ||
      !kuro_resident_digest_present(header.provenance.evidence_sha256)) return ERROR_INVALID_DATA;
  if (wcscmp(header.provenance.binding.sid, expected->sid) ||
      memcmp(header.provenance.binding.helper_sha256, expected->helper_sha256, 32)) return ERROR_ACCESS_DENIED;
  KuroResidentJournalState parsed = {0};
  parsed.initialized = TRUE; parsed.provenance = header.provenance;
  unsigned count = (unsigned)((size.QuadPart - sizeof header) / sizeof(KuroResidentJournalRecord));
  for (unsigned i = 0; i < count; ++i) {
    KuroResidentJournalRecord record;
    if (!ReadFile(file, &record, sizeof record, &bytes, NULL)) return GetLastError();
    if (bytes != sizeof record || record.magic != 0x3152504bu || record.server[299] ||
        record.checksum != kuro_resident_journal_checksum(record.server, sizeof record.server) ||
        !kuro_valid_server(record.server)) return ERROR_INVALID_DATA;
    for (unsigned j = 0; j < i; ++j)
      if (!wcscmp(parsed.servers[j], record.server)) return ERROR_INVALID_DATA;
    wcscpy(parsed.servers[i], record.server);
  }
  parsed.count = count; *state = parsed;
  return ERROR_SUCCESS;
}

/* Only explicit ADMIT may initialize an empty file. Existing provenance is immutable:
   identical proof is idempotent; different receipt/evidence is REVISION_MISMATCH.
   A later replacement/rebinding protocol is deliberately outside this primitive. */
static inline DWORD kuro_resident_journal_admit(HANDLE file, const KuroResidentJournalProvenance *proof) {
  if (!proof || !kuro_resident_journal_binding_valid(&proof->binding) ||
      !kuro_resident_digest_present(proof->receipt_sha256) ||
      !kuro_resident_digest_present(proof->evidence_sha256)) return ERROR_INVALID_PARAMETER;
  KuroResidentJournalState state;
  DWORD error = kuro_resident_journal_read(file, &proof->binding, &state);
  if (error) return error;
  if (state.initialized) {
    if (memcmp(state.provenance.receipt_sha256, proof->receipt_sha256, 32) ||
        memcmp(state.provenance.evidence_sha256, proof->evidence_sha256, 32)) return ERROR_REVISION_MISMATCH;
    return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
  }
  KuroResidentJournalHeader header = {0};
  header.magic = KURO_RESIDENT_JOURNAL_MAGIC; header.version = 2; header.bytes = sizeof header;
  wcscpy(header.provenance.binding.sid, proof->binding.sid);
  memcpy(header.provenance.binding.helper_sha256, proof->binding.helper_sha256, 32);
  memcpy(header.provenance.receipt_sha256, proof->receipt_sha256, 32);
  memcpy(header.provenance.evidence_sha256, proof->evidence_sha256, 32);
  header.checksum = kuro_resident_journal_checksum(&header, offsetof(KuroResidentJournalHeader, checksum));
  LARGE_INTEGER zero = {0}; DWORD bytes;
  if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN)) return GetLastError();
  if (!WriteFile(file, &header, sizeof header, &bytes, NULL)) return GetLastError();
  if (bytes != sizeof header) return ERROR_WRITE_FAULT;
  return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
}

/* Success must precede registration/set. Duplicate endpoints still flush; no retries
   or rollback after short writes/flush failure. Keep evidence and deny further writes. */
static inline DWORD kuro_resident_journal_append(HANDLE file,
    const KuroResidentJournalBinding *expected, const wchar_t *server) {
  if (!server || wcslen(server) >= 300 || !kuro_valid_server(server)) return ERROR_INVALID_PARAMETER;
  KuroResidentJournalState state;
  DWORD error = kuro_resident_journal_read(file, expected, &state);
  if (error) return error;
  if (!state.initialized) return ERROR_NOT_READY;
  for (unsigned i = 0; i < state.count; ++i) if (!wcscmp(state.servers[i], server))
    return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
  if (state.count == KURO_RESIDENT_JOURNAL_ENDPOINTS) return ERROR_BUFFER_OVERFLOW;
  KuroResidentJournalRecord record = {0};
  record.magic = 0x3152504bu; wcscpy(record.server, server);
  record.checksum = kuro_resident_journal_checksum(record.server, sizeof record.server);
  LARGE_INTEGER zero = {0}; DWORD bytes;
  if (!SetFilePointerEx(file, zero, NULL, FILE_END)) return GetLastError();
  if (!WriteFile(file, &record, sizeof record, &bytes, NULL)) return GetLastError();
  if (bytes != sizeof record) return ERROR_WRITE_FAULT;
  return FlushFileBuffers(file) ? ERROR_SUCCESS : GetLastError();
}

/* Call ONLY after verified clear of the entire endpoint set. Truncate endpoints,
   never provenance; interrupted reset may leave old endpoints for repeat cleanup.
   A torn/corrupt journal is rejected rather than reset into an authorized header. */
static inline DWORD kuro_resident_journal_reset_after_clear(HANDLE file,
    const KuroResidentJournalBinding *expected) {
  KuroResidentJournalState state;
  DWORD error = kuro_resident_journal_read(file, expected, &state);
  if (error) return error;
  if (!state.initialized) return ERROR_NOT_READY;
  LARGE_INTEGER end; end.QuadPart = sizeof(KuroResidentJournalHeader);
  if (!SetFilePointerEx(file, end, NULL, FILE_BEGIN) || !SetEndOfFile(file) || !FlushFileBuffers(file))
    return GetLastError();
  return ERROR_SUCCESS;
}
#endif
