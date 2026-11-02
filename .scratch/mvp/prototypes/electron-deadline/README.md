# Phase 2A: isolated Electron deadline experiment

Date: 2026-11-02. Decision: **current message-aware candidate rejected; do not
advance this implementation to real WinINet (2B)**. Basic loading and process
exit feasibility passed; bounded dispatch without arbitrary JS reentry did not.
This is not a fix for session-ending proxy cleanup.

## Scope and files

Everything here is throwaway and uses fake operations. No production dependency,
packaging configuration, Platform, Core, RunOnce, proxy setting, ADR or issue
status is changed. No real logoff/shutdown experiment was performed.

- `native/prototype.c`: pinned Node-API addon, one native worker, fixed events,
  fake notification recipient and deadline/reentry diagnostics.
- `native/watchdog.c`: external per-launch Windows Job Object supervisor.
- `main.cjs`: Electron carrier with hidden BaseWindow and no renderer.
- `build.mjs`: verified Electron headers and existing compiler; no installation.
- `package.mjs`: independent unsigned directory build, using installed Electron.
- `test.mjs`: external runner, assertions, timing and process-tree evidence.
- `out/`: headers, build metadata, binaries, package, isolated profiles, reports.

Electron 45.1.0 (the project's actual version), electron-builder 26.18.0,
Node v24.22.1, existing LLVM-MinGW gcc/clang 23.1.4. C compilation uses
`-Wall -Wextra -Werror`; all four JS entry files pass `node --check`.

## Reproduce

Run in PowerShell; commands only build/run this fake-operation prototype:

```powershell
Set-Location "D:\clash-kuro\.scratch\mvp\prototypes\electron-deadline"
node .\build.mjs
node .\package.mjs
node .\test.mjs --target=dev --repeat=3
node .\test.mjs --target=packaged --repeat=3
node .\test.mjs --target=dev --watchdog-negative-control
node .\test.mjs --target=packaged --watchdog-negative-control
```

Full matrices intentionally return **2**: diagnostics completed, architecture
gate rejected. Negative controls return **1**: watchdog termination is an exit
acceptance failure, never a passing exit. A selected case can be reproduced with
`--case=foreign-js-stall` (inspect `candidateAccepted` even if fixture assertions
complete). Do not launch the carrier directly without its external supervisor.

## Final matrix

Each ordinary row below ran 3 times with `app.quit()` and 3 with `app.exit(0)`,
in each of development and packaged environments (84 launches per environment).
Numbers are observed first-call wall times in milliseconds, not guarantees.

| Fake case | Development | Packaged | Interpretation |
| --- | --- | --- | --- |
| success | 20.33-35.70 | 21.88-29.23 | Clear completed |
| set-before-clear | 148.33-166.29 | 150.87-165.85 | Set completes before clear |
| clear-hang | 1503.37-1515.04 | 1504.62-1515.00 | Timeout, no success claim; process exits |
| set-hang | 1503.21-1512.06 | 1500.59-1511.89 | Timeout, no success claim; process exits |
| late-set | 1500.57-1509.06 | 1500.19-1510.92 | Released after timeout; set then clear, sticky uncertainty |
| late-clear | 1501.46-1512.46 | 1500.74-1514.20 | Released after timeout; sticky uncertainty |
| lock-hang | 1503.30-1514.87 | 1499.85-1511.72 | Worker-only lock fault does not trap caller |
| log-hang | 20.76-33.22 | 20.83-37.06 | Completion published before fake logger hangs |
| plain-sync-message | 1500.12-1510.52 | 1500.73-1513.75 | Expected mutual wait; NOT successful message chain |
| aware-sync-message | 21.53-35.55 | 20.80-34.80 | Controlled synchronous message chain completed |
| aware-flood | 1500.12-1500.44 | 1500.11-1500.15 | Deadline stops flood waiting |
| foreign-reentry | 22.21-37.26 | 22.32-29.96 | Rejected: foreign sent WM_CLOSE invokes Electron JS |
| foreign-js-stall | 2100.54-2104.42 | 2100.53-2101.48 | Rejected: JS dispatch exceeds outer budget |
| native-handler-stall | 2105.22-2116.27 | 2106.39-2113.85 | Rejected: native handler exceeds outer budget |

Per environment: 60 validated-behavior observations, 6 expected baseline
limitations, 18 candidate-safety failures. Do not describe this as 168 passing
architecture tests. All 168 completed fixture assertions and exited without a
watchdog kill or remaining Job members.

Normal quit and immediate exit are separate observations:

| Exit path | Development (42 each) | Packaged (42 each) |
| --- | --- | --- |
| app.quit, before-quit and will-quit observed | 71-288 ms | 70-227 ms |
| app.exit(0), those lifecycle events bypassed | 29-178 ms | 26-179 ms |

These times run from the final report timestamp to an empty Job, not from the
first clear, and do not include all earlier lifecycle work. Both paths returned
exit code 0. They demonstrate process exit with pinned/hung native work, not
safe native module unloading or a production shutdown-time guarantee.

Negative controls: two launches per environment intentionally omit the exit
call and remain alive. All four were killed by the 4-second external watchdog,
all four fail exit acceptance, and all four ended with zero remaining Job
members. The quit/exit labels on these controls are requested modes only:
neither exit API is actually invoked by the negative fixture.

## Deadline, message dispatch and memory review

The first clear establishes one QPC deadline, with a 1500 ms software waiting
budget; all later calls retain it. Completion is a native event, independent of
JS callbacks. Timeout remains uncertain even after late completion. Closing
rejects all new sets. The single worker orders accepted set before clear.
Nested clear returns busy rather than waiting recursively (observed 0.06-0.19
ms); nested set is rejected. A scheduled JS timer did not run inside the wait.

However, `PeekMessageW` filtering by private HWND and message does **not** stop
dispatch of other incoming sent messages on that GUI thread. The synthetic
WM_CLOSE reaches the hidden Electron BaseWindow and invokes its JS handler.
That handler can run arbitrarily long. Neither an outer deadline nor the
recursive-clear guard can preempt it. A native window procedure can likewise
overrun. The controlled private handler normally uses no locks, Node calls or
outbound messages; its explicit stall is a fault injection. No caller-side lock
is held across dispatch. The unsafe dispatch boundary itself remains unresolved.

The plain-wait fixture returns timeout with zero handled notifications; the
message is handled only after returning to Electron. Its late completion stays
uncertain. This is deliberately not classified as message-chain success.

The 1750 ms call threshold, 100 ms repeat threshold, and 1000 ms exit threshold
are observation criteria only. Scheduling, DLL loading, Windows API latency,
memory allocation and arbitrary dispatched code prevent a strict wall-clock
guarantee. Initialization occurs before tests; its readiness wait is 250 ms,
but loader/window creation/Node-API work are not thereby hard-bounded.

The DLL is pinned for process lifetime; static storage and handles remain valid
for outstanding native work. Cleanup sets flags and wakes the worker without
joining, freeing active storage, or calling JS. No in-process reinitialization
or real unload is supported. No forced thread termination is used. Diagnostic
file writes occur outside the measured wait; the supervisor bounds the test,
not those filesystem operations. Fake logger blocking follows completion and
does not represent a production logging guarantee.

For any future production design, uncertain cleanup must irreversibly close
the write gate, reject all proxy writes/reinitialization, and lead to bounded
process termination rather than return to a usable proxy-writing app. This
carrier verifies exit mechanisms only; it does not implement that policy in
the real app or prove a bounded whole-app exit with its other hooks.

## Packaging and watchdog evidence

Independent executable:
`out/packaged/win-unpacked/kuro-deadline-prototype.exe`.
ASAR contains only `main.cjs` and generated `package.json`; addon is outside ASAR
at `resources/native/deadline.node`. Development and packaged addon SHA256:
`199dd9c9a81c9d70c01978309dab61948dba5c3f9b8fe6ff9940473f43c486fb`.

Addon imports: USER32.dll, KERNEL32.dll and Windows UCRT API sets. It has no
node.exe, libgcc/libwinpthread, WinINet or RAS import. Minimal Node-API symbols
are resolved from the Electron host exports. Actual loaded module paths are
recorded in every carrier report. Both targets load the expected addon path;
none report libgcc/libwinpthread/libstdc++ modules. Child PATH contains only
Windows directories. This verifies this machine/architecture, not every clean
Windows installation. Electron's internal OS activity is not an assertion that
the entire runtime never reads any system network state; the experiment makes
no explicit proxy operations.

Each launch is created suspended and assigned to a fresh unnamed Job before
resume. Breakaway is not enabled; kill-on-job-close contains descendants.
Only tracked Job members or the exact created process handle are terminated.
No process-name kill is used. Reports include observed PIDs and final Job
membership; fast-lived children need not appear in sampled PID lists but are
contained by Job inheritance. A 20-second outer watchdog covers a stuck
supervisor. Forced termination and leftover-child cleanup both fail acceptance.

Final immutable reports under `out/runs/`:

- `1793585924121-dev/results.json`
- `1793585940244-packaged/results.json`
- `1793585972421-dev-negative/results.json`
- `1793585980832-packaged-negative/results.json`

## Failure and correction record

- No toolchain installation or compatibility workaround outside the prototype
  was needed. Host-export Node-API binding avoided a node.exe import dependency.
- Supervisor telemetry was corrected to capture root exit when observed and
  report Job-empty time separately; final matrices use the corrected version.
- Ordinary waiting reproduced synchronous-message mutual waiting as expected.
  Message-aware waiting completes the controlled chain but exposes foreign JS
  reentry. The guard fixes recursive waiting/new-set admission only, not arbitrary
  dispatch duration. That architectural failure is **not fixed or waived**.
- All four negative controls are retained as exit failures, demonstrating the
  harness does not count watchdog termination as success.

Do not proceed to 2B with this pump. A differently bounded dispatch strategy or
an asynchronous GUI-thread design needs a separately agreed fake-operation
evaluation before real WinINet. This does not rule out every Node-API design.
Real notifications, LAN/RAS, OS session-ending timing, production quit hooks,
updates/uninstall, RunOnce races, and signed installer deployment remain untested.
