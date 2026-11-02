# Logon identity evidence for legacy RunOnce migration

Researched 2026-11-02. Sources are primary Microsoft Windows documentation only. Documentation research only; no implementation review or experiments.

## Conclusion

An ordinary session owner can call `LsaGetLogonSessionData` without being an administrator. An explicit `STATUS_NO_SUCH_LOGON_SESSION` means the specified LSA logon session does not exist. Neither a generic query failure nor a different current logon establishes that fact. The API reference does not enumerate which failure codes it returns for missing versus inaccessible sessions. [1], [4]

`AuthenticationId` plus stored `LogonTime` is useful corroborating identity data, but Microsoft does not document this pair as a globally unique, reboot-safe identifier or as a migration barrier. It cannot by itself prove every old clear process is dead or that no legacy command can launch later. **The current route must fail closed wherever identity, query outcome, or legacy launch coverage is uncertain.** [2], [3], [5], [8], [11]

## What the identity and ordinary-user query establish

- `GetTokenInformation(TokenStatistics)` returns `TOKEN_STATISTICS.AuthenticationId`, the LUID of the logon session represented by that token; multiple tokens can represent one logon session. Querying these statistics requires `TOKEN_QUERY`. This is neither `TokenId` nor a Terminal Services session number. Capture the token associated with the legacy activity being tracked; the resident helper's current token is not evidence of which logon launched older activity. [2], [3], [6]
- The LSA query's documented access rule is: caller must be "the owner of the session or a local system administrator." This supports an ordinary owner querying its session, not unrestricted queries of every session. The reference does not specify every cross-logon/restricted-token permission case; access failure must remain unknown, including when the account name appears unchanged. [1]
- `SECURITY_LOGON_SESSION_DATA.LogonId` identifies the logon session; `Sid` identifies its user; `Session` is a Terminal Services session identifier and may be zero; `LogonTime` is "the time the session owner logged on." None is documented as a count of legacy processes or pending commands. Validate returned data before relying on it; malformed/missing identity fields are not absence. [3]

## Status meanings: absence versus inability to inspect

These are official status definitions, **not a function-specific promise that every listed status will be returned by this API**. `LsaGetLogonSessionData` documents only `STATUS_SUCCESS` and otherwise an explanatory `NTSTATUS`. [1], [4]

| Raw result | Documented meaning | Safe interpretation for this route |
| --- | --- | --- |
| `STATUS_SUCCESS` (`0x00000000`) | Operation succeeded. | A valid matching record means the tracked session still exists. A record with conflicting identity data is not clearance. |
| `STATUS_NO_SUCH_LOGON_SESSION` (`0xC000005F`) | "A specified logon session does not exist. It might already have been terminated." | Explicit absence of the queried LSA session at query time, subject to correct stored identity and reboot scope. Not proof about other sessions or future launches. |
| `STATUS_ACCESS_DENIED` (`0xC0000022`) | Requested access rights were not granted. | Unknown; block migration. Never translate denial into absence. |
| `STATUS_PRIVILEGE_NOT_HELD` (`0xC0000061`) | Client lacks a required privilege. | Unknown; block migration. This does not imply ordinary owners always need a privilege. |
| `STATUS_INVALID_PARAMETER` (`0xC000000D`) | Invalid parameter passed. | Invalid query, not documented session absence; block. |
| `STATUS_NOT_FOUND` (`0xC0000225`) | "The object was not found." | Generic definition does not identify the missing object or establish this API's missing-session contract; do not silently accept it as equivalent. |
| Any other failure or unusable output | No established absence interpretation. | Unknown; block. |

Use the returned `NTSTATUS`, not `GetLastError`, for this LSA call. `LsaNtStatusToWinError` converts LSA status codes for diagnostics and can return `ERROR_MR_MID_NOT_FOUND` when no mapping exists. The separate Win32 definitions are `ERROR_NO_SUCH_LOGON_SESSION` = 1312, `ERROR_ACCESS_DENIED` = 5, and `ERROR_PRIVILEGE_NOT_HELD` = 1314. Those numbers are not raw NTSTATUS values; the cited conversion page does not provide an exhaustive mapping table. Preserve the raw distinction. [1], [7]

**Documentation limit:** do not assert that every nonexistent LUID always produces `0xC000005F`, or that denial and absence are distinguished on every call path. That behavior is not specified in [1]. If the route needs that stronger guarantee, this documentation research does not establish it; retain the block.

## Reboot, stored LogonTime, and multiple sessions

Microsoft explicitly says logon IDs are unique while the computer runs, but their possible values reset at startup. LUID uniqueness is guaranteed only until restart. A persisted numeric `AuthenticationId` may therefore refer to a different logon after reboot. [5]

Comparing the stored `LogonTime` can expose an inconsistent record, but [3] promises only a logon timestamp, not uniqueness, monotonicity, or collision resistance for the pair. Windows also documents that system time can move backward or forward. A different timestamp does not, on its own, establish why the identity changed; an equal timestamp does not add a documented reboot identity guarantee. Missing/corrupt stored data, unknown boot continuity, or a mismatched record must not authorize this route. A separately established reboot is evidence beyond this pair. [3], [5], [9]

Fast User Switching leaves the previous user's applications running. `WTSDisconnectSession` explicitly disconnects without closing the RDP session and allows reconnection to it. A new desktop, active console change, or RDP disconnection therefore does not establish prior logon absence. One checked LUID says nothing about other concurrent logons, including another logon for the same account; the LSA and Terminal Services identifiers are distinct fields. [3], [10]

## RunOnce and process-lifetime limits

- **Registry disappearance is not completion.** By default a RunOnce value is deleted **before** its command runs; `!` defers deletion until after the command runs. Ordering of multiple entries under a key is indeterminate. Thus an absent value can coexist with an executing command. The documentation does not promise that deleting a value cancels a command already read/selected for launch, nor that starting the resident helper drains such work. Treat cancellation of an already selected launch as unproven. [8]
- **Do not overstate startup delay guarantees.** The Run/RunOnce page's explicit warning about delayed execution applies to `Run` and the Startup group. It does not specify the same scheduling rule for RunOnce or a RunOnce completion barrier relative to a new helper. HKLM RunOnce also runs only when an Administrators-group member logs on after reboot; a standard-user logon is not evidence that this pending work executed. [8]
- **Logoff and LSA deletion are different observations.** LSA increments a session reference count for tokens and their copies, including process creation and impersonation; it deletes the session when that count reaches zero. Microsoft also says a user remains logged on while a token exists and, for its `LogonUser`/`CreateProcessAsUser` example, until the process and children end. Consequently, an existing LSA session can reflect retained tokens after interactive activity ends; it is not proof that a particular clear process remains alive. Conversely, valid same-boot absence is meaningful against surviving tokens of that exact logon. [11]
- **Parent exit does not establish descendant exit.** Windows documents that terminating a process does not terminate its children. Do not equate launcher exit or RunOnce completion with termination of a spawned/detached clear child. Ordinary interactive applications are terminated at logoff, but services have different handling and can continue after user logoff. The docs do not support a blanket claim that every ordinary interactive child survives logoff, or that every kind of delegated work dies with it. [12]
- **Scheduled/delegated work may use another logon.** Task Scheduler distinguishes an existing interactive token from password, S4U, and service-account modes; S4U explicitly logs the user on for a noninteractive desktop. If a legacy command scheduled or delegated work, absence of the originating interactive LUID does not cover that separate execution context or a later launch. This is a limitation, not a claim that RunOnce inherently uses Task Scheduler. [13]

Migration consequence: matching data means present; denial, undocumented failure, invalid data, or identity ambiguity means unknown. Even explicit absence establishes only the queried session's absence. Without evidence covering every relevant legacy execution context and pending launch, **do not enable the resident helper's conflicting clear activity on this check alone**. No assertion here certifies that every old process is dead.

## Primary sources

[1]: https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-lsagetlogonsessiondata
[2]: https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-token_statistics
[3]: https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/ns-ntsecapi-security_logon_session_data
[4]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55
[5]: https://learn.microsoft.com/en-us/windows/win32/secgloss/l-gly
[6]: https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation
[7]: https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-lsantstatustowinerror
[8]: https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys
[9]: https://learn.microsoft.com/en-us/windows/win32/sysinfo/system-time
[10]: https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsdisconnectsession
[11]: https://learn.microsoft.com/en-us/windows/win32/secauthn/lsa-logon-sessions
[12]: https://learn.microsoft.com/en-us/windows/win32/procthread/terminating-a-process
[13]: https://learn.microsoft.com/en-us/windows/win32/api/taskschd/ne-taskschd-task_logon_type

Additional primary documentation supporting the grouped claims above:

- [Win32 error definitions, 0-499](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-) and [1300-1699](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1300-1699-) for [7].
- [AllocateLocallyUniqueId: uniqueness until restart](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-allocatelocallyuniqueid) for [5].
- [Fast User Switching: applications remain running](https://learn.microsoft.com/en-us/windows/win32/shell/fast-user-switching) for [10].
- [LogonUser, Remarks: token and process/child lifetime](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-logonusera) for [11].
- [HandlerRoutine: interactive logoff and surviving services](https://learn.microsoft.com/en-us/windows/console/handlerroutine) for [12].
