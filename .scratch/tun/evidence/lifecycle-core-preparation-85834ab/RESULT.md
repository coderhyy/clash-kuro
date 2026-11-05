# Frozen fixed-Core LaunchDaemon experiment — prepared, not executed

Source `85834ab8bc8d45c24f232883133a58d13b2daa6f`. Candidate directory `/private/tmp/kuro-lifecycle-core-review-85834ab`.

- `lifecycle-a` SHA256: `e5c949f29785297b8ba8ac5a5be76f8483dea17d0bf7daf20860cbd33daeb1f1`
- `approval.json` SHA256: `c20eb39a0032b73a4b6b5b229377642f2504aac30b77fe9ae592b3bb5ed29ec1`
- `artifact.json` SHA256: `cda70df87fd0b2c4dae1890547f313d31d845aba04a29bad5be2f570c8da68e5`
- Fixed Core SHA256: `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`.

Ordinary-user preparation verified current HEAD, clean source inputs and every source blob before/after compilation. Complete 11-entry SHA256SUMS and frozen harmless-child self-test passed. Independent reviewer rechecked all 23 source blobs, all payload bytes, both deterministic configurations/epochs, fixed plist paths/flags and 93/91-byte Unix socket paths. No Core, Core `-t`, root job or system network action was run by preparation.

## Proposed dedicated non-network window

Estimate 10–15 minutes plus administrator prompts. This is a new combination of real fixed Core and root LaunchDaemon death testing; it is not covered by the earlier ordinary-UID normal/EOF execution or harmless fixture A result. Do not execute without specific window authorization.

1. Recheck full digests, absence of exact label/targets, protected ancestors and baseline. Install only the fixed experiment binary, plist and private experiment directory. No production helper/App installation or third-party modification.
2. Run normal epoch. Require exact private readiness, same process group, two NoIP observations, held-child stop/reap, durable success, job runs1/exit0 and independent exact process/group/work/owner absence. Failure prevents stage3.
3. After independent normal verification, switch the same unloaded job to its distinct kill epoch. Recheck live executable/start/group identities and bounded readiness; signal only the exact launchd job label. Require actual supervisor/Core and entire group absence at the bounded observations. A timeout fallback is a failure, not launchd success.
4. Retire only the verified experiment job after absence checks. Save outputs and final state. The driver deliberately retains fixed binary/plist and the root evidence directory, including kill-stage owner/work/cache. These retained artifacts are not a completed uninstall or production recovery result. No blanket deletion or old PID/PGID signal is authorized by the driver. Any subsequent cleanup must inventory exact known objects; unknown content remains preserved.

Fixed scope: `system/dev.kuro.tun.lifecycle-a`, `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a`, `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist`, `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA`. Two pinned Core copies and the exact experiment logs are inside the latter directory. Config keeps TUN/DNS/NTP/sniffer/IP listeners/providers off, using only the private Unix controller. No system proxy/routes/DNS/login-item changes, logout/reboot/shutdown or third-party changes.

Stop on pin/path/identity mismatch, unexpected process/socket, failed normal evidence, timeout, unknown/live remaining process or inability to confirm retirement. While the supervisor still holds its original direct child, only its existing bounded stop is allowed. After supervisor death, recorded PID/PGID is observation-only; no wider signal, reset or deletion. Preserve evidence and report the exact live/unknown state instead of expanding recovery.

This experiment can supply a missing process-group observation for recovery design. It does not test utun, routes/DNS cleanup, actual Electron exit, production restart recovery or prove all possible detached descendants absent.
