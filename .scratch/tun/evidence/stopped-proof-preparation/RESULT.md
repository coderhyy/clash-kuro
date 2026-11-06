# Stopped proof and finite-session candidate preparation

Independent non-implementing review (windows_login) found no blockers in the bounded change. Exact held-child reap and owner unlink/fsync precede stop proof; route/DNS results bind the same session; new start durably revokes prior proof; neverStarted stays false. Uninstall saves approved evidence outside State before deletion and preserves unknown objects. Full fixture logs explicitly mark network proofs mocked, not real network validation.

Main integrated build: KURO_REQUIRE_CORE=1 node apps/desktop/scripts/build-macos-helper.mjs --test (native arm64 target), exit0. Full native suite including fixed Core -t passed, 11 held harmless-child uninstall cases and27 service cases passed. The local first build is preparation/sourceClean:false, not a deliverable; rebuild at the next frozen source commit is required. No actual root install/service/TUN/network operation.

Finite-session packaging separately requires freshly built sealed normal App and exact same-clean-commit helper with mandatory native tests including Core syntax; auth-only remains incapable. Fixed candidate data root is appData/Clash Kuro TUN Candidate with private marker/subdirectories, survives candidate upgrades and is not deleted by uninstall. App runtime tests16passed/one Windows-specific negative skipped on macOS; main TypeScript passed. Package/client-pin/source-builder focused36passed. Independent review approved both scopes.

CI d80736a macOS passed; Windows failed two pre-existing runtime tests assuming POSIX UID and /etc/passwd. Fix retains POSIX checks, explicitly rejects unsupported UID entry, and uses an actual cross-platform temporary file to verify isolated capabilities cannot reach real files. Windows rerun remains required.

Upgrade transaction is not implemented. No claim of actual Electron installed normal operation, root stopped-proof/uninstall, dual-stack routing/DNS or helper-crash recovery is made. First network window must still be explicitly approved.
