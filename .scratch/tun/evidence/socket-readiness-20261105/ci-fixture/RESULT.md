Test-only CI determinism repair; product behavior and error precedence unchanged.

Cause: the original 250ms startup deadline could expire in a later HTTP request after a genuine replacement was already rejected; the final request timeout replaced the prior identity error. The fixture had no independent handshake/replacement evidence.

Change: bounded 1000ms fixture budget; actual same-replacement dev/inode pair evidence (both updated together each round); completed HTTP response and SOCKS FIN handshake evidence; rejection, child close, not-running, and no core.pid assertions. No lstat spy. Only platform.test.ts changed.

Validation (ordinary UID fixtures; no real Core, -t, root jobs, installation or network settings):
1. Focused fixed case: exit0, 1 pass/48 skipped.
2. Isolated negative control removing only post-readiness secureUnixSocket: exit1, promise resolved instead of rejecting. This demonstrates the case catches incorrect startup acceptance.
3. Full platform.test.ts: exit0, 49/49 passed, 3.25s.
4. Desktop node typecheck: exit0.

Commands:
node /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/node_modules/vitest/vitest.mjs run src/main/platform/platform.test.ts --root /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop -t 'start refuses replacement control' --maxWorkers=1 --no-cache
node /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/node_modules/vitest/vitest.mjs run mutant-platform/platform.test.ts --root /private/tmp/kuro-d05-socket-test-fix -t 'start refuses replacement control' --maxWorkers=1 --no-cache
node /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/node_modules/vitest/vitest.mjs run src/main/platform/platform.test.ts --root /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop --maxWorkers=1 --no-cache
# cwd /Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro
node_modules/.bin/tsc -p apps/desktop/tsconfig.node.json --noEmit

All ordinary Unix/loopback fixtures were run with approved sandbox escalation solely because sandbox bind is denied. No system state changes.
