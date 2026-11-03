# Formal app: minimal Windows manual acceptance

Status: procedure only; **not executed or accepted**. Actual final artifact and
data paths are pending. Run serially on the target Windows desktop, never beside
Core/resource tests, other proxy experiments or another restore controller.
This tests the formal packaged app, not the historical isolated session package.
No migration/checker framework, synthetic session messages or RunOnce setup.

## 1. Supply paths and obtain a quiet baseline

Save work and arrange a connectivity interruption. Use the same Windows user
throughout. Disable/avoid app auto-launch after login for these trials using the
normal user setting; otherwise startup cleanup could mask session failure.
Have an operator review each checkpoint before any session-ending action.
The final artifact must contain the current resident implementation; retain its
build/source identity and actual executable hashes, not a guessed output path.

In PowerShell, replace every placeholder with a supplied/observed absolute path:

```powershell
$tools = 'D:\clash-kuro\.scratch\mvp\prototypes\wininet-recovery'
$appExe = '<PENDING_FINAL_FORMAL_APP_EXE_PATH>'
$dataDir = '<PENDING_ACTUAL_APP_DATA_DIRECTORY>'
$evidence = '<PENDING_ABSOLUTE_OUTSIDE_REPO_EVIDENCE_DIRECTORY>'
$case = Join-Path $evidence 'normal-quit'
New-Item -ItemType Directory -Path $case -ErrorAction Stop | Out-Null
Get-FileHash -LiteralPath $appExe -Algorithm SHA256 |
  Format-List | Out-File -LiteralPath "$case\artifact.txt"
```

`$dataDir` is the app's actual `userData\data`, confirmed for this artifact/user;
do not invent a `--data-dir` app flag. Use a controlled supplied profile/settings
with mixed-port **48967**, System Proxy initially off and no unintended auto-start.
Do not launch merely to discover paths/settings before taking the backup below.

At each checkpoint, set `$checkpoint` to a NEW label and save this read-only
inventory. Reuse these commands for `quiet`, `before-quit`, `after-quit`, and the
corresponding `before-logoff`/`after-login`/`before-shutdown`/`after-power-on` labels:

```powershell
$checkpoint = 'quiet'
Get-Date -Format o | Out-File -LiteralPath "$case\$checkpoint-time.txt"
Get-CimInstance Win32_OperatingSystem -ErrorAction Stop |
  Select-Object Caption,Version,LastBootUpTime |
  ConvertTo-Json | Set-Content -LiteralPath "$case\$checkpoint-os.json"
whoami.exe /user | Out-File -LiteralPath "$case\$checkpoint-user.txt"
whoami.exe /logonid | Out-File -LiteralPath "$case\$checkpoint-logon.txt"
Get-CimInstance Win32_Process -ErrorAction Stop |
  Select-Object ProcessId,Name,ExecutablePath,CreationDate,CommandLine |
  ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$case\$checkpoint-processes.json"
Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq 48967 |
  Select-Object LocalAddress,LocalPort,OwningProcess |
  ConvertTo-Json | Set-Content -LiteralPath "$case\$checkpoint-listeners.json"
reg.exe query HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce /reg:64 2>&1 |
  Out-File -LiteralPath "$case\$checkpoint-runonce64.txt"
reg.exe query HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce /reg:32 2>&1 |
  Out-File -LiteralPath "$case\$checkpoint-runonce32.txt"
```

Before backup/launch, review PID, full path, creation time and command line:
- Close known proxy apps through their own UI: Clash Kuro, clash-verge, Fiddler /
  Fiddler Everywhere, mihomo / verge-mihomo, sing-box, v2ray / v2rayN.
- Require no `kuro-sysproxy.exe` or retained 64-hex-name `.exe` under
  `%LOCALAPPDATA%\ClashKuro\Recovery` (including children). An unreadable hash
  process path is unknown: stop and identify it, not permission to continue.
- `clash-verge-service.exe` is informational, consistent with session-check;
  record it, do not broadly stop services. If it is observed changing settings
  or owning port 48967, stop; the exception is not proof of writer exclusion.
- Require port 48967 free. Inspect renamed/unclassified apps too; name matching
  is only a known-competitor guard, not a complete proof against other writers.
- RunOnce keys may be absent. If either view has `ClashKuroSysProxyCleanup` or
  `ClashKuroResidentCleanup` (also names prefixed with `!`/`*`), stop and report.
  No registration, deletion, migration or login recovery is part of this trial.

## 2. Back up BEFORE launching the app

Use the existing, built `out\probe.exe` and `out\watchdog.exe` supplied/reviewed
with the tools; record their hashes. This command exports registry reference
files and snapshots/verifies LAN plus every enumerated RAS connection. It writes
backup/evidence files only, not proxy settings or RunOnce:

```powershell
node "$tools\run.mjs" | Tee-Object -FilePath "$case\backup-console.txt"
if ($LASTEXITCODE -ne 0) { throw 'STOP: backup failed; do not launch app' }
if (Test-Path -LiteralPath "$dataDir\settings.json") {
  Copy-Item -LiteralPath "$dataDir\settings.json" -Destination "$case\settings-before.json" -ErrorAction Stop
}
$backup = '<ACTUAL_BACKUP_DIRECTORY_PRINTED_BY_RUN_MJS>'
Get-Content -LiteralPath "$backup\manifest.json"
Get-FileHash -LiteralPath "$backup\lan-ras.bin" -Algorithm SHA256 |
  Format-List | Out-File -LiteralPath "$case\baseline-hash.txt"
$backup | Set-Content -LiteralPath "$case\backup-path.txt"
```

Require `Verified read-only backup`, complete snapshot and verify reports, and
clean supervisor exits: `rootExitCode=0`, `remaining=0`, `watchdogKilled=false`,
`lingeringChildren=false`, no outer error. Preserve the original backup unchanged.
`lan-ras.bin` + exact WinINet verification are the authoritative original flags,
server, bypass and PAC for LAN/RAS. The `.reg` export is reference, not an
instruction to import. Backups/process commands may contain secrets: keep them
outside the repo; share only redacted evidence. Never use an old example backup.

## 3. Normal quit first

1. Launch only `$appExe` (normal interactive launch). Record actual app/helper/Core
   paths, SHA256, PID and creation time; identify retained helper/journal paths.
   Record the pre-existing length/end of `$dataDir\sysproxy-owner.log` so old
   reports cannot count for this run. `exit.log` is best-effort diagnostics only.
2. Confirm mixed-port **48967** in app settings before enabling System Proxy.
   Start the controlled profile/Core, then enable System Proxy. Record UI state,
   native set/readback evidence and the port listener's exact Core identity.
   Expected owned state: flags 3, server `127.0.0.1:48967`, bypass exactly
   `localhost;127.0.0.1;[::1]`, original PAC preserved on every connection.
   A different endpoint/bypass/PAC is STOP, not a reason to weaken restore guards.
3. Save `before-quit` inventory and the read-only probe below, plus a copy of the
   native log. Review ownership/state before proceeding. Quit via the tray
   **Exit** item, not window X (which can leave tray mode running). Note UTC action time.
4. Without relaunching the app or restoring, save `after-quit` inventory, probe
   and native log. Require matching new native shutdown evidence and app/helper/
   owned Core death, not merely an absent window or free port. Compare the exact
   recorded PID/path/creation-time identities; PID reuse/unreadable evidence is
   unknown. Correlate native `coreGone` with the recorded Core and process evidence.
5. Review section 5, then restore using section 6. Only after both the normal-quit
   review and verified baseline restoration may the native session cases proceed.

For each before/after checkpoint, this is the existing read-only `get`, supervised
by the existing watchdog (use the current `$checkpoint`, never overwrite files):

```powershell
& "$tools\out\watchdog.exe" 10000 "$case\$checkpoint-get.supervisor.json" `
  "$tools\out\probe.exe" ('"{0}" get' -f "$tools\out\probe.exe") |
  Set-Content -LiteralPath "$case\$checkpoint-get.stdout.jsonl"
if ($LASTEXITCODE -ne 0) { throw 'STOP: read-only probe failed' }
Copy-Item -LiteralPath "$dataDir\sysproxy-owner.log" -Destination "$case\$checkpoint-sysproxy-owner.log"
```

Inspect both the probe JSON and supervisor report; apply the same clean-exit
requirements as backup. Missing/failed/rescued observation is not success. Do not
run unbounded direct probe writes, `--exercise` or `--resident` for app acceptance.

## 4. Native Windows logoff, then full shutdown

Run two independent cases, `$case = Join-Path $evidence 'native-logoff'` and then
`'native-fullshutdown'`, creating each new directory. Repeat quiet inventory,
**fresh pre-launch backup**, launch/48967/set, and before checkpoint from sections
1-3. Record/review the native owner/Core identities, running state, log offset,
original backup path/hash, boot time and logon identity before the human proceeds.
Do NOT tray-quit first: the live native owner must receive Windows session events.

- Logoff: use the real Windows **Sign out** UI. After actual sign-out, sign in as
  the same user and record that a new logon session occurred (boot may be unchanged).
- Full shutdown: only after logoff evidence and baseline restore pass, save all
  work, record UTC, and have the human run `shutdown.exe /s /t 0`, then manually
  power on. No `/f`, `/hybrid`, Restart, power cut or persistent power-setting
  changes. Record actual power-off/on and a new boot time; requested shutdown
  alone does not prove it completed.

After each login/power-on, reestablish the SAME supplied paths and that case's
saved `$backup`; **before reopening Kuro or restoring**, save after inventory,
read-only probe, and `sysproxy-owner.log`. Record login/boot anchors and whether
anything auto-launched. Require native cleanup/readback/Core-stop timestamps
before the new login (and shutdown completion/boot where applicable), with actual
native query/end session evidence. EOF/IPC alone is not session-delivery proof;
a query event alone is not proof the session ended. Then review and restore.

If sign-out/shutdown is canceled or blocked, label the case **canceled, stopped /
unknown**, not passed. The first session trigger still closes the write gate and
stops owned Core; the surviving app must not resume Core/proxy writes or accept
re-enable as if running. Preserve logs/state, verify stopped identities and review
recovery before any fresh launch. Do not force completion, auto-resume, retry in
the same evidence directory, or credit later startup/manual recovery as session
cleanup. Unexpected automatic launch makes the original session result unknown.

## 5. Review native evidence and timing

For each case retain the new `closing` and `shutdown` JSONL records from
`<ACTUAL_APP_DATA_DIRECTORY>\sysproxy-owner.log`, correlated by native PID, Core
PID, protocol 3, trigger time and case boundaries. App `exit.log` is supplementary;
UI/API success, a cleared proxy after next launch, or a journal alone is not proof.

- Require `ok=true`, `timedOut=false`, `coreGone=true`,
  `cleanupReadbackVerified=true`; inspect `clearResult` and `cleanupReadback` for
  every LAN/RAS entry and flags 1 / disabled owned manual proxy after cleanup.
- Report `firstTrigger`, `firstTriggerEpochMs`, `triggerMask`, `queryEvents`,
  `endEvents`, `querySessionFlags`, `endSessionFlags`, `queryEpochMs`, `endEpochMs`.
  Session bits are 16 (WM_QUERYENDSESSION) / 32 (WM_ENDSESSION); preserve any
  IPC/EOF co-trigger (2/4). Normal quit need not have native session events.
- Report `clearStartedMs`, `clearCompletedMs`, `readbackCompletedMs`,
  `cleanupDurationMs`, `coreStopRequestedMs`, `coreConfirmedMs`, `durationMs`.
  All relative timings share the immutable first-trigger deadline: cleanup plus
  readback/decision <1500 ms, Core stop request <=2000 ms, confirmation <=2100 ms,
  report/exit software budget about 2200 ms. Never restart the budget on later
  triggers. Retain observed values, nulls and limits; no hard-real-time claim.
- Require clear/readback decision before Core stop request, then confirmed Core
  death. Equal coarse tick values do not prove zero latency or reverse source
  ordering; contradictory/missing timing is failed/unknown, not rounded to pass.
- Windows Core stop is the existing **forced owned Job/handle method**, reported
  as `coreStopMethod="TerminateJobObject-owned-job"`, NOT POSIX graceful SIGTERM.
  This expected Core termination is distinct from helper self-forcing, OS-forced
  cleanup or external watchdog rescue, none of which counts as accepted success.

## 6. Guarded restoration and case report

First prove the independently launched app, native owner and owned Core are gone
using recorded identities, native evidence and fresh process/listener inventory.
The watchdog only proves its own probe tree empty; `run.mjs`'s competitor snapshot
or writer lock does NOT establish formal-app death or exclude a third-party race.
No broad `taskkill`, service stop or registry write is authorized by this document.

With that review complete and no competing writer, use the ORIGINAL case backup:

```powershell
node "$tools\run.mjs" "--restore=$backup" |
  Tee-Object -FilePath "$case\restore-console.txt"
if ($LASTEXITCODE -ne 0) { throw 'STOP: restore failed/refused; preserve evidence' }
Copy-Item -LiteralPath "$tools\out\verified.json" -Destination "$case\restored-verified.json"
```

Retain all backup-directory restore/verify supervisor reports and stdout; require
clean exits, `restoredAndVerified=true`, `runOnceUnchanged=true` and unchanged
snapshot hash. Re-capture RunOnce views and compare the known entries to preflight:
the tool itself compares only the legacy `ClashKuroSysProxyCleanup` value.
Successful app clear is NOT restoration of original settings; only the exact
post-restore LAN/RAS verification is authoritative for baseline restoration.

The existing restore preflights all connections, then each again before writing:
it accepts exact baseline OR flags 1/3 with exactly `127.0.0.1:48967`, the bypass
above and original PAC. A new RAS entry, foreign endpoint/port, policy override,
changed PAC/bypass or unknown state must refuse restoration. Do not bypass this,
blindly import `.reg`, delete `writer.lock`, retry uncertain writes or overwrite
another app's settings. Keep evidence and request exact-process/state diagnosis.
Startup cleanup/manual retained-helper journal recovery remains available only as
a separately reviewed recovery action, never automatic RunOnce/login recovery or
a substitute for baseline verification/session success.

Report per case: actual artifact/build + hashes, OS/user/boot/logon anchors,
backup path/hash, app/helper/Core identities, action and before/after times,
native triggers/readback/timing table, process-death evidence, any cancellation,
rescue/unknowns, and independent app outcome vs baseline-restore outcome. A rescue
remains a failed trial even if safe restoration later succeeds. No native report,
timeout, uncertain writer death or missing observation can count as pass. Do not
advance to the next case until both evidence review and restoration are complete.

Changing mixed-port is an app setting, not part of the LAN/RAS restoration.
Keep the private `settings-before.json` (it can contain subscription secrets).
After the sequence, restore the original port through the app UI with System
Proxy off; do not blindly overwrite the live settings file or recovery journal.
