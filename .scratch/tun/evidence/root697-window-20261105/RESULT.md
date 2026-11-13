# Root697 no-network window — normal and kill passed, exact cleanup complete

Authorized source `69728e6abeb27f45f1bbea5b47b5e638d5f0ae9e`; unchanged frozen review `/private/tmp/kuro-lifecycle-core-review-69728e6`. Main rehashed all13 inventory entries, explicit approval/artifact/driver/fixture/Core/cleanup/archive pins and all four old archive dependencies, then ran the actual packaged offline review before system operations. The approved stages ran once in order; no rebuild, bypass, old-PID signal or retry occurred.

## Actual results

- `archive-old`: retired only the old four installation files and exclusively archived the old evidence.
- `install`: fresh fixed files installed, identity verified, no start during installation.
- `normal`: actual root mihomo v1.19.33 passed private version and typed mode/selection readbacks and no-IP FD checks. Held SIGTERM yielded observed Core exit0; owner/work removed. Three observations showed supervisor/Core absent, complete group empty, known boolean true. Actual job ran once with exit0.
- `prepare-kill`: rechecked normal, unloaded its exact job, installed only the distinct kill plist/epoch.
- `kill-test`: live supervisor35088/Core35089 were the complete inherited group at80ms. One job-targeted SIGKILL was followed by absent supervisor/Core and empty complete group at1179ms and5256ms. No kill result.json/reaped.json existed; the exact job recorded terminating signal9. The unchanged supervisor fallback begins after30seconds and would write reap/result records. This is launchd group-cleanup evidence for this fixed no-TUN Core session, not fallback success. Actual Core wait status is unavailable after supervisor death; do not claim its exit signal.
- `retire-kill`: repeated absence at69477/69537ms and unloaded exact stopped job. Independent launchctl query returned113.
- `cleanup`: exact four new installation files removed, with durable retirement record. Independent readback found all four absent (including symlinks) and job113. No failure recovery was needed.

## Retained evidence

- `/private/tmp/kuro-root697-window-lxtuhxeu`: restricted stage logs, preflight hashes, final readback and read-only collector source.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA-root858-preserved`: root0700 old approval/evidence/archival receipt.
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA`: root0700 new approval/normal evidence/kill owner and cleanup receipt.
- `kill/session-work` contains exactly `config.json` and `core.sock`; no cache.db was observed. Socket path is retained evidence, not a claim that a listener remains. No recursive deletion.

The four absent install targets are `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a`, `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist`, and `normal/mihomo`, `kill/mihomo` under the new experiment base. Retained data is not automatically deleted by a later run; a future exact retention cleanup must establish ownership and its authorized scope.

## Production consequence and limits

This removes the missing real root fixed-Core normal/launchd-group-kill evidence for the tested inherited process-group strategy. It does not demonstrate arbitrary descendant/non-group writer absence, actual Electron exit, production loaded-job provenance, restart cache recovery, uninstall after crash, upgrade after crash or any TUN/DNS/route recovery. The experiment owner uses core-control-experiment-v1 and cannot be promoted to a production stop proof.

No TUN/DNS service/IP proxy listener was enabled; no system proxy, route, DNS, login item or third-party setting changed. This window is complete and its authorization has ended. First TUN/network window remains separately gated.

Independent non-author review consumed the embedded raw normal receipt/job through the frozen strict parser and verified all eight embedded log hashes. Findings agree with the limited claims above. Reviewer did not reread root0600 originals or perform another kernel/system observation; main performed the privileged final readback.
