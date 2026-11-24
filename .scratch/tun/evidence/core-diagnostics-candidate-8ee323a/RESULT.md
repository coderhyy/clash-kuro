# New diagnostic candidate — prepared, real execution not authorized

Source commit: `8ee323a48da5729217a0f730d4de850da867f0d9`. Artifact: `/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/core-control-experiment-8ee323a48da5729217a0f730d4de850da867f0d9`.

- Runner SHA256: `72d10765f48bdd2d63ce6b6c39dae3a66becaeba87f66182d6a05e833a088064`
- inventory.json SHA256: `486de1e5986166e7e4903e782cea626655d3db6e3e7182bef6162240e85d9e84`
- Fixed Core SHA256: `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`
- Epoch: `973D82CC-BA3C-4389-9AA7-F7EA75D2C797`
- Offline build: passed; compiler and exact flags in artifact.json.
- SHA256SUMS: all six payload/metadata checks passed.
- --inspect: status prepared, normalPassed false, receipt matched.
- Signed candidate --self-test: exit 0, 111 fixture assertions passed, stderr empty.
- No real Core, -t, install, service or system network operation performed.

Signed fixture evidence retained (0700 directories; 0600 files):
- early exit: /private/tmp/kuro-core-evidence-IXr4ER
- overflow: /private/tmp/kuro-core-evidence-tCCAwK
- timeout: /private/tmp/kuro-core-evidence-5C7N2j
- deliberate log-save failure: /private/tmp/kuro-core-evidence-OEdh5C (fixture directory restored to0700 after assertions; runtime retained by failure policy)
- deliberate abnormal worker exit: /private/tmp/kuro-core-sAA3M2 (retained fixture recovery evidence, not real Core)

## Requested next experiment (requires fresh user authorization)

Estimated 5–8 minutes including review. Ordinary UID only; no installation, launchd, TUN, DNS service, public proxy listener, system proxy/routes/DNS/login-item changes. Do not run -t.

1. Recheck this exact artifact's SHA256SUMS, pinned runner/inventory/Core and --inspect. Any mismatch/conflict stops execution; never overwrite or retry a used stage.
2. Run this exact core-experiment --normal. Verify private control API, typed mode/select readbacks, two NoIP observations, actual termination and Core/owner/work/group absence. Capture runner stdout/stderr and stage result. The independent protected diagnostics directory remains for review.
3. Only after complete same-epoch normal success, run --eof and require the same stop/residual evidence. Owner socket EOF is not actual Electron exit.
4. Any failure/timeout stops subsequent stages. Preserve diagnostics and unknown objects. Recovery uses only the documented live guardian's unreaped direct-child identity and verified dedicated process group; never signal a process from an old PID. Guardian observation15s, bounded cleanup500+300+1000ms, worker lease5s; no new force-kill/detachment experiment.

Startup cause remains unknown. Fixed source independently establishes cache.db creation on select and Unix-controller token bypass; neither explains prior early exit. Private0700 paths do not isolate malicious same-UID processes. Ready/afterReap checkpoints improve failure evidence but cannot guarantee buffered output survives an unexpected worker kill before a checkpoint. Production-root diagnostics and exact cache recovery remain separate integration work.
