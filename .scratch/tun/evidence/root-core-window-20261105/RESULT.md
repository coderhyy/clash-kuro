# Root no-network window: normal observer failed; kill not executed

Authorized frozen experiment source `85834ab8bc8d45c24f232883133a58d13b2daa6f`, cleanup source `436c480f11483b1fffbf60b6d810d264e9c29930`. All 11 inventory entries, explicit fixture/approval/artifact pins, and cleanup bytes against its commit passed before installation. Exact job and installation targets were absent. Installed only the dedicated experiment files.

## Current state after separately authorized recovery

User separately approved source `ecb303c9215f935258e384ae4d963159df728a89` and recovery SHA256 `29c5fc0ae37902f77a89ed1f03ff2fcaeabe4dbad541d096d24ab6432a61fd27`. Before execution the script was matched byte-for-byte to that commit; all original 11 inventory entries and independent observer dependency were rehashed unchanged.

The unchanged recovery entry returned exit0 after its protected-install/normal-receipt/job and repeated independent kernel process/group checks, performing only exact job bootout. A separate host `launchctl print system/dev.kuro.tun.lifecycle-a` returned 113 with `Could not find service`. **The job is now absent; all four installation files and evidence remain.** No Core or fixture was started, no file deleted, no network changed. Logs: `/private/tmp/kuro-root858-window-jjwvtwqy/authorized-normal-retirement.log` and `independent-job-absent.json` (0600). The earlier failed-normal/retire and loaded-job snapshots below remain historical evidence, not current state.

New user policy: acceptance and recovery have independent strict evidence conditions. Within the already approved experiment scope, repairs needed only to stop/unload this exact job may be rebuilt, reviewed and rehashed without per-script reconfirmation. This does not authorize a new Core start, network change, unknown-file deletion, or old-PID/PGID signal. No root normal/kill repeat is scheduled now; protocol and recovery regressions come first.

## Real result

Native normal completed private version and typed mode/selection readbacks, held-child SIGTERM and wait/reap: Core exit0; native result and normal-success report passed with childReaped/workAbsent/ownerAbsent true. Core stdout contains configuration completed and `Mihomo shutting down`; stderr empty. Supervisor PID59038, Core PID59066, inherited PGID59038. Exact normal job: runs1, not running, last exit code0.

The driver normal operation nevertheless failed: `exact process/group absence unproven`. Read-only native inspect returned supervisor/child absent, groupMembers empty, owner/work absent, but `groupObservationKnown: 1` (JSON number). `@(members!=nil)` boxes a C comparison as an integer; the Python driver requires `is True`. This is an observer wire-type defect, not a Core startup failure. Native evidence does not override the failed full-stage gate.

Kill was NOT executed. No launchd forced group-cleanup or timeout-fallback result exists. The normal Core stopped by held-child SIGTERM; do not attribute it to launchd kill cleanup.

The authorized unchanged `retire-normal` recovery was attempted and failed at the same strict check before bootout. No bypass or recorded PID/PGID signal was used. Final read-only job state remains loaded but not running, runs1/exit0; fixed plist RunAtLoad=false, KeepAlive=false. Four-file success-only cleanup was NOT run.

## Retained objects after recovery

- `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a`: frozen experiment binary, retained because the authorized recovery only unloaded the job.
- `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist`: exact normal epoch plist; the job has been unloaded, while the plist file remains.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/normal/mihomo` and `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/kill/mihomo`: fixed Core copies, neither deleted.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/approval.json`: root0600 source/epoch binding.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/normal/`: root0700; attempt/config.redacted/launch/evidence/reaped/result/normal-success and stdout/stderr evidence root0600. No owner.json or session-work remained at observation.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/kill/`: root0700; only mihomo, no attempt, owner or work: stage never started.
- `/private/tmp/kuro-root858-window-jjwvtwqy`: user0700; preflight/install/normal/inspect/retire logs and final read-only root inventory/job evidence, files0600. Preserve for diagnosis; no user Profile/credentials recorded.

The original frozen review and cleanup directories remain unchanged. No Installer receipt exists. The separately authorized narrow recovery above has unloaded the exact stopped job after fresh identity/absence checks. The success-only cleanup cannot handle this failed-normal case; precise file retirement remains part of a future approved window. No recursive deletion is proposed. Retained diagnostics may be archived/deleted only after recovery is recorded and no unresolved ownership/diagnostic need remains.

No TUN, DNS service or public proxy listener was enabled; no system proxy/routes/DNS/login-item/third-party settings were changed. The observed no-IP checks are bounded observations, not an OS network sandbox. The window ended after the failed agreed recovery and final inventory; authorization is not carried to another experiment.

## Offline correction after the window

The future experiment source now uses a typed BOOL in its actual observer result builder. The strict Python boolean gate is unchanged. A real Foundation JSON serialization regression first reproduced the int/bool error, then passed eight boolean combinations and the legacy-number refusal boundary; 16 driver tests passed after integration (1.402s). The existing kill-unknown fixture now uses a temporary BASE instead of inspecting the installed root directory. A non-author reviewer approved the two-file patch. Full experiment branch strict compilation passed without execution. Frozen/installed bytes remain unchanged; no retry or new recovery operation was performed. Author patch SHA256 `dcca4952223702bbf550f83e47fb582b247019e76b4a1c82293e218c5e1f41a7`; evidence `/private/tmp/kuro-root858-observer-bool-candidate`.
