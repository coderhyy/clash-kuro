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
