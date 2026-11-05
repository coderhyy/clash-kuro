# 4441983 finite-session candidate checkpoint

**Withdrawn from installation/network use after follow-up review.** The actual platform shutdown/stop path still called legacy macOS all-service proxy cleanup even though candidate startup skipped it. A third-party proxy could therefore be disabled on App exit or mode switch. This package remains immutable evidence only; do not install it or treat the earlier window proposal as executable. The fix must reach the adapter, Core stop and TUN all-off admission before a replacement candidate is built.

Source `4441983abd114cae2d4febea1422182408eaf3ad`. CI [41963508007](https://github.com/coderhyy/clash-kuro/actions/runs/41963508007) passed. Existing draft PR remains unmerged.

Same clean source App and native helper builds passed, including mandatory fixed Core syntax validation. Initial native fixture Unix socket bind and Electron download were sandbox-blocked; exact permitted retries passed. Logs retain both attempts. Actual isolated Electron verification passed 14 scenarios; it verifies UI/IPC/in-memory Backup and bounded debug/injection refusal, not root installed-client or real TUN behavior.

Package: `apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-4441983abd11.pkg`

SHA256: `f42e960970c497942141330790a7a23a9669109f6dccee140f48864545f51d8b`

Independent offline extraction verified exact App pin/sealed source/runtime/fuses/inventory, all helper copies and fixed Core bytes, root-owned BOM permissions, fixed installation paths and scripts, disabled plist with no RunAtLoad/KeepAlive. See `offline-package-review.json`. The package was not installed. Its finite capability is explicit; no auth-only package was converted or resealed.

## Real non-TUN control regression

Frozen runner: `apps/desktop/dist/core-control-experiment-4441983abd114cae2d4febea1422182408eaf3ad/core-experiment`; SHA256 `c04a908972b38b722237f60cb815883afe530a1f176be4d47996df231f0f8789`; full inventory/artifact in `core-artifact.json`. All six SHA256SUMS entries and initial `--inspect` passed. Same epoch `230DF973-3316-4BA6-8743-18D44E15A257` normal passed before EOF was allowed.

Both stages runner exit0: fixed v1.19.33 private version, finite mode/selector readbacks, two point-in-time NoIP observations, requested SIGTERM and Core exit0/no signal. Normal has owner-stop plus ACK; EOF has actual owner-connection EOF and no ACK. Both strict success receipts pass. Independent proc_pidinfo returned ESRCH for normal Core/worker 74430/74429 and EOF 75125/75124; both entire runtime bases were absent. No additional kill or deletion was needed. Restricted diagnostics remain at `/private/tmp/kuro-core-evidence-Z9D5a3` and `/private/tmp/kuro-core-evidence-h0tpOD`.

Owner EOF is not actual Electron exit. Neither ordinary-user regression nor fixtures prove root Core, all descendants, utun, route/DNS restoration or helper-death recovery.

## First network-window blocker

Read-only baseline at `/private/tmp/kuro-tun-baseline-chfd3v_9` found nine IPv4 routing-table rows on existing `utun1024`, plus other IPv6 utun interfaces. No current candidate installation owns them. HTTP/HTTPS/SOCKS and automatic proxy flags read disabled; no `dev.kuro.tun` disabled override was present. Initial sandbox DNS view was unavailable; unsandboxed read-only DNS/proxy inspection succeeded. Raw topology remains private and is not committed.

Do not start TUN on this conflicting baseline or alter the other tunnel. The user must arrange a nonconflicting network window; then re-read baseline and freeze the minimal profile using only its existing DNS providers before any network write. Fresh installation and the network stages have not been executed. Upgrade implementation continues separately; cross-helper recovery and root/network acceptance remain open.
