# 2A-H: prestarted helper coordination experiment

2026-11-02. THROWAWAY, fake operations and fake Core only. This is a coordination
model experiment, **not Windows session-message delivery or logoff reliability
validation**. No WinINet, real Core, proxy settings, RunOnce or generated session messages.
No production code/dependency/configuration, ADR, issue Status or merge changes.

## Verdict

The prestarted helper adds demonstrated process-lifetime independence: it
completed after Electron actually exited, and completed while Electron's JS
thread was blocked. It can terminate its own stuck operation process without
terminating Electron. This is useful enough to propose a separately authorized
real-WinINet experiment, but not to skip straight to logoff/shutdown testing.

It does not guarantee cleanup success or termination of an indefinitely hung
Electron. That latter fixture still requires external rescue and fails whole-
fixture exit acceptance, even though helper/Core independently exited first.

## Run

Use the existing compiler and installed project Electron 45.1.0 (libuv 1.52.1).
Nothing is installed. All profiles/reports/binaries stay under this directory.

```powershell
Set-Location "D:\clash-kuro\.scratch\mvp\prototypes\prestarted-helper-deadline"
node .\build.mjs
node .\test.mjs
node .\test.mjs --watchdog-negative-control
# Narrow regression for parent-lifetime ownership:
node .\test.mjs --case=electron-exit
```

Default suite exit code is 0 when the specified coordination policies hold.
Negative suite exit code is **1**: both rescues are exit acceptance failures.
`negativeControlsObserved: true` only confirms the expected rescue evidence;
it never overrides `accepted: false`. Do not launch the carrier or helper without
the supervised runner. No packaged matrix was added in this narrowed phase.

## Topology and ownership

```text
external native test watchdog: sole owner of containment Job handle
  test-root Node process: survives Electron; observes its real exit time
    Electron: launches helper DETACHED, then sends test trigger over stdin
      helper: independent process lifetime, still inside external test Job
        coordinator (main): starts fake operation, publishes decision
        IPC reader: reads C bytes; EOF also closes this one-shot instance
        native window thread: hidden top-level window; W posts a private test message
        operation thread: fake work, optionally stuck forever
        supervisor: owns deadline decision fallback and ALL fake Core stops
        report writer: test-only filesystem output, separately time-limited
        fake Core: exact child process handle + inherited private stop event
```

All helper threads/events are created before its `ready` acknowledgement.
The follow-up adds a native window and session-event routing scaffold. Tests
only trigger a private WM_APP message, a C byte, or controller pipe EOF; they
never send WM_QUERYENDSESSION / WM_ENDSESSION or initiate a real session end.
No reconnect/restart,
endpoint management, set protocol, queue, persistence or general service exists.

The Electron spawn uses `detached: true, windowsHide: true`. Electron owns its
child-process object and pipe ends, but must not own a kill-on-parent-exit job
for the helper. The external watchdog owns a different Job with kill-on-close
and no breakaway permission. Every accepted case asserts that helper and fake
Core PIDs were observed in that Job. Detached does NOT mean uncontained.

The helper directly creates fake Core using CreateProcess and retains its
process handle from creation. STARTUPINFOEX HANDLE_LIST passes only two private
events (stop and ready), not the controller pipe or test Job handle. The fake
Core neither looks up nor kills any process. Only the helper supervisor signals
the stop event, at most once, and any escalation uses that exact process handle.
PIDs are diagnostic evidence, not termination targets.

The external watchdog is adapted locally from phase 2A, adding a live-members
snapshot immediately before rescue. It launches the root suspended, assigns
the Job before resuming, and only terminates that Job/exact created handles.
It does not kill by process name. An outer 16-second guard can terminate the
exact watchdog handle, closing its Job; that also fails acceptance.

## Closing policy and bounds

1. First trigger atomically closes the one-shot instance and establishes one
   monotonic deadline: start + 1500 ms. All repeats/EOF share it.
2. Coordinator starts one fake operation. Success is published only if the
   operation completes by the deadline. No Node/JS callback is needed.
3. Supervisor waits for that decision using the remaining deadline. If the
   operation or coordinator hangs, it records timeout/uncertainty, not success.
4. Only after success or explicit timeout does supervisor request fake Core
   stop. Core has up to 500 ms, also capped at start + 2000 ms. A stuck Core is
   terminated by its retained handle (exit 41); confirmation waiting ends no
   later than the start + 2100 ms software deadline.
5. Report I/O runs on a precreated test-only writer. Supervisor waits at most
   100 ms, then can terminate this helper (exit 43 if report did not finish).
   A hung operation/coordinator causes helper self-termination (exit 42), not
   an unsafe thread kill, module unload or continuation with unknown state.
6. Healthy completion exits helper normally (0). There is no automatic restart.

The extra supervisor solves one precise failure: the coordinator cannot issue
Core stop/exit if it is stuck. It is also the sole Core-stop owner, so the
coordinator and fallback cannot race to stop Core twice. It has no shared locks,
filesystem writes or blocking pipe reads in its decision/stop path. The report
thread prevents diagnostic I/O from blocking this supervisor indefinitely.

Idle waits before a trigger and deliberate fault waits are infinite by design;
coordinator completion waits are protected by independent supervision. Failure
of that supervisor itself is NOT tolerated: the negative fixture stalls both
coordinator and supervisor and needs external rescue. No claim of arbitrary
multi-thread-failure tolerance is made.

1500 ms is a software waiting budget, not a hard real-time guarantee. Native
API latency, scheduling, process termination and loader/runtime behavior are
not preempted by our arithmetic. Observational assertions are <1750 ms for
timeout decisions and <2350 ms for recorded helper shutdown work. The latter
excludes report I/O and final OS process exit; external Job completion is
separately checked. No Promise wraps a blocking native call.

## Final focused results

One final run per case, deliberately not a broad repeated timeout matrix.
Times below are coarse GetTickCount64 observations from the first helper
trigger. Assertions also compare external timestamps where needed.

| Case | Decision / stop request | Exit outcome | Policy result |
| --- | --- | --- | --- |
| normal | cleared, 62 ms | helper/Core normal | accepted |
| Electron JS blocked 4000 ms | cleared, 31 ms | helper/Core finish while JS blocked | accepted |
| Electron exits early | cleared, 422 ms | helper report 279 ms AFTER actual Electron exit | accepted |
| repeat at about 1200 ms | timeout, 1516 ms | one operation, eight triggers, one Core stop; helper self-terminates 42 | accepted timeout policy, NOT clean success |
| IPC closes before explicit trigger | cleared, 47 ms | EOF initiates closing; normal exit | accepted |
| IPC closes after trigger | cleared, 47 ms | same deadline, one stop; normal exit | accepted |
| operation never returns | timeout, 1500 ms | Core normal, helper self-terminates 42 | accepted timeout policy, NOT cleanup success |
| coordinator never returns | timeout, 1500 ms | operation never starts, Core normal, helper self-terminates 42 | accepted timeout policy, NOT cleanup success |
| fake Core ignores stop | cleared, 47 ms | Core terminated 41; helper normal; shutdown work 562 ms | accepted escalation policy, NOT normal Core exit |

All nine policy cases finished without external rescue and with zero remaining
Job members. Five have entirely normal helper/Core exit, three deliberately
self-terminate the helper, one deliberately terminates stuck fake Core. Do not
describe all nine as successful cleanup or graceful exit.

The repeat assertion checks elapsed wall time against the FIRST Electron-side
trigger acknowledgement, not merely a resettable helper-relative timestamp.
Core stop count and operation count are independently asserted.

| Negative case | Evidence | Overall result |
| --- | --- | --- |
| supervisor + coordinator stuck | no completion report; 5-second watchdog rescues tracked tree | FAIL |
| Electron JS permanently stuck | helper clears/stops Core in 46 ms; both PIDs absent from valid pre-rescue Job snapshot, Electron PID still present | helper independence observed; whole fixture FAIL |

Both negative cases have `remaining=0` after rescue. `independentBeforeRescue`
is true only for the permanent Electron hang. The experiment does not add a
helper responsibility to kill Electron just to turn this failure into a pass.

Final reports:

- `out/runs/1793587866461/results.json`
- `out/runs/1793587881314-negative/results.json`

Each case retains helper, Electron, host-exit and supervisor reports as
applicable. Reports include every observed Job PID and the pre-rescue snapshot.
The build passes C `-Wall -Wextra -Werror` and JS syntax checks. PE imports are
KERNEL32 and Windows UCRT API sets, with no WinINet/RAS/Node import or compiler
runtime DLL dependency. Tests sanitize PATH to Windows directories.

## Important failure and fix

The initial 40 ms fake clear could finish before Electron actually exited,
masking the lifetime bug. Tightening the test to a 400 ms operation and comparing
the external observer's actual Electron exit time made it reliably fail.

Failure reports: `out/runs/1793587435082/results.json` and minimized reproduction
`out/runs/1793587521198/results.json`. Helper disappeared without a report;
external rescue was required. Those failures are retained, not rewritten.

Ranked hypotheses were parent/child job coupling, report/exit failure, and pipe
EOF handling. Changing ONLY spawn `detached: true` made the minimized regression
pass (`out/runs/1793587562431/results.json`). Final tests also verify detached
children remain in the outer test Job. Pipe-only disconnect cases already passed.

Electron reports libuv 1.52.1. Its source explicitly assigns non-detached children
to a kill-on-close job so they die with the parent, and deliberately does not set
CREATE_BREAKAWAY_FROM_JOB for detached launches:
https://github.com/libuv/libuv/blob/v1.52.1/src/win/process.c#L1052
https://github.com/libuv/libuv/blob/v1.52.1/src/win/process.c#L1082

This was an ownership defect in the prototype, not a Windows session experiment.

## Added complexity and comparison

Added production-shaped concepts: one prestarted process, explicit detached
lifetime, one private byte pipe, one-shot closing/deadline state, independent
supervision, and accurate Core process/event ownership. There are no new project
runtime dependencies. The report thread and external Job harness are test-only.

Compared with a Node-API dedicated native window thread:

- **Observed extra value:** helper survives actual Electron process exit. A
  thread inside that process cannot. Helper can end its stuck process without
  ending Electron; Electron observed exit 42 and then chose its own exit.
- **Not unique extra value:** progress during a stalled JS thread can also be
  achieved by independent native threads in the same process. This test is not
  a head-to-head implementation of that remaining Node-API candidate.
- **Structural, not injected here:** native crash/address-space isolation. No
  memory-corruption fault or real WinINet failure was tested.
- **Cost:** lifecycle/IPC and Core authority become more complicated. Startup
  rollback, upgrade/uninstall paths, old cleanup vs new instance races, security
  and production shutdown integration are intentionally not implemented.

Recommend requesting a bounded, independently authorized real-WinINet study
next, with backups/restoration, notification-dependency measurements, and no
restoration until any old writer is confirmed gone. Do NOT directly infer that
a native window receives session events or that Windows will keep this helper
alive during logoff. A real session receiver, GUI/message dependencies and then
separately authorized session experiments still stand between this result and
acceptance of a formal architecture. ADR-0011 remains unchanged and ADR-0013
remains a draft; this prototype is not an exception to either constraint.

## Follow-up: uncertain exit must use runtime state (2026-11-02)

Review before production reuse found that self-termination was selected from
the injected `operation_hang` / `coordinator_hang` flags, rather than the actual
cleanup outcome. A finite 1900 ms operation therefore reported timeout at
1500 ms but returned through the ordinary process exit path while its worker
was still running. This is a policy defect even though the test process exited.

The new `late-operation` regression failed before the fix:
`out/runs/1793591412500/results.json` (`selfForced=false`, no external rescue).
The supervisor now selects self-termination whenever its final decision is not
successful, or the exact Core handle has not signalled exit. It does not infer
safety from the kind of injected fault. This also prevents uncertain shutdown
from depending on ordinary DLL teardown of a still-running operation.

After rebuilding, all ten policy fixtures passed:
`out/runs/1793591447018/results.json`. The late operation produced timeout at
1500 ms, helper exit 42, one Core stop after the decision, and zero remaining
Job processes, without watchdog rescue. Five cases exited normally; four
uncertain cases self-terminated; one case forced the fake Core before helper
normal exit. These are different outcomes, not ten successful cleanups.

Both watchdog negative controls still **failed exit acceptance**, as required:
`out/runs/1793591498972-negative/results.json`. Rescue left no Job members;
the permanently stalled Electron case still demonstrated independent helper
cleanup before rescue, not successful whole-application exit.

Reproduce with `node .scratch/mvp/prototypes/prestarted-helper-deadline/build.mjs`
followed by `node .scratch/mvp/prototypes/prestarted-helper-deadline/test.mjs`.
Use `--case=late-operation` for the minimized regression, or
`--watchdog-negative-control` for the deliberately failing rescue controls.
No proxy, RunOnce or session operation was performed. The timing observations
remain software-budget evidence, not a strict wall-clock guarantee.

## Follow-up: independent native window dispatch (2026-11-02)

The helper now creates an invisible top-level native window on a dedicated
thread before readiness. The private `W` test command posts WM_APP+1 to that
window. Its procedure enters the same closing gate and original deadline used
by IPC/EOF. At this initial checkpoint it did no waiting. It still does no
logging, pipe I/O, lock acquisition or JavaScript callback. The reader, not the
window procedure, acknowledges the test trigger.
No Electron message pumping was introduced.

The new `window-stall` fixture records its start, sends W, and immediately
blocks Electron's JS thread for 4000 ms. Assertions require one actual native
window dispatch, helper closure beginning after the recorded stall start, and
the completed report before Electron resumes. The minimized fixture passed:
`out/runs/1793591727552/results.json`. The complete eleven-case suite passed:
`out/runs/1793591767857/results.json`, including this case's 47 ms fake clear,
one subsequent Core stop, normal helper exit, no rescue and no Job leftovers.
The two negative controls still failed exit acceptance and were contained:
`out/runs/1793591892681-negative/results.json`.

The same procedure includes WM_QUERYENDSESSION / WM_ENDSESSION routing, but
neither event was generated by these tests. Query returns TRUE without veto.
**This initial routing scaffold returned immediately after triggering.** The
next section supersedes that behavior, but neither experiment establishes that
Windows will preserve the helper during an actual session end; this must not
be promoted as a production session-cleanup implementation yet. The
bounded query-phase strategy still needs to be reconciled with real WinINet
notification behavior. Blocking that window may itself cause a notification
dependency; pumping an arbitrary host's message loop is not an acceptable fix.

Only native window dispatch while Electron is unresponsive was verified here.
Real WinINet dependencies, real OS event delivery and session survival remain
unverified. Keep normal-exit, timeout/self-termination and external rescue
outcomes distinct. Reproduce the new case with `node
.scratch/mvp/prototypes/prestarted-helper-deadline/test.mjs --case=window-stall`
after the existing build command.

## Follow-up: bounded query wait and notification diagnostics (2026-11-02)

The native window now waits for the supervisor's shutdown-work completion,
using the original absolute deadline: 1500 ms for clear, Core stop through
2000 ms, and termination confirmation through 2100 ms. This adds no fresh
budget on callback entry or repeat delivery. Logging retains its existing
separate 100 ms allowance. These remain software budgets, not hard real-time
claims. The callback never vetoes a query. A nested query enters the shared
closing gate but returns immediately instead of recursively waiting.

Message-aware waiting is confined to the helper's native window thread; it
does not enter Electron's message loop or call JS. There is no claim that
PeekMessage dispatch itself is bounded. If a native procedure blocks forever,
the independent supervisor reaches the original deadline, reports uncertainty,
stops the exact fake Core, and terminates its own process. The external watchdog
does not provide this policy. Failure of both helper coordinator and supervisor
still requires rescue and still fails acceptance.

The operation sends a **synthetic synchronous message**, not a WinINet call.
The three focused diagnostics in `out/runs/1793592259836/results.json` were:

| Fixture | Observed result | Exit classification |
| --- | --- | --- |
| query-plain | Synchronous-message mutual wait; timeout at 1500 ms | Helper self-termination 42; not successful cleanup |
| query-aware | Message dispatched during wait; one nested query rejected; fake clear at 47 ms | Normal helper exit |
| query-handler-hang | Native procedure deliberately never returns; timeout at 1500 ms | Helper self-termination 42; not successful cleanup |

All fourteen policy fixtures matched their expected outcomes with no external
rescue and no remaining Job processes. Seven completed normal fake cleanup,
six reported uncertainty and self-terminated, and one forced fake Core exit.
The two external rescue controls remained exit failures:
`out/runs/1793592516610-negative/results.json`. Neither counts as acceptance.

Reproduce each diagnostic with the existing build and
`node .scratch/mvp/prototypes/prestarted-helper-deadline/test.mjs --case=query-aware`
(substitute `query-plain` or `query-handler-hang`). Windows CI now builds this
isolated fixture with its existing GCC toolchain, runs the policy suite and
verifies the expected failing rescue controls. It preserves results JSON as
`kuro-helper-coordination-evidence`; it does not package the prototype into Kuro.

This is still only coordination-model evidence. No real WinINet message
dependency, WM_QUERYENDSESSION delivery, Windows termination grace period,
logoff or shutdown reliability has been established. No proxy or RunOnce
settings were touched; competing proxy applications still prevent safe writes.
