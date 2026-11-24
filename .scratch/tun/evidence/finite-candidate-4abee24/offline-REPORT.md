# Final 4abee243 finite-session package offline verification

Result: **no offline blocker**. Scope: reuse prior4a static verifier for final exact package/App and compare unchanged helper/Core/scripts/BOM. No production-code re-audit, installation or execution of App/helper/Core/package scripts. No system/network/launchd/Git action.

- Exact source: `4abee2431de852244e43bf5ecab86cfcf91fb259`.
- Package SHA256: `f283dc18921aaf03980ca341c139d3721b38e5fffaafed15b711951f4365f4f6` (171726069 bytes).
- Package sidecar SHA256: `0c800b6f81d1d3b7b8c3ee09fe9d062f4061ee602459072cd82b1151d114e013`.
- Helper SHA256: `28f7d71bbf34587d289ff4c19095f1f779e2bdfba79b011f6380069d8b570391`; all4 delivered copies and clean same-source native tested protocol2 build record match; actual bytes identical to reviewed4a.
- Core executable SHA256: `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`; actual bytes identical to4a. Archive pin `060b64b0f2c9a310831db0fe4adb2878de67bfa606c311813c1f13966aa504b6` separately matches fixed core.lock.json.
- Actual extracted App CDHash: `271ee6f193d6ce35a09d93561c13997ec8059030`.
- App executable SHA256: `0f9572025f1aa43e6cc75be83f225322672078f7256e47eb0d3d1d39aa683271`.
- Info.plist SHA256: `3429b4bf4cffee7954a019a3c9217672cdd7a589dd9a9660b7efe816fac1ae21`.
- ASAR SHA256: `0588b8556ade5ede7c136a7f08e7805f914320c102a4e0b2adbd171f87bd7d13`.
- Client inventory SHA256: `3ee421e62ea07f0816126d1337e650dcbb759362ade2f5c67ef6afec396f5e38`; regenerated611-entry inventory exactbytes match delivered inventory and final manifest/metadata.

Actual extracted App passes existing strict/deep seal, all Mach-O runtime/allowed entitlement, ASAR signed header, fuse and client pin checks. Sealed package.json exact finite-session mode/source4abee243; actual pins equal manifest, metadata and same-source App build record.

Finite manifest activationAllowed=true/installerProtocol2/protocol1 remains explicit; disabled plist has fixed release/helper --serve, Disabled=true, RunAtLoad=false, KeepAlive=false, AbandonProcessGroup=false. Release103 chars/helper program path163 bytes satisfy fixed native constraints. Fresh preinstall/postinstall scripts are byte-identical to reviewed4a. PackageInfo install-location=/, relocatable=false, no relocation/version lookup and all9 nested bundles fixed under protected Client. All1253 BOM path/mode/UID/GID entries exactly equal4a and target root0:0; extracted fixed permissions checked again. BOM intended ownership is not installed ownership proof.

Diagnostic retention reuses unchanged helper/source behavior from previous review: actual helper bytes identical, retained-path message present, no TunDiagnostics payload or BOM entry. No diagnostic directory scan/deletion or system uninstall test. Unsigned local pkg remains expected; no paid signing/notarization claim.

Commands (all offline): pkgutil --expand-full; node /private/tmp/kuro-offline-package-4abee2431de8/verify.mjs (existing repository pin/static verifier); python3 /private/tmp/kuro-offline-package-4abee2431de8/postcheck.py (BOM/PackageInfo/locks/byte comparisons); codesign --display; pkgutil --check-signature (expected unsigned). Exact expansion/verifier invocation in commands.json. stdout/stderr logs and verification.json retained here.

Not claimed: installed privileged authentication, real TUN/network, cross-helper writer exit, system recovery, upgrade or uninstall acceptance.
