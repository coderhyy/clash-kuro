# Recovery admission: implementation gate

Draft engineering design, not an ADR change or final architecture acceptance.

## Rejected ordering change

Moving the existing single-endpoint RunOnce write before set is insufficient:

1. Endpoint A is enabled, with recovery command A.
2. A port change registers command B before writing settings.
3. The write fails, hangs or the process dies before replacing A.
4. Recovery B sees A as notOurs; A is stranded.

The attempted patch was reviewed and withdrawn before commit or real writes.
The current implementation still has its original write-before-registration
gap; neither ordering is accepted for the resident route.

## Required transaction boundary

Use one per-user ownership record and a stable recovery executable outside the
versioned app directory. Keep all admitted endpoints until verified clear, not
only the latest port. Before any mutation, persist the union of old and proposed
endpoints and register recovery. A failed admission cannot modify proxy settings.

All new resident mutations and recovery runs must acquire the same user-scoped
exclusive OS lock with bounded waiting. A recovery command must not take a
generation snapshot before acquiring that lock. An old delayed recovery invocation
must not clear a live new instance, even if the endpoint is identical. The resident
holds ownership through its entire lifetime, including timed-out native writes;
only process death releases ownership, never an impatient JS caller.

After acquiring exclusive ownership at startup, finish verified old recovery
before publishing readiness or allowing new set. If the record is malformed,
unknown, or cannot be safely upgraded, reject admission instead of discarding it.
On confirmed shutdown clear, remove recovery registration and record under the
same lock. On partial clear, notification failure or timeout retain both. A killed
writer must be proven dead before any recovery writer is started.

Legacy RunOnce commands do not know this lock. Migration cannot assume deleting
their registry value cancels an already launched command. Formal enablement needs
a conservative migration gate; do not claim cross-generation protection merely
because new binaries serialize. User startup/autostart must remain safe when a
delayed legacy logon command is still possible.

## Required focused tests

- A enabled, admission of B fails before settings: A remains recoverable.
- A/B partial LAN/RAS mutation: both endpoints remain recoverable.
- Old recovery process starts before new owner, acquires lock after: it must not
  use a stale snapshot to clear the new owner's settings.
- New owner active with same endpoint: recovery cannot write or delete its record.
- Owner timeout with worker still alive: no second writer; release only on exit.
- Crash at each persistence/registration/mutation boundary: safe admission failure
  or recoverable state, never a falsely successful clear.
- Malformed record, different endpoint and legacy outstanding command: conservative
  refusal, without modifying another application's proxy.
- Update/uninstall: recovery path remains usable while a record exists; no deletion
  of the only recovery executable until cleanup is proven.

Do not add an administrator service, automatic helper restart or generic proxy
manager. Validate these transitions with fake persistence/operations first; local
real proxy writes remain prohibited while competing proxy programs are active.

## Implemented primitive (not yet wired into resident)

`apps/desktop/native/win/recovery-lock.h` opens the stable lock file with no
sharing, no inheritance and no retry loop. The owner must keep the handle until
all its possible writes have ended; an operation timeout alone is not permission
to close it. File deletion/replacement is denied while held. Final-component
reparse points/directories are rejected; the caller must select a trusted local
per-user directory, not a network share or attacker-controlled parent junction.

`recovery-lock_test.c`, included in `build-sysproxy.mjs --test`, uses only a private
temporary file. An exact child verifies contention; another acquires ownership
and terminates itself without cleanup, after which acquisition succeeds. Tests
also verify noninheritance and denial of deletion while held. An external test
rescue fails rather than being counted as ownership success. Filesystem syscall
latency is not a hard realtime bound. There is no production lock acquisition yet;
this alone does not fix the RunOnce race or protect against legacy helpers.

## Endpoint journal

`recovery-journal.h` uses that same exclusively held file as an append-only list
of at most eight distinct endpoints. Each versioned fixed-size UTF-16 record has
a checksum; admission reads/validates the entire file, appends only missing
endpoints and flushes before returning success. A proposed B never overwrites A.
The caller must still register a stable recovery command successfully before
touching proxy settings. Re-admitting an existing endpoint also flushes: a prior
flush error cannot silently become a successful mutation admission.

The only truncation API is explicitly named `reset_after_clear`; integration must
call it only after verified clear of the entire recorded set. Malformed, torn,
oversized, duplicate or unknown-version records refuse admission. This trades
availability for safety: corrupt records need conservative recovery/manual review,
not automatic reset. The checksum detects accidental damage, not malicious edits
by another process with the same user's filesystem privileges. Flush success is
an OS persistence acknowledgement, not a guarantee against all hardware faults.

`recovery-journal_test.c` exercises actual private temporary files, close/reopen
with A and B preserved, deduplication, capacity refusal, invalid endpoints, torn
and corrupted records, and verified-clear reset mechanics. It never invokes the
included shipping entry or WinINet/registry APIs. Not yet wired into resident;
RunOnce registration, migration and stable executable location remain required.

## Resident admission integration

The experimental `serve` entry now requires an absolute `--recovery` file and
holds its exclusive handle until process exit, including self-termination paths.
Its validated set hook appends/flushes the endpoint before WinINet admission.
Shutdown resets the journal only after clear succeeds; a reset failure also makes
shutdown unsuccessful. The fake backend uses exactly this hook and real private
file I/O, while still replacing all proxy operations.

Normal/late-set/diagnostic-stall cases verify an empty journal after clear. Both
hang cases verify a retained 608-byte record; an immediate new helper invocation
must reject readiness, exit 1, preserve identical bytes, and emit no fake Core
startup marker. The whole test remains inside the exact external Job; rescue fails.

Unresolved prior records currently reject startup before creating Core. This is a
temporary integration guard, not the final recovery behavior. Do not enable this
route in the app until bounded recovery replay, stable registration and legacy
migration are implemented. The existing one-shot RunOnce path is unchanged and
does not gain this lock simply because `serve` uses it.

## Bounded replay entry

`recover --recovery <absolute journal> [--log <absolute log>]` now reuses the
native window, worker, report and supervisor from `serve`, without starting Core
or an IPC reader. It takes exclusive ownership before reading endpoints and
immediately starts the same first-close budget. Only recorded endpoints reach
the existing clear/notOurs logic; no caller-supplied endpoint list or set is
accepted. Success clears the journal, uncertainty retains it. Recovery deliberately
passes `manage_recovery=0`, so it does not delete the legacy RunOnce registration.

Fake-backend evidence `out/resident-1793604030489/`: a live owner denies recovery;
after timed-out owner exit, recovery succeeds without Core; a hung recovery
self-terminates 42 with timedOut=true and identical retained record. Structured
recovery outcomes are preserved in the suite JSON. No external rescue or leftover
process is accepted. Shared native build and fake tests pass without proxy writes.

The budget begins after CLI validation/journal acquisition, not before process
creation or filesystem calls. This is a software shutdown/replay wait bound, not
a universal whole-process wall-clock guarantee. The standalone entry is not yet
registered with RunOnce or called automatically by the app. Stable deployment,
registration, legacy migration and true API replay evidence are still required.

## Recovery executable deployment

`prepareRecoveryHelper(source, directory)` publishes a content-addressed copy into
a caller-selected trusted per-user directory outside the versioned installation.
It writes and syncs a private temporary file, then creates a hard link to publish
complete bytes without replacing an existing version. Existing destinations must
match byte-for-byte; old versions are never removed here. Unsupported hard links
fail rather than falling back to unsafe replacement. The final directory and its
canonical path must not traverse links. This is not protection against a malicious
same-user process changing the directory concurrently.

Tests use inert text files, not executable launches: concurrent publication,
source deletion after deployment, retention across upgrades, tampered destination
refusal without overwriting, temporary cleanup, relative paths and linked-directory
refusal. Three targeted tests pass; typecheck and the preceding 175-test full run
also passed (the linked-directory test was added afterward).

This utility is not yet called from app startup. Keep deployment, journal path and
native registration consistent in the integration; do not point RunOnce back into
an uninstallable application version. No automatic garbage collection is permitted
until all pending recovery references and writers can be ruled out.

## Native registration integration

Resident set admission now appends/flushes the endpoint union, then successfully
registers `ClashKuroResidentCleanup`, then allows mutation. Resident requests no
longer write/delete the legacy single-endpoint registration. Successful shutdown
or replay resets the journal and deletes only the new value under exclusive
ownership; registration/deletion failure remains explicit failure.

The new command is `"<retained executable>" recover`. The executable infers the
adjacent `recovery.bin`; registration rejects any different supplied journal path.
Bare recover logs to `%APPDATA%\Clash Kuro\data\runonce.log`. This removes repeated
long paths from the 260-character RunOnce command while preserving diagnostics.
Explicit `recover --recovery ... [--log ...]` remains available for test/recovery
tools. The new command's length is checked before registry access.

Fake registry tests cover quoting, same-directory journal matching, denied key
creation/value writes/deletes and absent keys. Native fake-backend tests replace
registration too, never touching the real registry. The one-shot implementation
remains unchanged. These changes do not handle already-launched legacy cleanup;
migration gating and app deployment/routing remain mandatory before enablement.

## Session composition

`startResidentSession` now composes immutable helper publication, verified prior
recovery, then native `serve` startup. No session is returned if prior recovery
or startup is uncertain. The returned close operation closes admission immediately,
shares one promise/deadline across repeats, and requires final native evidence plus
actual exit. Its 2500 ms parent wait cannot turn a kill request into success; native
1500/2100/2200 budgets remain unchanged. Startup failures also close the exact child.

The normal native fixture runs this actual TS composition against the fake binary,
including publication to a separate retained directory, empty-journal replay,
fake set, repeated identical close promise, rejected late set and empty journal
after verified exit. `out/resident-1793605150682/normal/session-result.json` records
the result; the same external Job checks the complete added process tree.

The experimental Platform option now calls this composition and retains Core API
readiness and pipe rotation. App startup does not enable it yet: legacy migration
must be enforced before admitting a new owner. The helper handshake alone is not
Core readiness.

## Diagnostic evidence and migration probe

Shutdown reports carry UTC report time, helper PID, elapsed monotonic duration,
session message counters and a trigger bit mask: 1 internal failure, 2 IPC close,
4 reader ended (EOF or invalid input), 8 Core exit, 16 query-session-end,
32 session-end, 64 recovery replay. Multiple bits can be set; this is an observed
trigger set, not a total ordering or proof that every later message was received.
The counters are captured at report time. Reporting stays on its separate thread;
blocked logging cannot extend the supervisor deadline. Missing reports remain
unknown outcomes, never inferred success.

`node .scratch/mvp/prototypes/prestarted-helper-deadline/logon-probe.mjs` compiles
and runs a read-only token/LSA identity probe with a five-second process timeout.
It does not enumerate users, change proxy/registry state or trigger session events.
Local evidence `out/logon-probe-1793608070020/result.json` shows own authentication
LUID and logon creation time available, while a synthetic unallocated LUID returns
NTSTATUS 0xC000005F / Win32 1312. This establishes API availability only: it does
not prove old processes/queued legacy RunOnce commands cannot survive or race a
new owner, and is not sufficient by itself to authorize proxy writes.

The extended read-only probe also enumerates LSA sessions and emits counts only
(no account names or other users' identity records). Local evidence
`out/logon-probe-1793609544869/result.json` has 25 sessions, 14 readable same-user
records and 11 unclassifiable records. This rejects using a supposedly complete
ordinary-user logon inventory as an automatic migration barrier. Unclassifiable
is not absent, and granting elevation is not an acceptable workaround here.
