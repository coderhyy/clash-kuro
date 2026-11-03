# Current Windows resident contract

## Commands and ownership

`start --core <absolute exe> --data <absolute directory> [--log <absolute file>]`
acquires the native per-user owner mutex, pins non-reparse recovery ancestors and
the content-addressed retained executable, and exclusively opens `recovery.bin`.
It validates/replays the journal before creating Core suspended in a kill-on-close
Job. Ready is published only after replay/readback and Core creation succeed:

```json
{"ready":true,"protocol":3,"recoveryVerified":true}
```

Only protocol 3 is supported. `reserve`, resident `serve`, old `recover`, ADMIT,
nonces, receipts, admission evidence, CLI endpoint seeds and CLI recovery roots
are not compatibility paths. The inherited private pipe accepts bounded EXEC=1
UTF-16LE argv and CLOSE=2 frames. EOF or invalid input permanently closes that
instance. A failed mutation closes before its response can invite another write.

`recover-admitted [--log <absolute file>]` is an explicit startup/manual recovery
command, run from the native content-addressed retained path. It uses the same
owner and exclusive journal locks, starts no Core and publishes no ready event.
A missing or zero-byte journal succeeds without proxy calls, header creation or
registration. An active owner refuses a contender without consuming pending
endpoints. Exit 0 means verified completion (or the empty no-op); exit 42 means
cleanup/confirmation/reporting failure or timeout; ownership/provenance/usage
refusals return 1. Initialization failures can return 3.

## Journal and application updates

The current header is 416 bytes: protocol 3 magic/version/size, native user SID,
helper SHA-256 and corruption checksum. Endpoint records are 608 bytes; at most
eight distinct validated endpoints are retained. Append and flush happen before
WinINet set. A checksum is corruption detection, not hostile same-user protection.

Under the owner lock, a valid same-SID protocol 3 journal may name a previous
helper hash. Native must open, hash-verify and pin that previous retained helper
before using its binding. It clears and reads back the complete pending endpoint
set, resets endpoints only after verification, then flushes a current-hash header.
This also handles a previous header with zero endpoints. Both helper files stay
pinned throughout. Missing/changed prior helpers and invalid/old-format journals
are refused unchanged. This is current-version update handoff, not legacy
migration. Disk/flush failures may leave torn bytes; they never authorize a new set.

## Closing, deadlines and evidence

The first closing trigger latches admission closed. Session query is sufficient;
a later cancelled end-session does not reopen the instance. Native emits an early
`command:"closing", protocol:3` event before final `command:"shutdown"` so main
can latch application state immediately. Stdout serialization prevents ready from
appearing after that event. Trigger masks are failure=1, IPC=2, EOF=4, Core exit=8,
session query=16, committed end-session=32, explicit recovery=64.

Clear, notifications, fresh LAN/RAS readback and durable endpoint reset share the
original 1500 ms cleanup deadline. Startup replay has the same single budget,
including initialization and Core creation; close during replay does not renew it.
Readback rejects a still-enabled owned manual endpoint even if the clear API
succeeded. Foreign endpoints are preserved. Unknown RAS/query state is failure.
Completed work observed after the deadline is still a timeout.

Native then forces only its owned Job/Core, confirms no Job members remain, and
caps confirmation at 2100 ms and reporting/helper exit at 2200 ms from the same
origin. Diagnostic draining stops waiting at 2000 ms so a blocked stderr sink
cannot consume the original bounded reporter-before-finished evidence slot
(at most 100 ms, capped by the remaining 2100 ms deadline). This does not reserve
extra time if Core confirmation itself needs the full 2100 ms, renew any deadline,
or guarantee filesystem flush. This is not a graceful OS signal: the existing Windows Node
`child.kill(SIGTERM)` also uses forced termination. No process-name/PID search is
used. A hung startup may report `coreGone:false` rather than falsely claiming that
Core creation can no longer be in progress; final Job close still contains it.
Recovery-only marks the Core-start barrier complete before its threads run because
that command cannot create Core; even hung replay must confirm its empty Job as
`coreGone:true` with `corePid:0`, rather than wait on an impossible creation path.

The optional rotated, best-effort log is JSONL containing closing and shutdown
records. Final evidence includes first reason/epoch, query/end counts, individual
flags and epochs, clear start/completion, post-notification readback completion,
Core stop/confirmation offsets, the clear result, actual connection flags in
`cleanupReadback`, and `cleanupReadbackVerified`. Uncompleted timings/results are
null. `ok` additionally requires durable reset and confirmed Core exit. A blocked
log/stdout path cannot extend the supervisor's original exit bound, but may prevent
the final evidence record from being persisted.

## No RunOnce

No resident or one-shot set/clear registers, deletes or inspects RunOnce. The old
registration implementation and command builder are removed. Read-only
`resident-paths` retains `recoveryRegistrationPresent:false` in its response shape;
it does not query the registry. Existing development entries are not migrated or
deleted.

After a crash, power loss or offline uninstall, an owned proxy can remain enabled
until next app startup or explicit retained-helper recovery. There is no automatic
login cleanup guarantee. The journal, retained executable and lock support
startup/manual recovery, including startup without an active Core profile; main
must sequence that recovery and wait for exact helper exit before another writer.

## Safe verification

From the repository root, these commands use only pure units/private fake fixtures:

```powershell
node apps/desktop/scripts/build-sysproxy.mjs --test
node .scratch/mvp/prototypes/prestarted-helper-deadline/native/admission-test.mjs
```

The real WinINet cycle and real session end are separate guarded CI/manual checks,
not part of local acceptance. See the private native `current-owner-tests.md` for
the historical admission-case replacement map.

The shipping executable rejects standalone CLI `set` and `clear` before calling
WinINet. The shared command parser is reachable for writes only inside the
admitted resident. `get` remains read-only; manual recovery must use the locked
`recover-admitted` route. The unused development `publish-migration` command and
its file-publication implementation are removed, not supported as compatibility.
