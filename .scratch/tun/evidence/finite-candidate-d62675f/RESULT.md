# d62675f finite-session candidate

Source: `d62675f583c3794fa4c75dcdf4c2e514d2db74d8`, pushed to the existing draft branch. No merge.

Fresh package: `apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-d62675f583c3.pkg`

SHA256: `3e574cbf1d432c70dda45d4774c40c62ebabb74441abcd9b9f46182a506e5169`

Upgrade package: `apps/desktop/dist/kuro-tun-finite-session-upgrade-0.1.0-arm64-d62675f583c3.pkg`

SHA256: `8bda0e8a6d486e4ce938dd66f2bc8e22113e207b7ac446b9328c1b6711c2b907`

Both built offline from the same clean source App and native helper; the native build includes mandatory fixed-Core syntax and upgrade fixture checks. Prior 4441983 payload was hash-checked and preserved, not overwritten. New release binds the full App inventory. Upgrade package requires a distinct already-installed protocol-2 release; it cannot upgrade the fresh package of this same release or a legacy install.

Actual new isolated Electron verification passed 14 scenarios: UI/IPC/in-memory Backup and bounded debug/injection refusal. This capability-lowered verification does not create the real Platform/Core/helper/network writer and does not prove installed privileged authentication or TUN functionality.

CI run: https://github.com/coderhyy/clash-kuro/actions/runs/41967758386 . Subsequently independently queried: completed, success (macOS and Windows).

Offline independent verification of both actual packages passed; see `offline-package-review.json`. This does not prove Installer runtime behavior.

Under the existing broad fresh-install authorization, the new fresh package was subsequently installed successfully. Actual installed App/helper identities match the package, the service job is absent, and the installed plist remains Disabled=true, RunAtLoad/KeepAlive/AbandonProcessGroup=false. No App/Core/service or real TUN/network writer was started. Protected fresh/installed records match the package and `neverStarted:true`. Fixed native uninstall returned 0. All exclusive installation targets, socket directory, identity/ownership records and job were absent afterward; the exact 1,252-entry Installer receipt matched the package BOM before it was forgotten. Final receipt/job/path checks passed and exact installed executable path process scan had no matches. See `fresh-execution/`; full private evidence remains at `/private/tmp/kuro-fresh-d62675f-qlws__xe`.

An existing empty root-protected Client parent was preserved with the same inode; the native contract allows that ancestor but refuses an existing App. Initial external preflight incorrectly treated the parent itself as an exclusive target; the corrected check and reason are retained. An initial read-only administrator `cat` used the wrong installed.json path and failed; the corrected source-defined State path succeeded. Neither failed check modified system state. No manual deletion or process signaling was needed. These results prove fresh installation and never-started uninstall only, not post-TUN uninstall or upgrade.

First TUN/network window still requires explicit approval. The prior read-only baseline found third-party utun routes: they must not be modified by this experiment. Normal TUN/stop and actual App exit precede any later helper-death injection; cross-helper residual recovery is not yet accepted.

Real non-TUN normal/EOF last passed on 4441983 (see sibling evidence); they were not rerun merely for the installer/proxy changes. Source and package checks do not expand that evidence to root Core, all descendants, dual-stack data-plane, LAN/split DNS or network cleanup.
