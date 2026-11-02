# Real Core first-streams ECONNREFUSED

Date: 2026-11-02. Baseline: ec8a813. Workspace: D:/clash-kuro.

## Scope and ownership

The initial investigation edited only
`apps/desktop/src/main/platform/mihomo.integration.test.ts` and this document.
The user subsequently authorized the bounded production fix in `platform/index.ts`
and `platform/platform.test.ts`, plus necessary fake Core fixture updates. The only
additional fixture path is `platform/resident-platform.test.ts`, announced before
editing. Real-Core ownership was released at the first checkpoint, then explicitly
reacquired for this follow-up. Tests use the
already installed bundled Windows x64 Core, loopback listeners, randomized named
pipes, and private temporary directories. No dependency installation, production
app launch, real System Proxy/RunOnce writes, OS session events, commits or push.

## Root cause and tight reproduction

The old fixture selected an ephemeral **TCP** port and assumed it was suitable
for Core's mixed listener. The bundled mihomo needs **both TCP and UDP** on that
port. Windows' UDP exclusion ranges differ from its TCP ranges.

Read-only commands on this host:

```powershell
netsh interface ipv4 show excludedportrange protocol=udp
netsh interface ipv4 show excludedportrange protocol=tcp
```

UDP exclusions included `57722-57821`; TCP exclusions did not include that range.
Both the historical failing mixed port **57785** and this investigation's
naturally selected failing port **57798** are inside the UDP exclusion.

The feedback command, run from `D:/clash-kuro/apps/desktop`, is:

```powershell
$env:KURO_REQUIRE_CORE = '1'
Remove-Item Env:KURO_RESIDENT_FAKE -ErrorAction SilentlyContinue
node ../../node_modules/vitest/vitest.mjs run src/main/platform/mihomo.integration.test.ts --maxWorkers=1 --reporter=verbose
```

After adding bounded Core stdout/stderr capture and correcting the request Host
header, this command naturally reproduced the exact first-streams symptom:

```text
20:10:31 start; 1 failed; test 5405ms
Core integration failed at first-streams; mixedPort=57798; originPort=57799;
originHits=0; traffic=connect ECONNREFUSED 127.0.0.1:57798 [five tail entries]
Caused by: /logs?level=info stream timed out
Core: RESTful API pipe listening at: [random fixture pipe]
Core: Start Mixed(http+socks) server error: listen udp 127.0.0.1:57798:
bind: An attempt was made to access a socket in a way forbidden by its access permissions.
```

To make the reproduction deterministic, the old TCP-only reservation was then
temporarily changed from `listen(0, ...)` to `listen(57785, ...)`, the exact
historical mixed port. The same command failed again:

```text
20:12:23 start; 1 failed; test 5623ms
Core integration failed at first-streams; mixedPort=57785; originPort=53184;
originHits=0; traffic=connect ECONNREFUSED 127.0.0.1:57785 [five tail entries]
Caused by: /logs?level=info stream timed out
Core: RESTful API pipe listening at: [random fixture pipe]
Core: Start Mixed(http+socks) server error: listen udp 127.0.0.1:57785:
bind: An attempt was made to access a socket in a way forbidden by its access permissions.
```

The hardcoded port was removed. These are failed runs, not passes or retries.
The reproduction needs no other test, resident helper, external network, load
injection, or timeout change. API `/version`, live-resume `/connections`, and the
traffic stream can work while the mixed listener is absent. The original run did
not retain Core output, so its precise bind error cannot be recovered; matching
the exact original port and symptom plus the exclusion table establishes a
reproducible explanation without inventing historical log evidence.

## Other observed defects and failures

1. The original proxy request omitted an explicit origin Host header. Node used
   the proxy port in Host. Core logged `127.0.0.1:57712 --> 127.0.0.1:57709 using
   DIRECT` for mixed port 57709, rather than forwarding to origin 57710. Requests
   returned HTTP 400, originHits stayed zero, yet the old two-stream assertions
   could pass. Adding an origin-response assertion before changing the header
   deterministically failed at first-streams (20:07:47; 1497ms). This was a false
   positive in the fixture, separate from UDP access denial.
2. The unchanged isolated baseline passed (20:04:45; 3057ms). It does not disprove
   the intermittent port-selection defect and, without the new assertion, does
   not prove origin traffic succeeded.
3. The unchanged full desktop suite (`bun run test`, Core required, fake override
   cleared; 20:06:02) failed **12/195**, with **183 passed**. Core failed at
   **restart**, mixed 55198 / origin 55199, after HTTP 400 traffic, with TCP
   `EADDRINUSE`. Ten resident-client tests hit their existing request deadlines;
   one cat-glyph test exceeded its existing 5000ms deadline. None is relabeled as
   the first-streams ECONNREFUSED. CI 41414184199's EADDRINUSE remains a separate
   historical failure whose cause is not proven here.

Ranked predictions before probes were: (1) API readiness can precede a failed
mixed bind; (2) a released port can be occupied before Core binds; (3) malformed
proxy requests explain HTTP 400; (4) outstanding traffic can affect restart.
Core output confirmed a UDP bind denial for (1), not evidence of another process
taking TCP for (2). Explicit Host plus real response assertions address (3).
No claim is made that this proves (4) or repairs the earlier CI EADDRINUSE.

## Scoped fix

- Ask the OS for a loopback UDP ephemeral port, then reserve TCP on that same
  number. Keep both reservations through config validation and origin setup;
  release them immediately before Core startup. A reservation error fails the
  test; there is no alternate-port loop, Core restart retry or test retry.
- Send the origin authority explicitly in Host. Require HTTP 200 with the exact
  local origin body in each stream phase, including new responses after restart.
- Keep an 8 KiB Core output tail and include it, origin hits/responses, traffic
  tail and original cause in failures. Include existing resident diagnostics
  when that fixture is selected. Keep the existing stop-error aggregation and
  retain the private directory if stop cannot be verified.
- Keep the five-second stream deadline and twenty-second test deadline.

The existing real-Core integration is the regression seam: it exercises config
validation, actual listener startup, live resume, both WebSocket streams, real
proxy traffic, stop/restart and Windows pipe rotation. The added response checks
cannot pass on self-directed HTTP 400 traffic.

## Initial production proposal

At the first checkpoint, `apps/desktop/src/main/platform/index.ts` had the same
TCP-only `assertMixedPortAvailable` preflight and accepted `/version` as startup
readiness. The fixture change alone did not repair a real user's UDP-blocked port.

Proposed main-owned change, reported before any out-of-scope edit:

1. Validate port syntax as today. Probe both loopback TCP and UDP for the exact
   configured mixed port, close both probes on success/failure, and name the
   failing protocol/port in the error. Preserve the configured port; do not pick
   a replacement or retry Core.
2. Require mixed-listener readiness as well as API readiness before returning
   startup success, using the existing startup deadline, including the resident
   route. Report captured listener diagnostics on failure. A preflight alone
   cannot eliminate the release-to-Core-bind race.
3. Add main-owned tests for UDP-only occupancy, TCP occupancy and validation,
   successful dual-protocol release, and API-ready/mixed-not-ready startup.

No production file was edited in that initial round. The next section records
the subsequently authorized implementation.

## Authorized production fix

The user accepted the root cause and assigned `index.ts` and the actual
`platform.test.ts` to this chat until explicit release. Main continues migration
work separately. The only necessary disjoint fixture edit,
`apps/desktop/src/main/platform/resident-platform.test.ts`, was announced before
editing. No migration file was edited or reverted.

Implementation:

- `assertMixedPortAvailable` validates the configured port, probes loopback TCP
  and UDP, closes probes before returning, and preserves the original socket
  error as cause. Both occupied and access-denied errors identify protocol/port.
  It does not substitute another port or retry a failed preflight.
- Both direct and resident startup call the same `assertCoreReady` helper. It
  requires successful API `/version` **and a valid SOCKS5 greeting** from the
  configured loopback mixed listener before returning success. A TCP handshake
  alone is insufficient: a silent or non-SOCKS listener cannot pass.
- The greeting offers no-auth and username/password methods; accepting either
  proves the listener is responding without credentials, a SOCKS connection
  request, upstream traffic, or System Proxy writes. Two response bytes are
  buffered, so fragmented greetings are handled. Wrong protocol/method, EOF,
  connection errors and stalls reject the probe; sockets and timers are closed.
- The API request and mixed probe each use only the remaining original startup
  deadline (at most 250ms per operation). Poll delays are capped by its remainder;
  no new deadline or Core restart is introduced. The default remains 10000ms.
- The port getter is sampled once per start and the same value is checked,
  passed to the resident owner, and probed. Resident success also checks that the
  owner has not exited or entered shutdown during readiness. Direct success
  checks that its child is still alive and startup has not been shut down.
- Timeout errors include the last readiness error and existing Core/resident
  diagnostics. Existing stop/abort, failed-lifetime admission, pipe rotation,
  PID cleanup and owner-report verification remain in place.

Regression seam and red evidence:

```powershell
# From apps/desktop, before editing production index.ts:
node ../../node_modules/vitest/vitest.mjs run src/main/platform/platform.test.ts src/main/platform/resident-platform.test.ts --maxWorkers=1 --reporter=verbose -t 'UDP-only|API-ready'
```

At 20:24:31 this selected **four regressions, all failed** against the old code:
both API-ready/mixed-missing tests resolved successfully instead of rejecting;
both UDP-only occupied-port tests reached the forbidden spawn/owner seam instead
of rejecting preflight. The missing-listener direct case runs a real child HTTP
API on the private Control Channel; the resident case uses the existing mocked
API and an owner with no listener. This is not a transport-only unit substitute.
The other 36 tests were excluded by this diagnostic name filter, then run in full
in subsequent validations. No skip directive was added.

An earlier 20:24:11 feedback attempt had a test parse error (`await` inside a
non-async Promise executor) plus the resident regression's expected red. That
test syntax was corrected before accepting the four-test red result. One old-code
resident negative control also reported cleanup unverified after its intentionally
unimplemented owner seam was reached; it is not counted as an accepted stop.

After the first production implementation all **40/40** Platform tests passed
(20:26:24; 4.76s). The stronger SOCKS greeting check and fixtures then passed
**42/42** (20:28:16; 6.86s), including password-method negotiation and a silent
TCP listener. An invalid-protocol negative case was added before final validation.

The direct fake Core now opens both its API and a local SOCKS greeting responder.
The resident fake owner opens/closes a local responder with its lifetime and
reopens it on restart. Their ephemeral port selection checks TCP and UDP, as does
the earlier real-Core fixture. No real helper/proxy setting is used by unit tests.

## Initial fixture validation record

- Scoped fix, direct Core: **1/1 passed**, 20:14:19, test **2709ms**. Both origin
  response assertions, both streams before/after restart, config checks, resume,
  stop, PID removal and pipe rotation executed.
- Scoped fix, real Core plus existing compile-time fake resident: **1/1 passed**,
  20:16:43, test **3249ms**. Same invocation as above, with
  `$env:KURO_RESIDENT_FAKE = 'D:\clash-kuro\.scratch\mvp\prototypes\prestarted-helper-deadline\out\resident-fake.exe'`.
  This also executed fake-owner writes, native completion before Platform
  shutdown, shared shutdown Promise and rejection of writes after close. Only
  fake operations/registration are used; it is not real WinINet acceptance.
- Final original full-suite command, from desktop:

  ```powershell
  $env:KURO_REQUIRE_CORE = '1'
  Remove-Item Env:KURO_RESIDENT_FAKE -ErrorAction SilentlyContinue
  bun run test
  ```

  **23/23 files, 199/199 tests passed**, start **20:17:18**, duration **17.76s**.
  Core was required and executed; no tests were skipped. The current shared
  workspace includes concurrent main-owned tests, so this total is 199 rather
  than the baseline's 195. The earlier 12/195 failures remain recorded above.
- Main-process TypeScript check:
  `node ../../node_modules/typescript/bin/tsc -p tsconfig.node.json --noEmit`
  from desktop: **exit 0**.
- `git diff --check`: **exit 0**. No pinned failing ports, debug log markers, new
  retry loop, relaxed deadline or skip was left in the integration test.
- After all tests exited, read-only `Win32_Process` queries matched the bundled
  Core's exact executable path and both the fake resident executable name and
  its content-addressed deployed name: **0 Core, 0 fake resident processes**.
  The fixture's stop and private-directory cleanup completed. No external
  watchdog/rescue was used in these invocations.
- **Real-Core resource ownership released** after this process check; main may
  resume real-Core tests. No further Core executions are planned in this round.

Files changed by this investigation:

1. `apps/desktop/src/main/platform/mihomo.integration.test.ts`
2. `.scratch/mvp/prototypes/prestarted-helper-deadline/CORE-FAILURE.md`

Concurrent main-owned migration/native work was not changed or reverted.

## Production fix final validation and release

Executed once per final real-Core route after the production fix, using the
feedback command above and `KURO_REQUIRE_CORE=1`:

- Direct bundled Core: **1/1 passed**, start **20:28:42**, test **3028ms**.
- Real bundled Core with the existing fake native resident: **1/1 passed**,
  start **20:28:59**, test **3438ms**. The fake resident executable is the existing
  private test backend, not the real System Proxy helper. Config validation,
  SOCKS readiness, both streams, actual local origin responses, stop/restart,
  pipe rotation and native completion verification all executed.

Final full desktop validation:

```powershell
# apps/desktop
$env:KURO_REQUIRE_CORE = '1'
Remove-Item Env:KURO_RESIDENT_FAKE -ErrorAction SilentlyContinue
bun run test
```

**24/24 files, 210/210 tests passed**, start **20:30:53**, duration **20.45s**.
No tests were skipped. This includes all **43 Platform tests** in the two edited
test files, including UDP-only occupancy in both routes, TCP occupancy, invalid
port rejection, dual-protocol probe release, API-ready/mixed-missing in both
routes, silent/wrong-protocol listeners, password negotiation, startup success,
restart and the existing owner/cleanup failure cases. The shared workspace also
contains concurrent main-owned migration/startup tests; the total describes that
workspace at execution time, not a pristine baseline. There was no repeated green
full-suite run. Earlier failed/red runs are retained above.

Final `node ../../node_modules/typescript/bin/tsc -p tsconfig.node.json --noEmit`
from desktop: **exit 0**. `git diff --check`: **exit 0**; Git reported existing
LF/CRLF conversion notices, not whitespace errors.

After all runs exited, read-only `Win32_Process` queries again found **0 bundled
Core processes** (exact bundled executable path) and **0 fake resident processes**
(original and content-addressed executable names). No watchdog/rescue was used.
Both resources and code ownership were explicitly released to main after these
checks: **`platform/index.ts`, `platform/platform.test.ts`, the necessary
`platform/resident-platform.test.ts` fixture, and real-Core test execution are
released**. No further production/test edits or Core runs are planned here.

Changed in this follow-up:

1. `apps/desktop/src/main/platform/index.ts`
2. `apps/desktop/src/main/platform/platform.test.ts`
3. `apps/desktop/src/main/platform/resident-platform.test.ts` (announced fixture)
4. This `CORE-FAILURE.md`

The earlier `mihomo.integration.test.ts` fix is still present and was not changed
in this follow-up. Main's new migration files, app/native entry changes, CI and
packaging work were left untouched. No dependency installation, real System
Proxy/RunOnce writes, production app launch, OS shutdown/logoff, commits or push.

## Limits

The two-protocol reservation must be released before Core can bind, so it is not
an atomic handoff. If TCP cannot bind the UDP-selected candidate, setup fails
explicitly rather than hiding contention. No claim of macOS execution, real
proxy/session acceptance or historical CI EADDRINUSE root cause is made. The
production readiness repair is recorded above; it cannot make process creation
or OS networking hard real-time, or establish an atomic reservation handoff.

## Integrated failures after 70d6e8a (not waived)

- Windows CI `41447368781` failed 1/210: the fake-Core concurrent-start/restart
  test could not bind TCP `127.0.0.1:51399` (`EADDRINUSE`). The real mihomo
  integration passed in that run. macOS passed. This is not a green Windows run.
- A local **uncached** full workspace run failed 39/210 desktop tests with TCP
  `EACCES`, including port 62622. Read-only `netsh` showed TCP exclusions
  62413-62512, 62513-62612, **62613-62712**, while UDP had different exclusions
  (including 57722-57821). Binding UDP port zero is not a shared-protocol
  allocator: it repeatedly selected a TCP-forbidden address before test actions.
- The replacement test-only allocator excludes the union of advertised TCP/UDP
  exclusions, then actually holds both protocols on one port. A bounded candidate
  allocation handles only address-specific EADDRINUSE/EACCES and records each
  rejected port/protocol/code. It never retries Core startup, a failed assertion,
  or a failed test. Exhaustion/other errors fail setup. Production still fails on
  the user's configured unavailable port; it never silently selects another.
- Fake SOCKS servers now write their greeting and let the probing client close,
  matching the real server rather than actively closing first. The separate
  liveness connection awaits its close event before Core teardown. An isolated
  12-per-mode end-vs-write socket diagnostic did **not** reproduce EADDRINUSE;
  do not claim that this proves the precise CI TCP-occupancy cause.
- Focused validation of the allocator, both Platform suites and real mihomo:
  **46/46 passed**, 21:03:23 local, 6.27s, Core required. TCP-only and UDP-only
  candidate rejection/cleanup are asserted. Final full tests and new CI are
  required; one successful run does not erase the retained CI failure.
- Windows dynamic TCP/UDP ranges are now also excluded from test listener
  selection (read-only `netsh`; unknown output fails setup). Locally both ranges
  were 49152-65535. This prevents an OS-assigned outbound ephemeral endpoint from
  taking the test address in its release/restart window; explicitly bound other
  applications can still contend, so handoff is still not atomic.
- A subsequent focused run had 46 passing assertions but **failed the suite** on
  an unhandled ECONNRESET in the deliberately invalid/silent fake SOCKS endpoint.
  Its client intentionally aborts; fixtures now handle precisely ECONNRESET and
  still fail on other socket errors. This was not recorded as a passing run.
- After those changes, uncached workspace `turbo typecheck test --force` passed
  all 8 tasks; desktop **266/266**, 26 files, Core required, no skips, 21:18:30
  local. This includes the preparation worker's 54 fake-command cases and is not
  a claim of real migration or session verification.
- CI `41454369038` / `8a6cc45` failed: preparation fixtures used macOS `/tmp`
  aliases and Windows `RUNNER~1` short paths, correctly refused by canonical-path
  admission. Fixture roots now use `realpath`; a junction/symlink regression
  retains production rejection. Raw CI output is retained in
  `out/ci-41454369038-failed.log`.
- The first Windows filesystem test also exhausted its 5s test limit while its
  shared fixture initialized four read-only netsh inventory commands. Inventory
  initialization now runs in suite setup; no Core or cleanup deadline changed.
- Local full integration at 21:42:40 failed (267 passed / 1 failed): the existing
  86px cat-mask test took 7402ms against 5000ms. This is not a passing run; raw
  output is `out/local-214240-failed.log`. Separate glyph optimization must retain
  all tested pixels, dimensions and assertions, without increasing its timeout.
- The glyph failure was fixed by replacing per-edge array destructuring with
  indexed reads. All six complete mask hashes (18/36/86px, open/closed) match;
  the original 86px assertion remains. Standalone median pair time fell from
  2339.69ms to 85.67ms; the integrated four-test glyph file took 377ms.
- At 22:38:37 the final uncached workspace run passed all 8 tasks and desktop
  **335/335**, 26 files, no skips. Both real Core integration and the actual
  read-only boot/checkpoint probe ran. Turbo now explicitly passes both required
  test flags; the previous 334-pass/1-skip run was not the live probe acceptance.
- The independently built native parser/lock/journal/registration/connection/Core
  tests passed. Rebuilt shared fake engine passed **8/8**, including late clear
  with a delayed supervisor, with no rescue or leftover children:
  `out/resident-1793630965197`. Real Core through the fake resident Platform then
  passed **1/1**, `out/resident-platform-1793630981218`. No real proxy or RunOnce
  writes occurred on this machine. New CI remains required.

## Migration command/admission staging checkpoint (2026-11-02)

- CI `41469260599` completed successfully for exact commit
  `cf54ea512b619436ea9d255d90db93e2719c1e30`, Windows and macOS. Downloaded
  artifact/archive/build stamp/helper/collector verification is recorded in
  `ARTIFACT-cf54ea5.md`. It is intermediate evidence, not a manual candidate.
- The subsequent uncached integrated run at 23:47:17 passed all 8 tasks;
  desktop **424/424**, 28 files, no skips, with real Core and actual read-only
  boot/checkpoint collection required. Explicit prepare/check commands are
  wired before Platform construction, but were exercised only with fake
  commands and private filesystem fixtures. No real preparation was run.
- Native owner tests add private-namespace cross-process exclusion, recursive
  acquisition rejection, abandonment and access-error coverage. Native unit
  suite passed; the ownership primitive is not yet wired into the shipping
  resident engine. Local-drive recovery-root restriction still needs integrated
  path/provenance tests before it is admission evidence.
- Rebuilt protocol-1 regression engine remains **8/8**, with no rescue or
  leftovers, `out/resident-1793634509460`; real Core through that fake engine
  **1/1**, `out/resident-platform-1793634526612`. The new protocol-2 client
  tests use fake pipes, not native protocol-2 replay or real System Proxy.
- Replay prerequisites are now distinct from successful-recovery permission;
  no caller may manufacture `priorRecovery: verified` just to enter replay.
  Native same-owner reservation/replay and durable provenance integration are
  still required. No new Restart/session instructions or activation granted.

### CI 41475913891 retained failure, not acceptance

Windows failed on `42254bf`: 422 tests passed, 1 failed, 1 skipped. The actual
write-through publication fixture's PowerShell child was terminated at its
existing 10s subprocess limit (10084ms observed). Raw job125381303097 log is
`out/ci-41475913891-windows-failed.log`. The log does not localize time between
process initialization, Add-Type compilation and MoveFileEx; do not claim that
one particular substage was proven to hang. No blind rerun or timeout increase.

The implementation unnecessarily spawned PowerShell and compiled a C# P/Invoke
wrapper for every publication. Reuse the already compiled helper instead:
`publish-migration` performs the same local same-directory MoveFileExW
WRITE_THROUGH operation, validates no-replace/replace and returns checked JSON.
It has no proxy/RunOnce API calls. Temporary source bytes still flush before
publication, and result readback remains required. Real private-file integration
now covers missing source, no-replace preservation, replacement, invalid paths,
directory denial and retained source after denial. The old fixture's safety
assertion (stop before collection/registry/proxy operations) remains, now through
the native publisher. Focused 168/168 and all native unit tests passed locally;
new integrated run/CI still required.

The same review found Windows full-suite CI was missing the live read-only
boot-evidence opt-in; it had mistakenly been set only on macOS's Core step.
Windows now explicitly sets it. Earlier green CI therefore did not run this
particular live Windows collector test (local integrated runs did); no skipped
probe is claimed as live evidence.

### Protocol fixture bootstrap/order failure, 2026-11-03 00:34 local

Focused admission/startup/session suite: 82 passed, 1 failed. The premature-ready
case expected `Unexpected` but got `Resident helper request timed out; state
unknown`; 641ms observed against a 500ms protocol fixture timer. This is not a
successful ordering test and not a real Core or WinINet result. The fixture
started that timer before launching/initializing its unrelated Node interpreter,
so process bootstrap competed with the intended protocol fault. The log alone
does not isolate OS scheduling versus interpreter initialization time.

The fake child now explicitly acknowledges bootstrap before the protocol client
is attached; only then a one-byte test trigger sends the out-of-order frames.
The protocol timer remains 500ms, the whole-fixture watchdog remains 4000ms,
and production startup/cleanup budgets are unchanged. A bootstrap rescue still
fails; native/process integration tests remain necessary and are not replaced
by this unit fixture. No retry or broadened assertion substitutes for the fault.

### Exact legacy registration retirement is unsupported locally (2026-11-03)

A standalone HKCU private-key experiment attempted transactional compare/delete
with CreateTransaction and RegOpenKeyTransactedW. The mismatch case failed before
the expected comparison result: error 6801 (ERROR_RM_NOT_ACTIVE). Diagnostic
reproduction printed `mismatch result=6801`; both assertion exits were failures
(3221226505), not acceptance or watchdog rescue. This establishes failure on this
machine, not that all Windows installations lack registry transactions.

The rejected sources are retained as native/migration-retirement.h and
native/migration-retirement.test.c, outside shipping sources and build inputs.
No KtmW32 dependency is added to production. Exact private keys from the two
failed test processes (29380 and 12584) were removed after verifying that they
contained only the fixture's Owned/Other values and no subkeys. Actual RunOnce
and proxy settings were not written. An error-checked read found the actual
legacy value absent; absence is not proof of execution exclusion.

No ordinary query-then-delete fallback is permitted. Windows can consume a
RunOnce value before starting its executable; a missing value and an empty
process snapshot cannot exclude that pending launch. Preparation is being
narrowed to absence-only capture. First resident admission now explicitly
rejects even a controlled-Restart confirmation, pending a proven legacy launch
boundary. Native fake admission remains an isolated coordination test, not a
shipping activation permission. Possible migration alternatives require fencing
the actual old executable entry points or an offline maintenance boundary;
neither has been performed or accepted as complete.

Independent current-source validation: native unit build passed and protocol-2
fake resident plus real Core Platform passed 1/1, with evidence in
out/resident-platform-1793639307088. This is not a final full-suite/CI result.

### Integrated failures and caller migration, 2026-11-03 01:20 local

The uncached workspace run failed: 7/8 tasks, desktop 585 passed / 2 failed.
Raw output remains out/integration-20261103-hold.log. The failures were TCP
EADDRINUSE on fixture port 10573 and the resident-client malformed-channel
fixture timing out during its initial ready wait. Neither is a passing test;
they are not the earlier UDP-excluded mixed-port failure. Dedicated fixes and
a new integrated run are required, with deadlines/assertions retained.

The legacy engine regression also exposed an unmigrated production-wrapper
caller: `Resident requires native reservation and migration authorization`.
Failed watchdog evidence is out/resident-1793640366490/normal/supervisor.json.
Keep the legacy fake engine cases, but run the normal wrapper/abort assertions
through the protocol-2 admission fake with private root/namespace and explicit
fake commitments. The v2 journal keeps its 480-byte provenance header after
endpoint removal; it is no longer a zero-byte legacy journal. No production
authorization bypass or retired shipping command is restored for this test.

Electron 45.1.0 Node-mode read-only smoke verification of the raw archive hashing
module matched Node's SHA256 for the historical cf54ea5 archive:
ebcd282f2b36e9bae86af571f4d093b23209239e6410c52ae0c3d9847f3b2941.
This exercised original-fs without Kuro startup, Core or proxy calls; it does
not make that historical archive a final delivery candidate.

The TCP investigation did not establish a specific Windows TIME_WAIT state.
Removing the extra fixture probe still reproduced EADDRINUSE, so it was not
just that fixture connection. A tighter production-readiness regression then
failed deterministically at 01:42:55: `readiness must receive peer FIN before
reporting success: expected false to be true`. The shared readiness function
destroyed its socket and resolved immediately on the SOCKS greeting, before
establishing peer teardown.

The shared direct/resident readiness path now sends FIN, keeps its existing
250ms/overall deadline through teardown, and succeeds only after peer EOF and
local close. A greeting without peer FIN must time out rather than report
readiness. No timeout increase, port change, skipped assertion or retry was
used. Platform focused suite passed 34/34; real Core through protocol-2 fake
resident passed 1/1 at out/resident-platform-1793641494285. Actual occupation or
an intervening writer can still correctly deny a port; no kernel-state cause
is claimed beyond the observed ordering defect.

The client fault fixture now separates Node bootstrap from its unchanged 500ms
protocol budget and asserts the specific malformed-response failure. Its
delayed-bootstrap regression reproduced the old timeout and passed after the
fix; focused client/admission passed 31/31. Legacy engine plus v2 wrapper/abort
regressions passed 8/8 at out/resident-1793640480306, without external rescue or
leftover children. These focused results do not replace the integrated rerun.

### Owned Core close ordering: failure retained, integrated correction

The next full run still failed (589 passed / 1 failed): port 30617 remained
unavailable immediately after stop, despite completed probe FIN/close. Raw
output is out/integration-20261103-hold-final.log; the filename is not a success
claim. Thus fixing probe teardown alone was insufficient.

A bounded diagnostic stopped on its first failure, not on eventual success:
out/probe-close-diagnostic.log, 01:57:11. After stopCore returned, port 44501
failed bind while the tracked Core PID 7648 still had exitCode=null,
signalCode=null, coreClosed=false, stdoutClosed=false and stderrClosed=false.
Netstat subsequently showed client-side 64145 -> 44501 TIME_WAIT, not a proven
server-side TIME_WAIT explanation. The defect was declaring owned teardown
complete from PID liveness polling before the owned child's close event.

Owned termination now signals the actual ChildProcess handle and awaits its
close promise, registered at spawn. Existing TERM/KILL phase limits are unchanged;
unacknowledged teardown fails and closes restart/proxy-write admission. Orphan
fingerprint handling is not silently generalized to owned-child completion.
The regression asserts probe EOF/close, owned close and immediate rebind. A
separate withheld-close fault asserts bounded failure and denied restart/set.

Final uncached integrated run at 02:02 local passed all 8 workspace tasks:
desktop 591/591, 32 files, zero skips; core 89/89, api 12/12, state 36/36.
Typechecks, real Core integration and the actual read-only boot/checkpoint probe
ran. Raw output: out/integration-20261103-owned-close.log. Latest native private
admission suite passed 65/65 with watchdog reports copied into out/admission-native.
These are current local results; Windows CI and final archive verification are
still distinct, and initial resident admission remains intentionally denied.

Rebuilt post-fix native fixtures then passed 8/8 (out/resident-1793642767494)
and real Core/Platform 1/1 (out/resident-platform-1793642786457), with no external
rescue or remaining processes. The real-WinINet carrier compiled warning-clean;
its local parser/restoration guards and read-only get passed. No local exercise,
set, clear, restore, RunOnce mutation or session event was performed. Fixture
TEMP paths normalize Windows short-name spelling without relaxing the production
canonical-path rejection policy.

### CI 41497752909: fixture failures, not an accepted run

Both jobs failed on commit 16ebbc1. macOS could not identify the readiness
probe when observing destroy (probe was undefined); its EOF/close assertions
therefore failed. Observation now starts at the socket connect event, before
teardown can discard endpoint metadata. All probe EOF/local close, owned Core
close and immediate-rebind assertions remain; no platform skip was introduced.

Windows passed the full desktop suite and base coordination scenarios, then
the wrapper fixture failed the production canonical-directory guard. A local
read-only short-name specimen reproduced the API mismatch on Node 24:
realpathSync("C:\\PROGRA~1") returned "C:\\PROGRA~1", while both native sync
and promises realpath returned "C:\\Program Files". The wrapper and Platform
fixtures now use the same promises realpath as the guard. Production alias
rejection is unchanged; no weaker comparison or timeout extension was made.
Raw CI failure: out/ci-41497752909-failed.log.

The subsequent uncached integrated local run passed all 8 tasks, desktop
591/591 with zero skips, core89/api12/state36, including actual read-only boot
evidence and real Core. Log: out/integration-20261103-ci-fixtures.log.
Private fake wrapper regressions passed 8/8 at out/resident-1793643417465;
real Core/fake resident Platform passed 1/1 at
out/resident-platform-1793643625891. Neither used rescue or left processes.
These local results do not predeclare the next CI successful. No local proxy,
RunOnce, old-helper replacement or session operation occurred.

### CI 41499917232: autonomous fixture alias, reproduced locally

macOS passed. Windows passed the desktop suite, base coordination, wrapper
regressions and the first 58 native scenarios, then autonomous recovery exited
1 before mutation. Its downloaded watchdog report shows rootExitCode=1,
watchdogKilled=false, lingeringChildren=false, remaining=0, processMs=219.
Raw failure and reports: out/ci-41499917232-failed.log and
out/ci-41499917232-evidence. The whole CI run remains failed.

The native fixture runner was a third caller that still passed raw TEMP paths.
Its fake root was normalized, but its retained executable launch path was not;
the production recovery-only check correctly rejected that mismatched spelling.
On this machine, a private TEMP directory's 8.3 alias reproduced the same
autonomous exit1 after the same preceding scenarios. The failed local watchdog
reports no rescue/leftovers and processMs=594. See out/short-temp.json,
out/admission-short-path-red.log and out/admission-short-path-red-watchdog.json.

Changing only fixture base creation to promises realpath made all 65 scenarios
pass under the same short-TEMP condition, including autonomous recovery and its
negative cases (out/admission-short-path-green.log). No production path guard,
budget or assertion was relaxed. Assertions now include helper protocol output
on failure. This is a fixture correction, not evidence that initial app
migration or real session cleanup has become safe.

### CI 41502533486: read-only process failures and collection overhead

Windows failed the port-inventory beforeAll (netsh excludedportrange/tcp) and
the actual read-only PowerShell collector (10027ms); 555 passed / 1 failed /
35 skipped is not full acceptance. macOS passed. The old error messages omitted
exit/signal/killed metadata, so the exact CI cause remains unproven. Raw output:
out/ci-41502533486-failed.log. This run was not blindly retried.

Both paths now retain child failure metadata and elapsed time. The four netsh
reads are sequential with the same 5-second per-command limit. All 24 local
read-only probes succeeded: concurrent per-command156-227ms versus sequential
86-147ms; sequential total387-500ms exceeded concurrent total182-252ms. These
measurements support avoiding overlapping interpreter overhead, not a claim
that the original CI failure was reproduced. Actual TCP/UDP reservation and
all excluded/dynamic range checks remain; four new tests cover serialization,
range retention and failure diagnostics.

A local instrumented collector spent1395ms before machine-identity access
(including runtime C# compilation), and964ms querying all CIM OS properties.
It now reads the same uint64 uptime from the verified helper's boot-clock
command, passes its explicit bound path, and requests only LastBootUpTime.
No runtime compiler is started; the outer10-second budget is unchanged.
The subsequent quiet sample reached the native-clock read at1041ms and completed
it at1214ms; this is an observation, not a guaranteed CI latency improvement.
Private profiles: out/collector-profile.log and
out/collector-profile-native-clock.log (local identity JSON is not published).

The first focused run caught Windows PowerShell not awaiting the GUI helper,
plus an old mock-argument assertion (out/collector-focused.log). An explicit
Out-String pipeline now waits for stdout/exit, and all caller assertions retain
the exact Helper argument. The initial boot-clock regression failure remains
in out/boot-clock-red.log. Actual collection and same-boot denial then passed.

Final uncached integration after these edits: 8/8 tasks, desktop596/596 in32
files with zero skips, core89/api12/state36, including real Core and read-only
boot evidence (out/integration-20261103-readonly-cost.log). Native units passed;
private admission65/65 passed at out/admission-final-readonly-cost.log without
rescue/leftovers. CI and same-head artifact verification remain separate.
Post-build wrapper regressions also passed8/8 at out/resident-1793646523326;
real Core/fake resident Platform passed1/1 at out/resident-platform-1793646539008,
again without rescue or leftovers. These are not real session experiments.
