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
