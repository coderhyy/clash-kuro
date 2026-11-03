# Current-owner native safety suite

`admission-test.mjs` keeps its filename for the existing CI entry point, not its
old protocol. It now compiles the shipping protocol 3 engine through
`admission_fake.c`; `resident_fake.c` includes that same engine/fixture. It uses
private temporary roots, a UUID-namespaced native owner mutex, fake LAN/RAS and
forbidden registry APIs. No real proxy/registry writes or actual session operations
are allowed. The `query` case posts only to the fixture's own private window.

The binary protocol is start/ready 3 with no authorization frame. Journal headers
are 416 bytes, endpoint records 608 bytes. Journal inspection occurs after helper
exit; inability to read a live journal is an expected exclusive-lock assertion.
The fake WinINet set checks that the endpoint was persisted first. Each child
scenario is contained in the exact-child Job watchdog; rescue or lingering children
fails acceptance. CI receives per-case watchdog JSON and `last-run.json`. Temporary
scenario directories retain closing/shutdown JSONL with actual fake flags/timings.

Safe command, from the repo root:

```powershell
node .scratch/mvp/prototypes/prestarted-helper-deadline/native/admission-test.mjs
# Focus one private scenario without exercising other cases:
node .scratch/mvp/prototypes/prestarted-helper-deadline/native/admission-test.mjs --case=shutdown-readback-reenabled
```

## Historical evidence and explicit retirement

The former 65-case protocol 2 admission suite remains in repository history. It
is not silently skipped, reported as passing, or retained as a production bypass.
The active 78-case replacement preserves native safety failures and explicitly
retires properties of the deleted migration/registration design:

| Former cases | Current scope/replacement |
| --- | --- |
| `initial`, `pending`, `header-only`, `seed-replay`, `seed-bound` | Native-owned initialization/replay: `initial`, `replay-success`, `header-only`, `endpoint-bound`; no caller-supplied admission or seeds. |
| `contention`, `junction-root`, `changed-retained-helper` | `owner-contention`, `recovery-contention`, `journal-contention`, `root-junction`, `retained-changed`; contenders preserve durable pending state. |
| `corrupt`, `legacy`, `wrong-sid`, `wrong-helper` | `reject-corrupt`, `reject-legacy`, `reject-v2`, `reject-sid`, `reject-helper`; invalid/foreign bytes stay unchanged and no Core is created. |
| `seed-write-fail/short/hung`, `seed-header-fail/crash/short` | `append-fail/short/hung`, `header-fail/short/hung/crash`, `flush-fail/hung`; journal failure never reaches fake WinINet set. |
| `seed-overflow/duplicate/invalid` | CLI seeding removed; v3 journal units enforce endpoint validation, deduplication and eight-endpoint bound. `endpoint-bound` replays all eight. |
| `seed-autonomous-denied`, `autonomous-empty`, `autonomous-source` | Native-uninitialized recovery is now intentionally a no-op: `recovery-missing/empty`; `recovery-source` rejects a non-retained executable. No CLI seeds can authorize it. |
| `seed-close/eof/query/deny`, `existing-close/eof/query/malformed/exec` | Pre-ADMIT waiting does not exist. `eof`, `query`, `malformed-admit`, `unknown-frame`, `truncated-exec`, `close-replay`, `close-hung` cover actual current-owner cancellation/framing/deadline properties. Ready permits EXEC without an admission callback. |
| `no-admit`, `exec-before-admit`, `bad-nonce`, `bad-journal`, `zero-proof`, `wrong-receipt`, `truncated-admit`, `close-then-admit`, `duplicate` | Receipt/nonce/proof handshake and replayable ADMIT are retired. `malformed-admit` rejects the old frame. `repeated-close` proves closing cannot renew the original budget. Native provenance validation is covered independently of clients. |
| `existing-seeds-ignored`, `header-seeds-ignored` | No seed options remain; native replay depends only on validated durable endpoints, never a client-proposed endpoint. |
| `warm-fail/hung/late`, `late`, `hung` | `replay-readback-fail/hung/late`, `replay-clear-fail/hung/late`, `replay-readback-reenabled/ras-fail`, `replay-reset-fail/hung`; startup cannot publish ready after unsuccessful/late verification. |
| `core-hung/late` | `core-fail/hung/late`; suspended owned-Job creation, no ready on failure, bounded exit without claiming unproved Core confirmation. |
| `autonomous`, `autonomous-hung/late` | `autonomous-success`, `autonomous-clear-fail/hung`, `autonomous-readback-fail/hung/reenabled`, `autonomous-reset-fail`; retained recovery has no ready/Core. Late completion is additionally tested through the shared replay engine. |
| `shutdown-unregister-fail/hung`, `unregister-fail/hung/late`, `autonomous-unregister-fail/hung` | Automatic RunOnce is removed, so registration-hang acceptance is obsolete, not skipped. Registry calls are forbidden in every active fake case; the shipping negative unit proves successful set/clear/readback make none. Journal reset, clear/readback and logging hangs remain active. |

## Additional current-version guarantees

- `update-empty/pending` accepts a native same-SID previous v3 hash only with the
  verified prior retained file present, clears pending endpoints, then rebinds.
  Missing/changed old files and failed readback preserve the original bytes.
- Shutdown clear/readback/reset faults mirror startup faults, including actual
  still-enabled endpoint flags. Foreign proxy settings remain untouched.
- Late completion and a deliberately delayed supervisor cannot turn timeout into
  success. Repeated close does not renew the first deadline.
- Hung/late/slow mutation, blocked Core stderr and hung persisted logs cannot
  strand the owned Job or helper. Successful reports require flags readback;
  persisted JSONL must match the stdout report and record closing first.
- Journal units additionally test strict digest reads versus SID-bound owner
  inspection, pending-endpoint rebind rejection, SID mismatch, empty rebind,
  successful handoff and short-write/write/flush errors.
- Every recovery-only failure, including hung clear/readback, requires
  `corePid:0` and `coreGone:true`. The native no-Core startup barrier is completed
  before recovery threads launch; the supervisor still verifies the empty Job.
- The negative registry unit also models a preempted first closing publisher and
  checks immutable first reason/epoch/deadline on a later trigger.
- `query` and `log-hung` instrument supervisor event/wait calls: report release,
  a completed wait of at most 100 ms, then session-finished publication. The wait
  is capped by the original 2100 ms deadline; persistence within 100 ms is not
  assumed, and the final 2200 ms cap remains unchanged.
- `diagnostics-report-delay` deterministically holds the supervisor's diagnostic
  drain wait and delays the released reporter by 125 ms. A blocked diagnostic sink
  stops consuming shutdown time at the original 2000 ms deadline, leaving the
  bounded evidence opportunity without changing the 2100/2200 ms caps. Like
  `diagnostics-stall`, this still requires exit 0, successful clear/readback and
  matching stdout/persisted shutdown evidence; hung logs still require exit 42.
- Each case retains bounded child execution stdout/stderr in `*.execution.json`.
  A caught assertion also writes `*.failure.json` with protocol output, log content
  and a bounded diagnostic tail. Existing CI's native JSON glob uploads both;
  assertion messages no longer contain 64 KiB of repeated diagnostic noise.

The guarded WinINet `serve.c` fixture uses the same current engine. CI's `recover`
cycle in `replay.c` launches the actual content-addressed retained executable with
`recover-admitted --log`, inside an exact-child Job. It passes only the private
fixture root/mutex through its child environment, not a native recovery-root option.
It requires closing then shutdown with no ready, no Core and verified readback;
after exact helper exit the parent verifies the empty journal and native binding.
The pure fixture self-test checks command construction and recovery framing,
including rejection of ready or a nonzero Core PID. This fake suite retains fault
coverage. Compile those WinINet fixtures locally if needed; do not run their
proxy-changing cycle locally.
