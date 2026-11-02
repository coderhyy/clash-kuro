/* Read-only feasibility probe. Never changes proxy settings or RunOnce. */
#define SECURITY_WIN32
#include <windows.h>
#include <ntsecapi.h>
#include <stdio.h>
#include <stdlib.h>

static int inventory(HANDLE token) {
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  if (!size || size > 65536) return 4;
  TOKEN_USER *user = malloc(size);
  if (!user || !GetTokenInformation(token, TokenUser, user, size, &size)) { free(user); return 4; }
  ULONG count = 0, readable = 0, same_user = 0, unknown = 0;
  PLUID sessions = NULL;
  NTSTATUS status = LsaEnumerateLogonSessions(&count, &sessions);
  if (status || !sessions || count > 65536) {
    if (sessions) LsaFreeReturnBuffer(sessions);
    free(user); return 5;
  }
  for (ULONG i = 0; i < count; ++i) {
    PSECURITY_LOGON_SESSION_DATA data = NULL;
    NTSTATUS error = LsaGetLogonSessionData(sessions + i, &data);
    if (!error && data && data->Size >= sizeof *data && data->Sid && IsValidSid(data->Sid)) {
      readable++;
      if (EqualSid(user->User.Sid, data->Sid)) same_user++;
    } else unknown++;
    if (data) LsaFreeReturnBuffer(data);
  }
  printf("{\"query\":\"inventory-counts-only\",\"total\":%lu,\"readable\":%lu,\"sameUser\":%lu,\"unknown\":%lu}\n",
    count, readable, same_user, unknown);
  LsaFreeReturnBuffer(sessions); free(user);
  return 0;
}

static int query(const char *label, LUID id, int must_exist) {
  PSECURITY_LOGON_SESSION_DATA data = NULL;
  NTSTATUS status = LsaGetLogonSessionData(&id, &data);
  printf("{\"query\":\"%s\",\"luidHigh\":%lu,\"luidLow\":%lu,"
    "\"ntstatus\":\"0x%08lx\",\"winerror\":%lu",
    label, (unsigned long)id.HighPart, id.LowPart,
    (unsigned long)status, LsaNtStatusToWinError(status));
  int valid = status == 0 && data &&
    data->Size >= sizeof(SECURITY_LOGON_SESSION_DATA) &&
    data->LogonId.HighPart == id.HighPart && data->LogonId.LowPart == id.LowPart &&
    data->LogonTime.QuadPart > 0;
  if (valid) printf(",\"logonTime\":\"%lld\",\"session\":%lu,\"logonType\":%lu",
    (long long)data->LogonTime.QuadPart, data->Session, data->LogonType);
  printf(",\"validIdentity\":%s}\n", valid ? "true" : "false");
  if (data) LsaFreeReturnBuffer(data);
  return must_exist && !valid ? 1 : 0;
}

int main(void) {
  HANDLE token = NULL;
  TOKEN_STATISTICS stats;
  DWORD size = 0;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 2;
  BOOL ok = GetTokenInformation(token, TokenStatistics, &stats, sizeof(stats), &size);
  if (!ok) { CloseHandle(token); return 3; }
  int result = query("self", stats.AuthenticationId, 1);
  LUID nonexistent = {0xffffffffu, 0x7fffffff};
  result |= query("synthetic-unallocated", nonexistent, 0);
  result |= inventory(token);
  CloseHandle(token);
  return result;
}
