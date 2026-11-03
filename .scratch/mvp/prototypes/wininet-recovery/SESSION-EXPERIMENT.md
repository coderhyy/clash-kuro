# One-machine manual real-logoff experiment

Prepared workflow only; no local proxy/registry mutation, carrier launch, restart,
or logoff was executed while authoring it. This is an isolated experiment, not a
migration system or a production recovery guarantee. Keep the package and private
evidence on this machine. Registry exports, PAC URLs and connection names may be
sensitive; do not commit or upload them.

The prestarted helper avoids launching a fresh WinINet process during session
ending, where our earlier one-shot tests saw `0xC0000142` / `0xC000026B`. That
motivates this test; it is not reliability evidence. Windows documents
[WM_QUERYENDSESSION](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-queryendsession)
and [WM_ENDSESSION](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-endsession)
separately: query delivery alone does not prove the session ended. The native
hidden top-level window receives these messages itself. Electron session events
are evidence only; those handlers send no IPC close, so the real native session
route is tested. Other projects are not proof of this implementation.

## Package and state contract

Build with `node .scratch/mvp/prototypes/wininet-recovery/build-session.mjs`.
It copies the Electron runtime and actual binaries to `out/session-package/`:

```text
bin/session.exe
bin/probe.exe
bin/mihomo.exe
runtime/electron.exe       (with the rest of the Electron runtime)
session-main.cjs
session-check.ps1
SESSION-EXPERIMENT.md
```

The checker finds the package beside itself, or at `out/session-package` when run
from the source prototype directory. No package path option is needed.

Always pass the absolute outside-repository data path explicitly:
`C:\Users\DT-056\kuro-session-experiment\run1` (also the script default). `prepare`
requires that directory not exist. Use a new run name for a new experiment; never
overwrite a backup. The two restart phases use the sibling
`run1-before-restart` so the actual experiment directory remains new.

The agreed native launch is:

```text
bin/session.exe arm DATA/lan-ras.bin DATA/helper-report.json bin/mihomo.exe DATA/core
```

All paths passed by the carrier must be absolute. The only endpoint is
`127.0.0.1:48967`. `prepare` snapshots LAN/RAS with `probe.exe snapshot FILE`,
verifies with `verify FILE`, and writes `core/runtime.yaml`: mixed port 48967,
IPv4 loopback bind, allow-lan false, no IPv6, MATCH,DIRECT, no subscriptions or
external controller. DIRECT exposes the machine's normal outbound connection;
this experiment provides no upstream proxy. It does not launch anything.

`carrier.json` is `{pid,startedAt,helperPid,helperStartedAt,events:[{event,at}],
ready,helperExit:{code,signal}}` (also `fixture`); `helper-report.json` is the
native armed checkpoint and final outcome. The carrier creates `attempt.json`
exclusively before launch: one attempt per backup directory, never delete or
retry it. A failed launch still consumes that directory; recover if needed,
then prepare a new run. `fixture:true` or native `fakeProxy:true` disallows a
manual real-session pass.
`startedAt` fields are carrier evidence. `before.json` separately records the OS
PID, full executable path and creation time used by recovery; it does not assume
a JS timestamp equals OS creation time. Native report fields follow `session.c`.

Native owns the actual Core process handles and the real WinINet operation. The
cleanup wait shares one 1500 ms deadline from the first close/session trigger;
later events do not extend it. Core stop is requested within 2000 ms and confirmed
within 2100 ms of that same trigger. Helper diagnostics have a 100 ms cap; these
are software budgets, not hard realtime guarantees. Timeout, self-forced helper
exit or external rescue is failed/uncertain even if manual recovery succeeds.
`coreForced:true` is allowed: real Core is stopped by exact-handle
`TerminateProcess` after cleanup, not gracefully. The carrier records its own
events. It does not auto-restore; normal carrier quit sends the helper close
frame. Real session messages are handled by the native window. Neither this
workflow nor the native fixture uses RunOnce.

## Manual command checklist

Run in a normal PowerShell window as the same Windows user throughout. Build the
package first. All commands here are for the human to run later. The launcher
arms **real system proxy settings**; signout affects all of this user's apps.

1. Save work and exit Kuro and other known proxy apps. Disable only known Kuro
   startup entries if needed; do not change other software's startup settings.
   Do not start the carrier yet. Capture the read-only
   inventory and registry export outside the repo:

   ```powershell
   Set-Location D:\clash-kuro
   $check = 'D:\clash-kuro\.scratch\mvp\prototypes\wininet-recovery\out\session-package\session-check.ps1'
   $data = 'C:\Users\DT-056\kuro-session-experiment\run1'
   & $check -Phase before-restart -Data $data
   ```

   Inspect `run1-before-restart/inventory.json`, including full commands for
   `ClashKuroSysProxyCleanup` and `ClashKuroResidentCleanup` in HKCU RunOnce (both
   registry views, including `!`/`*` prefixes). The script never deletes entries.
   If a value exists, confirm that exact name and command belong to the retired
   Kuro helper. Manually remove only that exact value using Registry Editor.
   Do not delete the key, use a wildcard, remove another app's value, or infer
   completion from a missing value. Stop if its ownership is unclear. Keep the
   JSON inventory and Internet Settings `.reg` export as evidence. No old
   executable needs deletion. The known running app/engine were `clash-verge.exe`
   and `verge-mihomo.exe`: exit/stop those through clash-verge's own UI.
   `clash-verge-service.exe` is separately informational; its presence alone is
   not a demonstrated per-user writer and does not require an admin stop.

2. Use Windows Start > Power > **Restart** after exiting those apps/removing the
   exact known values. A signout, Explorer restart or shutdown with Fast Startup
   is not this initial full Restart. The script performs no session operation.
   Sign back in; do not reopen any proxy app. If another app starts automatically,
   exit it and stop its engine through its own UI, then recheck; its startup
   settings need no changes. Recreate the two variables from step 1 in the new
   PowerShell window, then run:

   ```powershell
   & $check -Phase after-restart -Data $data
   & $check -Phase prepare -Data $data
   ```

   Stop on any error. These checks require a later boot, the same user/machine,
   no known RunOnce entries, no known writers/proxy apps and no listener on
   48967. The guard covers package paths and the named Kuro, clash-verge,
   verge-mihomo and Fiddler apps/helpers, not generic probes, hash-named binaries
   or every possible proxy product. It does not prove no other copies exist;
   two minutes of quiet would not prove global safety. This manual
   one-machine procedure relies on the human keeping old apps stopped. Proxy
   settings may change across Restart or app exit: `prepare` takes a fresh
   snapshot after those apps are closed, not from the pre-restart registry export. If
   preparation fails, preserve the partial directory and choose a new run name
   for a new attempt; do not reuse a partial backup.

3. Review the prepared files, then deliberately launch the hidden carrier:

   ```powershell
   $pkg = Split-Path -Parent $check
   & "$pkg\runtime\electron.exe" "$pkg\session-main.cjs" "--session-dir=$data"
   ```

   Wait for `carrier.json` to show `ready:true`. The carrier starts the native
   helper, which starts real Core and arms WinINet. Run the next check in a
   second PowerShell window if the first is occupied (recreate `$check/$data`):

   ```powershell
   & $check -Phase before -Data $data
   ```

   This writes `before.json` with process identities even if later checks fail.
   It requires carrier ready plus `native:ready`, and native `phase:"armed"`,
   `setVerified:true`, `fakeProxy:false` with helper `pid` and `corePid` matching
   the carrier/OS; the exact packaged carrier/helper and one live Core,
   only Core's IPv4-loopback listener at 48967, and every enumerated LAN/RAS
   connection at flags **3**, server `127.0.0.1:48967`, fixture bypass
   `localhost;127.0.0.1;[::1]`. Preserve the console output outside the repo. A
   ready flag or a running Core alone is insufficient. Do not repeat `before`
   against the same run; keep its original evidence. If the check fails, stop
   the experiment and follow recovery below.

4. With the carrier still running, use Windows Start > user > **Sign out**.
   Do not quit Electron first or inject fake session messages. Sign back in;
   keep all proxy apps closed and do not relaunch this carrier. Recreate
   `$check/$data`, then collect:

   ```powershell
   & $check -Phase after -Data $data
   ```

   `after` only reads the identity, process/listener inventory, known RunOnce,
   saved reports, Winlogon/Explorer timing and current WinINet state. It creates no files or restore
   notifications. Preserve this output yourself before recovery. Missing files
   print as uncertain. A malformed file or inaccessible OS state may refuse
   collection; keep the raw files for inspection.

5. After recording the outcome, restore the original saved LAN/RAS fields:

   ```powershell
   & $check -Phase restore -Data $data
   ```

   Keep the entire run directory and restart inventory after recovery. No phase
   imports a `.reg` file or restores the registry wholesale. The `.reg` export is
   a reference, not a recovery command. The binary `lan-ras.bin` is immutable and
   hash-checked against `prepared.json`.

## Outcome and recovery limits

Read `helper-report.json`: require `phase:"shutdown-complete"`, `decision:"cleared"`,
`operationError:0`, `selfForced:false`, native
`firstTriggerSource` such as `WM_QUERYENDSESSION`, actual `querySession`/`endSession`
counts and flags, `cleanupReadbackVerified:true`, `cleanupWithinBudget:true`, and
`coreGone:true`. Inspect `readbackEndEpochMs <= coreStopRequestEpochMs`
and the source's decision/stop/confirmation timing against 1500/2000/2100 ms.
`coreForced:true` alone is not failure; it describes intentional exact-handle
Core termination. The clear/readback must precede the next login, using the
Winlogon/Explorer timing and the user's actual signout action; a missing timing
anchor must be disclosed, not replaced with post-login flags alone. These fields support manual assessment, not an automatic
success verdict. After
sign-in, WinINet should report flags **1**, retaining the fixture server/bypass
and original PAC string; inspect every LAN/RAS row, not only the LAN. Successful
manual restore should match the original snapshot, whose flags need not be 1.

Electron `events` only establish what Electron observed. They cannot prove the
native window received session messages, that WinINet completed before Core
stopped, or that the native deadline was met. An absent/truncated report, only
Electron events, post-login flags alone, a timeout, or external process rescue
is not session-cleanup success. Do not turn a successful restore into a passing
session result. One logoff on this machine says nothing about all Windows builds,
RAS configurations, shutdown, or hard power loss.

Recovery refuses known proxy apps/writers, known Kuro RunOnce, any live packaged
carrier/helper/Core/probe path, any listener on 48967, incomplete recorded process
identity, or an old PID whose reuse cannot be classified. It compares recorded
full executable paths, PIDs and OS creation times; it never kills an old process
by name or PID. A missing `before.json` still requires complete current inventory
and absence of every packaged executable; missing `prepared.json`, a changed
backup, or wrong user/machine/package refuses restore.

Exit any identified competing app normally and retry only after it is gone. If
the experiment's hidden carrier/helper will not exit normally, use a manual full
Restart, then collect `after` before retrying restore. Do not run another proxy
app in between. Unknown state means **stop with a diagnostic**, not an infinite
HOLD or an instruction to blindly kill processes.

The checker serializes restore attempts for this run. Its only process kill is
its own exact probe child after a 10 s timeout/error; it then waits up to 5 s for
that child's exit before releasing recovery. Timeout is failure and may mean a
partial restore. It never immediately starts a second restore. A recorded
unconfirmed attempt (including controller crash) refuses further restore until
a manual full Restart establishes its old child cannot still run. Preserve all
`restore-attempt-*.json` records. An exited failed attempt can be retried only
through the same preflight. This does not coordinate independent tools: do not
run raw probe restore or another experiment/controller concurrently.

Finally, `probe.exe restore FILE 127.0.0.1:48967` itself checks that the complete
LAN/RAS connection list matches, and each current row is either the saved state
or exactly the fixture's flags 1/3, endpoint, bypass and preserved PAC. Unrelated
settings cause refusal before writes; a concurrent change can stop a partially
completed restore. Keep snapshots and investigate instead of forcing it. The
checker verifies the baseline afterward; neither notification success nor
process exit alone is acceptance.

## Authoring validation (no experiment execution)

Parse the script without invoking it; this does not run a phase or start a probe:

```powershell
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  'D:\clash-kuro\.scratch\mvp\prototypes\wininet-recovery\session-check.ps1',
  [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
```

Local validation on 2026-11-03: warning-clean native builds; pure backup/argument
self-tests; PowerShell parser and pure conflict guards; packaged Electron 45.1.0
with real isolated Core and fake proxy (normal, clear-hang, readback-hang). Both
hangs reported timeout and exited without external rescue. Existing coordination
suite: 18/18 expected policies. Workspace typecheck passed; uncached full tests
passed, including desktop 596/596 with no skips. These results do not exercise
real proxy writes or real session events. This package still needs the one manual
logoff described above; earlier CI WinINet evidence is not its acceptance.
