# Finite-session candidate 4abee24

Exact source: `4abee2431de852244e43bf5ecab86cfcf91fb259`.

Both macOS and Windows CI passed: https://github.com/coderhyy/clash-kuro/actions/runs/41982213587 . This includes the corrected real-private-API/missing-listener test; the earlier failed 4a8c7ac run is preserved in the recovery evidence, not overwritten or called green.

Local package: `apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-4abee2431de8.pkg`.
SHA256: `f283dc18921aaf03980ca341c139d3721b38e5fffaafed15b711951f4365f4f6`.
Helper: `28f7d71bbf34587d289ff4c19095f1f779e2bdfba79b011f6380069d8b570391`.
Fixed Core v1.19.33: `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`.

Native mandatory full tests and real fixed Core -t passed with no syntax skip. Hardened runtime App built and sealed from clean same-commit source. The explicit finite-session manifest allows the production operation path but installed service remains disabled/no autostart. No installation, service startup or TUN operation was performed for this candidate.

The prior 4a8c7ac real normal and owner-connection EOF executions both passed private interface readbacks, SIGTERM/Core exit0, independent exact process/group/base absence and retained bounded diagnostics: [execution evidence](../recovery-durability-20261105/RESULT.md). This later commit changes only the readiness test and evidence/docs; all19 frozen experiment source blobs and production native code are identical, and rebuilt helper SHA is identical. The earlier executions are not relabeled as new actual 4abee24 runs or root/TUN results.

Still open: actual root LaunchDaemon/fixed-Core supervisor death behavior; origin-only cache writer-exit proof; installed production TUN, utun and dual-stack data-plane/LAN/split-DNS preservation; real App exit, helper-death recovery and post-session uninstall; actual upgrade/rollback. The dedicated root non-network window already prepared at `lifecycle-core-preparation-85834ab` has not been approved/executed. First TUN window remains unapproved. No merge performed; 04/06/08 remain open and the long-term goal remains active.

Independent final-package extraction review passed: exact package/sidecar/source metadata, actual App seal/runtime/fuses/ASAR/client pin and611-entry inventory, all helper/Core bytes, fixed fresh scripts/disabled plist and1253 BOM entries. Native helper/Core and fresh scripts/BOM paths/modes/ownership match the independently reviewed 4a candidate byte-for-byte; new App metadata/pin exactly matches this source. Report and machine checks are adjacent. No extracted code or system operation was executed.
