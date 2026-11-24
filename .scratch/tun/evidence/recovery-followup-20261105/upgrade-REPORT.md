# Upgrade retirement retry candidate

Only native/tun-install.m and native/tun-install.test.m differ from the recorded shared baseline. The final approval unlink and a fully validated no-record recovery now both require the fixed approval parent directory to fsync. A missing record alone cannot confirm durable retirement. No identity/layout checks or deletion authority were relaxed.

Strict arm64 production/test clang compilation passed; commands are in compile-command.json, empty compile.log means no warnings/errors. Ordinary-UID --upgrade-tests exited 0 in 44.787 seconds with KURO_SKIP_CORE_SYNTAX=1; no actual Core, service, installer, or network operations.

The new real-file fixture covers post-unlink sync failure, repeated no-record sync failure, unchanged installed tree, changed App rejection before sync without deleting it, eventual successful real parent fsync, a fresh exact recovery CLI process, and immediate uninstall. The existing 102 deterministic transaction interruption points and both history/repeated-upgrade paths also passed. Test sync faults simulate a failed fsync; the eventual successful path calls the real directory fsync.

No production candidate was rebuilt. This is a narrow durability fix, not real macOS Installer or power-loss acceptance. Unknown/truncated staged objects still block recovery and are preserved.
