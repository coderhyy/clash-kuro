# Throwaway Node-API deadline experiment (phase 1)

This is not an app integration or an accepted architecture. ADR-0011 is unchanged;
ADR-0013 remains a draft. Only fake in-memory operations run here. No WinINet,
registry/RunOnce, Core, logoff, shutdown, or proxy settings access.

## Reproduce on Windows x64

Use Node (not Bun), with LLVM-MinGW `gcc` and Windows `tar` on PATH:

```powershell
Set-Location D:\clash-kuro
node .scratch/mvp/prototypes/node-api-deadline/build.mjs
if ($LASTEXITCODE -ne 0) { throw 'Prototype build failed' }
node .scratch/mvp/prototypes/node-api-deadline/test.mjs --repeat=3
if ($LASTEXITCODE -ne 0) { throw 'Prototype acceptance failed' }
```

The build downloads the running Node version's headers and x64 import library
from nodejs.org over HTTPS, checking their published SHA-256 hashes. Inputs,
binary, build arguments and machine-readable results stay in ignored `out/`.
No package.json, lockfile, installed dependency or production build changes.
`CC` can select another compatible mingw-w64 compiler.

Watchdog negative control (intentionally **fails**, exit code **1**):

```powershell
node .scratch/mvp/prototypes/node-api-deadline/test.mjs --watchdog-negative-control
```

This case reports successful fake cleanup but deliberately keeps a JS interval
alive. The external parent kills it after two seconds and records `pass:false`,
`killedByWatchdog:true` in `out/negative-control.json`. It is NOT an accepted exit.
Normal cases have an eight-second external watchdog; any kill is a failure.

## What the implementation proves / does not prove

- `init` pins the DLL and creates one native thread plus eight unnamed events
  during normal startup. All requests and trace entries live in fixed static
  memory. One owner Node environment and one fake set per process are supported.
  This is intentionally not a general work queue or a reloadable module.
- The first clear creates one QPC-based deadline, 1500 ms from entry. Repeated
  clear calls retain it. The worker sets a Windows event, without calling Node,
  V8, JS, libuv or a thread-safe function. A JS timer scheduled before clear stays
  unexecuted until the native wait returns; successful clear does not need it.
- Only the worker performs fake set, clear, lock and diagnostic operations. It
  serializes an accepted set before clear. Closing rejects new sets. A hung set
  blocks clear from starting, but not the caller from timing out. A late set can
  still finish after the deadline, then clear follows if the environment lives.
  Timeout is sticky: a later completion does not retroactively report success.
- A real `WAIT_TIMEOUT` is authoritative even if a following QPC reading is just
  before the deadline. The pre-fix repeated run exposed this clock boundary;
  `early-timeout` now injects it deterministically as a regression case.
- Native environment cleanup sets atomic stop/closing flags and signals wake;
  it never joins a thread. The stuck worker never retains a `napi_env`, JS value,
  JS callback or pointer into a Node-managed buffer. Its static memory and event
  handles are NOT freed while it may still run.
- **The DLL is intentionally never unloaded after init.** `GET_MODULE_HANDLE_EX_FLAG_PIN`
  retains its code until process termination. Up to one native thread/stack,
  eight event handles and fixed state remain process-owned. Normal Node process
  exit ends remaining native threads; this is NOT safe cancellation or recovery
  of the stuck operation. Repeated module reload/initialization is unsupported.
- `env-natural` and `env-terminate` destroy the owning Node Worker environment
  while its native operation is still stuck; the parent verifies the native
  cleanup hook ran. `env-late-return` releases it *after* that teardown, observes
  its late fake set finish, and observes native thread exit using retained state.
  These test environment teardown, not successful physical DLL unloading.

## Bounded waiting versus a real-time promise

The native clear path has no explicit unbounded lock, I/O, initialization or join.
Its sole operation wait is finite. The only `INFINITE` waits are on the raw native
worker: idle wake and deliberately injected stuck operations. Cleanup does not
wait for any of them. The fake log stall happens after completion is signaled;
there is no main-thread file logging. This does **not** validate real log durability.

Initialization readiness is waited on for 250 ms. DLL loading, OS event/thread
creation and Node registration happen before cleanup is enabled; their total
duration has no hard OS guarantee. A failed/not-ready initializer reports failure,
not working cleanup. A hung initializer cannot prevent process exit in these tests.

This is a bounded **application waiting policy**, not a mathematically strict
wall-clock guarantee. Windows scheduling, suspension, kernel calls and runtime
pauses are outside that guarantee. Snapshot/result construction allocates JS
objects after waiting; GC/Node API duration is not bounded by the native deadline.
`wallMs` measures the full call, whereas `nativeMs` is a diagnostic inside it.
Acceptance uses 1750 ms observed full-call tolerance, repeat-call <100 ms, and
process exit <1000 ms after its final report. These are failure thresholds for
this experiment, not proof of real-time behavior or an extra production budget.
The partial-budget case uses <1350 ms for the second wait after spending ~350 ms
of the original budget; a new 1500 ms allocation would fail.

If the requirement means every full handler including runtime/OS work must finish
within exactly 1500 ms in all circumstances, **this prototype does not meet or
prove that requirement**. A future shutdown adapter should minimize allocations
and move diagnostic formatting off that path, but that still cannot make Windows
a real-time OS.

## Cases and output

| Case | Check |
| --- | --- |
| success | Completion while JS callback cannot execute; repeat clear is idempotent |
| set-before-clear / queued-set | Accepted set precedes clear, running or still queued |
| clear-hang / set-hang | Caller times out; process exits with native operation still stuck |
| late-set / late-clear | Late completion retains storage and cannot turn timeout into success |
| lock-hang | Worker lock stall cannot hold the caller beyond its wait budget |
| log-hang | Diagnostic stall after completion cannot hold cleanup or process exit |
| init-hang | Readiness timeout fails closed; stuck initialization does not hold exit |
| partial-budget | Early not-ready result and later event share one deadline |
| explicit-exit | Explicit Node process.exit works with a stuck native operation |
| early-timeout | WAIT_TIMEOUT before QPC deadline latches uncertainty |
| env-natural / env-terminate | Environment cleanup does not join a stuck native thread |
| env-late-return | Native thread returns safely after its owning environment is destroyed |

`out/results.json` contains per-case assertions, full-call timings, native state,
trace, process exit code/signal, exit-after-report timing and watchdog status.
Trace codes: 1=set start, 2=set done, 3=clear start, 4=clear done, 5=log start,
6=native thread exit. A report alone is never sufficient: the parent requires
actual process exit with code 0 and no watchdog kill.

## Decision boundary

### Local result: 2026-11-02 (Asia/Shanghai)

- Windows x64, Node v24.22.1, Node-API v8, LLVM-MinGW clang 23.1.4;
  `-O2 -Wall -Wextra -Werror`. Final suite: **16 cases x 3 = 48/48 passed**,
  **zero watchdog kills**. Syntax checks passed for all three JS scripts.
- Full-call hung-operation waits observed **1501.153--1514.448 ms** (not exactly
  <=1500 ms; the OS timer/scheduler can return later). Repeat timeout calls were
  **0.007--0.100 ms**. After ~350 ms already spent, the second event waited only
  **1151.890--1154.284 ms**, preserving the original deadline.
- Every accepted child actually exited with code 0; exit after final report was
  **8.700--32.563 ms**. Native-thread hangs, environment teardown and late returns
  did not require killing those processes. Worker.terminate is an intentional
  environment-teardown test, distinct from killing the process with the watchdog.
- The negative control returned a successful fake-clear report but failed exit:
  parent killed it at **2035.4 ms**, `pass:false`, suite exit code **1**, as required.
- An earlier 45-case repetition had **3 failures**, including **1 watchdog kill**.
  WAIT_TIMEOUT was not latched when the subsequent QPC sample was still before
  the deadline. The environment test's failed assertion left its intentionally
  held Worker alive; the watchdog correctly marked that case failed. Evidence
  retained in `out/results-before-timeout-fix.json`; it is not counted as passing.
  Fix: latch the actual timeout immediately; deterministic `early-timeout`
  regression plus the fresh 48-case suite passed. No false-success case was
  observed, but the old timeout-state bug was real.
- `llvm-objdump -p out/deadline.node` shows imports only from node.exe, KERNEL32
  and Windows CRT API sets; no WinINet, RAS or Advapi32 imports.
- Final binary SHA-256:
  `E86FA0EDAA653F698E6B5DFA0DD6BC393816A38E3006C17C2E81DD5F5459E150`.

Continue feasibility evaluation only if process-lifetime pinning and a bounded
waiting policy are acceptable tradeoffs. Prefer a separate prestarted process if
safe recovery/restart of a hung native service or native crash isolation is required.
No real WinINet or Electron lifecycle conclusion follows from fake-operation tests.
Further initialization, GUI message-pump/reentrancy, WinINet notification, packaging,
ownership/RunOnce races and session-end experiments need a separately approved plan.

Relevant contracts:
- [Windows module pinning](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw)
- [WaitForSingleObject, including GUI/message-loop caveats](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject)
- [Node environment cleanup hooks](https://nodejs.org/api/n-api.html#napi_add_env_cleanup_hook)
- [Windows process exit](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-exitprocess)
