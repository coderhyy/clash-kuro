# Finite-session build and isolated Electron checkpoint

Source: `8a989ec9d40bc330d33f232ab8672fa0026bfc2b`, clean implementation tree during both builds. This is a preserved checkpoint, not the eventual network experiment package.

- Native build/test with mandatory fixed Core syntax validation passed; exact helper SHA256 `ee9624aba0607c58075ef4fc5d554bcffcfb9280fb299ff12e9a08a411f4ca0a`. See `native-build.json` and `native-build.log`.
- First App build could not download Electron inside the network sandbox. The exact build was rerun with approved network access and passed; no candidate output existed before the retry. See `app-build-network-retry.log` and `app-build.json`.
- Actual source-built App: `apps/desktop/dist/electron-finite-session-candidate-8a989ec9d40b/mac-arm64/Clash Kuro.app`. Seal, hardened runtime, ASAR and fuse verification passed. Sealed source/mode and actual client pin match the build record.
- Actual isolated Electron execution passed all 14 scenarios: UI/CSS/IPC and in-memory backup export/import; RunAsNode, NODE_OPTIONS, packaged renderer URL and DYLD constructor injection checks; explicit debugging/code-loading argument refusal. This deliberately lowered verification entry cannot construct real Core/helper/network capabilities. It is not installed-client authorization or production Core-management proof.
- Runtime evidence retained privately at `/private/var/folders/08/49qljhcd40jbdr05n6w59v9m0000gn/T/kuro-runtime-evidence-NO9xnT`; summary in `runtime-verification.log`. Debug-port polling is sampled, not kernel tracing.
- CI run `41961279135` failed one Windows-only assertion in the candidate build-plan test: a POSIX separator regex rejected the correct Windows path. A platform-native exact path assertion is prepared for the next commit. This checkpoint is not reported as green CI.

No installation, service registration or TUN/network writes occurred. Existing prepared helper payload belongs to an older candidate and must not be packaged with this App. Same-worker explicit cleanup recovery is still being integrated; a new clean commit and matching native/App rebuild are required before the network candidate is frozen. Upgrade and real root/TUN acceptance remain open.

The old prepared payload was independently checked against its manifest (helper `f995f1fd8416d5cb99af1655b1814dc206405bfc24dabe2d7d1f534c13265623`, fixed Core `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`) and preserved by rename to `apps/desktop/dist/helper-payload-preserved-ba360907bb7f91f6`. No old artifact was overwritten or removed.
