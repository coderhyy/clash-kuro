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
- **No set, clear, notification or restore has been executed.** Other proxy
  applications were running. Actual writes/restoration and prestarted WinINet
  notification behavior remain unverified; do not treat this as 2B success.

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
