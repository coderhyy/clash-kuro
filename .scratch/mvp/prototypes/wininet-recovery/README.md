# Guarded WinINet backup / restoration fixture

2026-11-02. Independent prerequisite for the prestarted-helper experiment, not
the resident helper implementation. The shipping C operations and endpoint
checks are included directly; the fixture passes `manage_recovery=0` and never
writes or deletes RunOnce. It does not start Core or send session messages.

## Current evidence

- Existing compiler, warnings-as-errors build passed.
- Pure restoration-state guards and six malformed-backup cases passed.
- Read-only LAN/RAS snapshots and exact baseline verification passed. Latest:
  `C:\Users\DT-056\kuro-sysproxy-backups\wininet-1793590661881`.
- **No local set, clear, notification or restore has been executed.** Other proxy
  applications were running. Actual writes/restoration and prestarted WinINet
  notification behavior remain unverified; do not treat this as 2B success.

The Windows CI job now also runs the guarded exercise on its own ephemeral
runner, after all Core fixtures have exited. This is not the user's Windows
10/11 desktop: a CI result must not substitute for target-machine notification
or session evidence. No competitor check, backup, writer-exit gate or restoration
check is bypassed. RunOnce is read again and compared after restoration; missing
RunOnce keys are handled without creating them. Only the verified result summary
is uploaded, not the raw registry export or baseline fields.

CI `41388311489` (`4716fa8`) passed the actual WinINet cycle and restoration,
along with both full CI jobs. Downloaded `kuro-wininet-recovery-evidence` to
`out/ci-41388311489/verified.json`: `restoredAndVerified=true` and
`runOnceUnchanged=true`. The runner's outside-repository backup was
`C:\Users\runneradmin\kuro-sysproxy-backups\wininet-1793593619146`.
This proves the shared one-shot API path and restored final state on that
runner, not the resident thread/window notification path or target-machine RAS
connections. No claim of a 1500 ms operation budget is made for this fixture.

The follow-up tightens this evidence: after set and after clear, query every
enumerated connection and require flags 3/1 respectively, the fixture endpoint
and bypass, and the preserved PAC string. API success alone is insufficient.
The summary includes the number of connections and observed set/clear timings
(including notifications, excluding subsequent verification). The updated
verification still needs its own CI result; local builds and parser/state-guard
tests do not exercise proxy writes.

## Supervised output defect and native-thread bridge

CI `41389190950` failed while parsing the new evidence, after guarded restoration:
stdout was empty. The supervisor did not explicitly pass standard handles to a
GUI child. A local **read-only get** regression reproduced the missing JSON.
It now duplicates and allowlists only stdin/stdout/stderr with STARTUPINFOEX;
the Job handle remains private. Rebuilding made that regression pass. No state
assertion was removed, and the failed CI run remains failed.

`resident.c` now bridges the same shipping clear function into the already
tested helper coordination model. It first verifies a fresh baseline and sets
the isolated endpoint without recovery registration. It then creates the native
window/threads and fake Core, and posts a private WM_APP trigger. Real clear
and its WinINet notifications run on the worker; the native window uses either
plain or message-aware waiting. The same 1500 ms deadline, Core stop ordering,
supervisor, exact Core handle and uncertain-process exit remain in use. An API
failure is reported as `failed`, not falsely called a timeout or success.

This is deliberately not production startup or a full resident protocol: setup
set precedes the coordination phase, there is no Electron carrier in this bridge,
and no OS session event is synthesized. It tests real WinINet clear against the
native wait model, not real session delivery/survival or an unresponsive Electron
window. The synthetic Electron cases remain separate evidence.

After building, the write commands are:

```powershell
node .scratch/mvp/prototypes/wininet-recovery/run.mjs --exercise --resident=plain
node .scratch/mvp/prototypes/wininet-recovery/run.mjs --exercise --resident=aware
```

These are enabled on the isolated CI runner; **do not run locally while the
other proxy applications are present**. Both keep the existing outside-repo
backup, competitor checks, whole-writer-Job exit gate and guarded restoration.
Each successful summary contains the native shutdown report and post-operation
state evidence. An uncertain result fails the fixture even if restoration works.
The controller now also retains its writer lock when restoration is required
but failed/refused; an empty old Job alone is insufficient to resume writes.
Pure tests reject rescued, nonzero, nonempty or incomplete exit evidence.

## CI bridge result

Run `41390975216` (`3ea3673`) passed both full CI jobs on 2026-11-02. The Windows
job identifies its OS as Windows Server 2025, image `windows-2025-vs2026`.
Downloaded summaries are in `out/ci-41390975216/`:

| Mode | Connections | Set flags / clear flags | API set / clear observation | Result |
| --- | --- | --- | --- | --- |
| one-shot | 1 (LAN) | 3 / 1 | 16 / 0 tick-ms | Verified, restored |
| native plain wait | 1 (LAN) | 3 / 1 | 0 / 0 tick-ms | Clear completed, fake Core exited normally, restored |
| native aware wait | 1 (LAN) | 3 / 1 | 0 / 0 tick-ms | Clear completed, fake Core exited normally, restored |

All three verified the endpoint, bypass and preserved PAC string and confirmed
RunOnce unchanged. Both native-mode summaries contain `decision=cleared`, one
operation/one Core stop, `coreGone=true`, `selfForced=false` and the original
1500 ms clear deadline. Acceptance also requires the writer Job to be empty
without external rescue before any restoration. **0 tick-ms means no clock tick
elapsed in GetTickCount64, not instantaneous completion or a precision latency
benchmark.** Source/event ordering, not equal coarse timestamps, establishes the
clear-decision-before-Core-stop sequence.

The synthetic plain-wait deadlock did not recur for these actual API calls on
this runner. That neither establishes nor excludes a real notification
dependency on other Windows versions, Electron windows, RAS, or session ending.
No RAS connection was present, and there was no Electron carrier in this bridge.
The user's desktop settings were never changed by these tests. The stdout defect
from the preceding failed CI is now covered by a passing read-only regression.

The latest local read-only backup after this script change is
`C:\Users\DT-056\kuro-sysproxy-backups\wininet-1793593360809`.

## Commands

From `D:\clash-kuro`, using the already installed compiler:

```powershell
node .scratch/mvp/prototypes/wininet-recovery/build.mjs
node .scratch/mvp/prototypes/wininet-recovery/test.mjs
node .scratch/mvp/prototypes/wininet-recovery/run.mjs
```

The default run is read-only. It exports Internet Settings to a directory
outside the repository, captures the current RunOnce value read-only, and saves
LAN plus every enumerated RAS connection (name, flags, server, bypass, PAC URL).
A versioned binary snapshot preserves UTF-16 values. Snapshot creation fails on
incomplete RAS enumeration, failed query, oversized fields or incomplete write.
Null and empty strings compare equally; raw snapshot values are retained.

Only after all competing proxy applications are closed, the authorized write
fixture is:

```powershell
node .scratch/mvp/prototypes/wininet-recovery/run.mjs --exercise
```

This creates a NEW backup immediately before testing. It checks the baseline,
sets LAN/RAS to manual `127.0.0.1:48967`, clears that endpoint using the shipping
ownership rules, saves a post-cycle snapshot, restores the original four fields
through WinINet, sends notifications and verifies the restored state. No listener
exists at the fixture endpoint: applications using System Proxy may briefly lose
connectivity. It must not be run while the user needs uninterrupted proxy access.

To retry guarded restoration of a specific experiment backup:

```powershell
node .scratch/mvp/prototypes/wininet-recovery/run.mjs --restore="C:\Users\DT-056\kuro-sysproxy-backups\wininet-1793590661881"
```

This read-only baseline currently needs NO restoration. The command is shown for
recovery, not an instruction to execute it now. Do not blindly `reg import` the
export: that can overwrite newer settings belonging to other software.

## Safety and stop conditions

- An exclusive `writer.lock` under the backup root prevents concurrent fixture
  controllers. A crashed controller or missing writer-exit evidence leaves the
  lock in place. **Do not delete it and retry blindly**; inspect the exact test
  process/Job evidence first. PID absence alone is not restoration permission.
- Every native invocation runs in the existing external watchdog's unnamed Job,
  assigned before process resume. The Job tracks only its own process tree.
  Before any restoration the previous writer's report must confirm `remaining=0`.
  Missing report/nonempty Job stops the script and retains the lock and backup.
- External termination still FAILS the experiment even when restoration is
  subsequently possible. It is test rescue, not implementation success.
- Restoration preflights the entire connection list and each connection again
  immediately before writing. It accepts the exact baseline or the fixture's
  exact endpoint/bypass/original-PAC with flags 1/3. New RAS entries, a foreign
  endpoint, unexpected flags/PAC/bypass, incomplete RAS enumeration or a policy
  override stop restoration instead of overwriting them.
- This is not a transaction against other proxy software. A third-party writer
  that ignores our lock can race the last check; detection is conservative but
  cannot prove exclusion. Partial writes outside the recognized fixture state
  require diagnosis instead of automatic broad registry restoration.
- Per-invocation watchdog budget is 10 seconds, with an outer 16-second guard.
  These are fixture rescue limits, NOT the product's 1500 ms cleanup budget and
  NOT evidence of bounded WinINet execution.

The prototype's shared functions no longer leak their per-command JSON or RAS
enumeration buffers. Separately, production get/set/clear now report failure
when RAS enumeration is incomplete; clear retains RunOnce. The native fake test
in `apps/desktop/native/win/connections_test.c` reproduced the previous false
success before the fix and never calls real mutation APIs on its test paths.
