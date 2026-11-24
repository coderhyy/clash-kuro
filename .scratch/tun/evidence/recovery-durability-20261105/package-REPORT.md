# 4a8c7ac finite-session package offline review

Result: **no offline blocker found**. Extraction and static checks only; no package scripts, App, helper or Core were executed. No installation, launchctl, system/network mutation or Git operation.

Source: `4a8c7acff81f1c52e9dfab221363638161e952bd`. Fresh package SHA256 `06e67370180d243c414ce471b3c0b7af66f44feb88959b9d1bcaf54c44bd2d5f`, 171726433 bytes; sidecar SHA256 `a8405233eef418314160665f35d8f1bcdfa5e464e91dcafed3201381cbc43cfb`.

Actual extracted helper SHA256 `28f7d71bbf34587d289ff4c19095f1f779e2bdfba79b011f6380069d8b570391` matches all four delivered copies (Inbox, installer, uninstall recovery, scripts/preflight-native), clean native build record/source/protocol2/tests and package metadata. Actual extracted Core SHA256 `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`; compressed archive pin `060b64b0f2c9a310831db0fe4adb2878de67bfa606c311813c1f13966aa504b6` separately matches core.lock.json. Both actual Mach-O headers are arm64.

Actual App deep/strict seal, every Mach-O runtime/allowed-entitlements, signed ASAR header and fuses pass existing `macos-client-pin.mjs` / `verify-macos-app.cjs`. Actual executable/Info/ASAR/CDHash match package manifest, App build record and metadata. Sealed package.json mode/source exactly finite-session/4a8c7ac. Actual regenerated 611-entry inventory equals delivered bytes and digest. Release length103 and fixed helper program path163 bytes satisfy native release120/PATH_MAX rules; no use as Unix socket path.

Manifest activationAllowed=true/installerProtocol2/protocol1 is the explicit finite candidate; this is not disabled-helper/auth-only behavior. Launchd plist remains Disabled=true, RunAtLoad=false, KeepAlive=false, AbandonProcessGroup=false and ProgramArguments fixed release helper + --serve. Fresh preinstall is exact preflight-native --begin-client-install; postinstall exact fixed installer --install. Neither was executed. PackageInfo install-location=/, relocatable=false, no relocation/version lookup, all9 nested bundles fixed under protected Client. All1253 BOM entries specify UID/GID0; extracted permissions match shared0755, State/Inbox0700, executable0755 and manifest/plist/inventory0600. Intended owner metadata is not installed ownership proof. AppleDouble BOM metadata is decoded by pkgutil: no extracted ._ objects.

Diagnostic retention: no TunDiagnostics payload/BOM entry. Pinned helper contains fixed successful-uninstall retention message. Current same-source UninstallFresh/Uninstall only remove exact recorded App/Tools/State/socket/recovery paths and leave common Clash Kuro parent plus sibling TunDiagnostics untouched. Diagnostic storage/retention is a source+binary static conclusion, not an actual uninstall test.

Package is unsigned as expected for this local ad-hoc candidate. No paid-signing/notarization claim. No real TUN, writer-exit, network recovery, upgrade, installed authentication or uninstall acceptance is inferred.

Commands actually used:

- `/usr/sbin/pkgutil --expand-full <exact pkg> /private/tmp/kuro-offline-package-4a8c7acff81f/expanded` (exit0)
- `node /private/tmp/kuro-offline-package-4a8c7acff81f/verify.mjs` (exit0; reuses existing static verifier/pin/inventory)
- `/usr/bin/lsbom -p fmug /private/tmp/kuro-offline-package-4a8c7acff81f/expanded/Bom`
- `/usr/bin/codesign --display --verbose=4 <extracted Inbox/helper|mihomo>`
- `/usr/sbin/pkgutil --check-signature <exact pkg>` (expected unsigned result)
- Python SHA256/closed metadata/plist/PackageInfo/BOM/Mach-O assertions; all passed.

Machine report: verification.json; raw logs verify.stdout.log, verify.stderr.log, expand.stdout.log, expand.stderr.log, bom.txt, helper-codesign.txt, mihomo-codesign.txt, package-signature.txt.
