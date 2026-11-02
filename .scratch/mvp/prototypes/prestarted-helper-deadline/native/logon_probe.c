/* Read-only feasibility probe. Never changes proxy settings or RunOnce. */
#define SECURITY_WIN32
#include <windows.h>
#include <ntsecapi.h>
#include <stdio.h>

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
  CloseHandle(token);
  if (!ok) return 3;
  int result = query("self", stats.AuthenticationId, 1);
  LUID nonexistent = {0xffffffffu, 0x7fffffff};
  result |= query("synthetic-unallocated", nonexistent, 0);
  return result;
}
