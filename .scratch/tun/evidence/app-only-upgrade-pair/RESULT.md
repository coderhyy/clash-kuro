# Prepared App-only upgrade pair

Old fresh source `d62675f583c3794fa4c75dcdf4c2e514d2db74d8`, package SHA256 `3e574cbf1d432c70dda45d4774c40c62ebabb74441abcd9b9f46182a506e5169` (fresh installation and never-started uninstall already passed).

New upgrade source `9763482e426be990593211dd773ad447cf1ec586`, package `apps/desktop/dist/kuro-tun-finite-session-upgrade-0.1.0-arm64-9763482e426b.pkg`, SHA256 `35c2883d8bdb3de8325ccdebcf92f1787c699a21be22ad4db11d7ec15a5be5af`.

Both sources have passing CI: old run41967758386, new run41970069176. The new clean-source helper and App builds passed. Offline extraction verified actual seal/inventory, fixed scripts, staged-only payload, BOM permissions and pins. The helper and fixed Core bytes are identical between releases; the sealed App source identity/inventory and resulting release differ. This is an executable pair for an App-only upgrade, unlike two packages of the same release.

No upgrade installation was executed. The second source changes evidence only, so this pair tests replacement/identity/receipt mechanics, not an application feature migration. Actual transaction, rollback and post-upgrade uninstall remain unverified. Both helpers retain disabled service startup and the same finite-session scope; no service/Core/network operation was performed while preparing this pair.
