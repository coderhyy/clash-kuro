# Formal app Windows acceptance evidence

Recorded 2026-11-03. Tested binary commit:
`143a97f46c4b867de77069f9b945bdd7ad150e89`, CI run `41594932698`
(Windows/macOS passed). Documentation commits after that do not change the
identity of the tested artifact. This is limited manual evidence, not release
acceptance or permission to merge.

## Three completed cases

Windows 11 Home Chinese, 10.0.26200, same current user, LAN only. Human performed
all Exit/logoff/shutdown actions. No power settings changed. Times below are
milliseconds from each native owner's immutable first trigger, not realtime
guarantees. Core stop used `TerminateJobObject-owned-job`, not graceful exit.

| Case | Owner / Core PID | First trigger | Clear done | Readback | Core request / confirmed | Native duration | Baseline restored |
| --- | --- | --- | --- | --- | --- | --- | --- |
| normal-quit | 8488 / 14604 | IPC (2) | 47 | 62 | 62 / 62 | 109 | yes |
| native-logoff-01, Tray Mode | 12244 / 13912 | WM_QUERYENDSESSION (16), logoff flag | 62 | 78 | 94 / 94 | 203 | yes |
| native-fullshutdown-01, Tray Mode | 15920 / 3472 | WM_QUERYENDSESSION (16), flags 0 | 78 | 125 | 125 / 125 | 282 | yes |

All three matching native records have `ok=true`, `timedOut=false`,
`cleanupReadbackVerified=true`, `coreGone=true`, LAN cleared and read back as
flags 1 before the Core stop request. Equal tick values are coarse timing,
not evidence of zero latency. Independent after probes found flags 1 and no
48967 listener. Known old app/owner/Core identities were gone. Probe supervisor
exit codes were zero, with no rescue or remaining children.

- Normal quit: user confirmed exactly one tray Exit, no error or other action.
  App logged `exit done in 189 ms` and `cleanup completed` at 09:30:15.068Z.
- Logoff: cleanup record at 09:57:15.894Z precedes new Explorer at 09:57:45Z.
  User confirmed completed logoff/same-user login without error. Final trigger
  mask 22 includes subsequent IPC/EOF; native query was first. PID 12244 was
  reused by a later WebView process: path and creation time disambiguate it.
- Full shutdown: human used `shutdown.exe /s /t 0`, then powered on. User32 1074
  records shutdown.exe at 10:51:04.303Z; cleanup record 10:51:04.797Z;
  Kernel-General 13 shutdown at 10:51:19.028Z; Kernel-General 12 new boot at
  10:55:23.500Z, followed by Explorer at 10:55:39Z. Final trigger mask 18.
- Session cases had queryEvents=1/endEvents=0. A missing end event after completed
  query-triggered cleanup does not invalidate that cleanup. Persisted JSON and
  absence after login do NOT independently establish voluntary helper exit code
  zero. Historical `exit.log` entries are not evidence for these session cases.

No RunOnce fallback was used. Startup recovery records before each test are
excluded. The session cleanup precedes new login/boot, rather than being credited
to subsequent app startup or restoration.

## Restoration and private evidence

Local private evidence root: `C:\Users\DT-056\kuro-formal-acceptance\143a97f`.
Each table case has its own subdirectory, before/after inventory and logs, and
`restored-verified.json`. Raw process/settings/registry files remain outside Git.

Backups under `C:\Users\DT-056\kuro-sysproxy-backups`:

| Case | Backup directory | Verified restoration UTC |
| --- | --- | --- |
| normal-quit | wininet-1793693847461 | 09:37:15.833Z |
| native-logoff-01 | wininet-1793699260531 | 10:06:11.817Z |
| native-fullshutdown-01 | wininet-1793700901604 | 11:48:19.555Z |

Every result reports `restoredAndVerified=true`, `runOnceUnchanged=true`.
Original LAN baseline: flags 1, server 127.0.0.1:7891, bypass
`localhost;127.0.0.1;[::1]`, stored PAC `http://127.0.0.1:9/test.pac`.
Snapshot SHA256 remained
`C510A4B595C1F81CBC18426C8440949FE45703ADEC046284D8ADD6E0363CF3B0`.
The restore tool's one-shot scope describes guarded baseline restoration, not
resident session validation. No recovery ran alongside a known surviving writer.

Capture failures retained: missing Node in the user's PATH; partial preparation
files; watchdog exit 94 on direct Windows PowerShell invocation (exact native
branch unproven); PowerShell 5.1 nested JSON array/date comparison error. Existing
Node v24.22.1 absolute-path execution with explicit streams and the same watchdog
budget succeeded. These tooling failures were not counted as app cleanup failures
or hidden as successful captures. No budgets were enlarged.

## Remaining risks and minimal validation proposals (NOT scheduled or executed)

Maintainer decision, 2026-11-03: defer the canceled-shutdown and abnormal
startup/explicit retained-helper recovery cases below to subsequent TUN work.
Validate and fix any discovered defects in that work; do not run more cases or
change implementation now. These risks remain open, not accepted as tested or
resolved. This is a follow-up scope note, not authorization for power-loss tests
or expanded architecture, and does not change issue Status or merge restrictions.

### Canceled shutdown

Risk: query-session cleanup can already have stopped Core when Windows cancels
shutdown. A surviving app must show stopped/restart-required, proxy unknown, and
reject new writes/restarts rather than falsely show running or auto-reenable.
Automated coverage is not a real canceled-session observation.

Minimum: one separately authorized, backed-up real cancellation case using a
controlled user-owned app that legitimately blocks shutdown and the Windows
Cancel UI. Do not use shutdown.exe /a as proof after session query: it may only
cancel an earlier timer. Require native query evidence, actual cancellation with
the user session retained, stopped exact Core, visible restart requirement and
rejected UI/tray re-enable. If Windows completes shutdown or no query occurred,
label the case inconclusive for cancellation; do not force or blindly repeat.
Restore only after old writer death is established.

### Abnormal termination and journal recovery

Risk: no RunOnce/login recovery. A crash or power loss may leave an enabled proxy
until Kuro startup or explicit retained-helper recovery. Recovery must refuse a
live competing owner, foreign settings or invalid journal; install removal must
not make the retained helper unavailable. Actual power-loss durability remains
unproved, and bounded best-effort logging can leave uncertain results.

Minimum, separately authorized: first an isolated fake fault test that preserves
an admitted journal and confirms owner exclusion. Then, only if real settings
need validation, one backed-up exact-process failure case with no surviving
writer, capture residual state BEFORE recovery, and test next-app-start cleanup
before any new set. Parent-only termination may allow successful helper cleanup;
that proves EOF behavior, not journal replay. If no residual exists, do not claim
recovery passed or immediately escalate to physical power loss.

Explicit retained-helper recovery is a separate alternative branch: use a fresh
controlled case and retained absolute path, without deleting the installed app
or modifying other software. Verify cleanup, clean process exit, and guarded
baseline restore. Do not combine startup and manual recovery in one case and
credit both. No new experiments or destructive actions are authorized by this
report; proposals require selecting the next scope.

VPN/RAS, hybrid shutdown, policy/security-software interference and high-load
reliability remain outside these three samples. Issue Status unchanged; no merge.
