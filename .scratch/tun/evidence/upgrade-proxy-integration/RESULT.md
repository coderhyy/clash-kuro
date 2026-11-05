# Upgrade and proxy integration — 2026-11-05

Implementation checkpoint, not installed-system acceptance. The previous 4441983 package remains withdrawn.

macOS System Proxy now records this adapter's writes, checks the observed state before restoring them, and preserves unknown/externally changed settings. With no owned writes, clear performs no writes. Active authenticated proxies are rejected before modification. Stale cleanup does not infer ownership from a localhost endpoint. TUN admission independently requires HTTP/HTTPS proxies to be confirmed off. Core stop still runs when proxy cleanup fails. Windows behavior is unchanged.

Limits: ownership is in memory; external changes between a read and write cannot be atomically excluded. Previously disabled proxy endpoints may retain inactive values after restoring the disabled state. No real proxy changes were performed for this checkpoint.

Native protocol-2 upgrades use the existing protected installer, fixed staged payload, exact App/Core/helper identities, stopped proof and an external recovery receipt. Legacy installations and same-release upgrades are refused. Recovery rolls back before finalization and completes forward afterward. The historical `neverStarted:false` state remains sticky. Client-bearing package releases now include the full client inventory SHA256 so App-only updates are distinct. The original disabled plist is validated before rewriting its exact helper path.

Integrated validation:

- `KURO_REQUIRE_CORE=1 node apps/desktop/scripts/build-macos-helper.mjs --test` passed with the host target: strict native compile, ordinary-user fixture suite, fixed-Core syntax validation, and mandatory upgrade suite. No installed helper/service or TUN was started.
- Upgrade fixtures cover two histories, repeated upgrade, immediate uninstall, 102 deterministic interruptions through the exact recovery executable, and refusal branches.
- Actually truncated staged helper/Core files were refused; original installation, transaction and staged data were retained. This is preservation, **not automatic recovery of arbitrary partial package extraction**.
- Integrated typecheck passed all four packages. System-proxy/platform tests passed 94/94 after sandbox loopback-port denial was resolved by the approved unsandboxed test invocation.
- Prepare/package tests passed 48/48 under Vitest. An initial Node test-runner invocation failed before tests because these suites require Vitest; it was not a code failure.
- Full workspace test command passed: API 12, core 218, state 171, desktop 528 passed; desktop 17 conditional tests skipped. Skips are not acceptance evidence. Full output retained in `all-tests.log`.
- Implementation and independent review were separated: proxy implementation by windows_login, independent review by tun_spec and main; native upgrade implementation by macos_acceptance, integration review by main. Main found and corrected the staged plist mode mismatch; package/native layout evidence uses non-executable Inbox files at 0600.
- Final App-bound package release received independent native-compatibility review by macos_acceptance: no new blocker. Both actual JS-staged fresh/upgrade roots passed `--upgrade-package-layout-fixture`; commands and results are in `native-layout-review.json`. These fixtures inject seal verification and use test helper/Core bytes, proving layout compatibility only. Current arm64 release/helper path lengths are 103/163 bytes; the native 120-character release limit is respected and fixed socket paths do not depend on release.

Real root installation/upgrade/uninstall and TUN normal stop, actual Electron exit, helper-death recovery, dual-stack/LAN/split DNS acceptance remain outstanding. Current tests do not replace them. The first network window still requires user approval and a baseline free of conflicting third-party VPN routes; no third-party settings may be changed by the experiment.
