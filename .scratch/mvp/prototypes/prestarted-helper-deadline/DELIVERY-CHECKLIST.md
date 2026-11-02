# Prestarted user helper: delivery, controlled migration and recovery

2026-11-02. Direction3 documentation and read-only constraint audit.

**Disposition: HOLD for migration delivery and user session testing.** This is an
experimental prestarted user helper, not an accepted final architecture. The
migration executor, trustworthy restart evidence and app handoff remain open.
The requirements below are not executable, verified migration instructions.

## Integration work after the initial audit

- The app now denies legacy startup before Platform creation when any
  `data/proxy-migration.json` exists. Empty/corrupt/non-file markers also deny.
  `--experimental-resident` is explicitly unavailable: there is still no positive
  admission path in this checkpoint, and no user setting can enable it.
- `collect-migration-evidence.ps1` is read-only and is packaged next to the helper.
  It gathers startup/checkpoint events, CIM boot time, identity, the old RunOnce
  value and known process names. This is evidence collection, not preparation,
  retirement, restoration or a guarantee against unknown/renamed writers.
- Windows CI now checks the packaged helper and collector against their build
  inputs, checks x64 GUI-subsystem PE metadata, and writes `build-identity.json`
  with the checked-out source commit/run ID/hashes. Both CI platforms explicitly
  check out the PR head rather than a synthetic merge commit. Still verify final
  run success and downloaded bytes; the stamp alone does not establish acceptance.

## Scope and evidence boundary

- This task writes only this file. No implementation, ADR, issue or CI changes;
  no commits. Main owns migration/native/app; the other agent owns Core integration.
- No local proxy, notification, RunOnce or restoration writes; no app activation,
  Core tests, generated session events, logoff, reboot or toolchain installation.
  No builds or tests were run for this audit. Repository reads and read-only GitHub
  run/artifact metadata queries were used.
- Committed inspection baseline: `ec8a813569d8f7f4e1fdaec6d5fce5378b50a847`.
  Main's identity work and the other agent's integration work were changing in
  parallel. References below describe the inspected source, not a final delivery
  commit. Recheck them against main's frozen delivery revision.
- The user has accepted one controlled migration with a user-performed restart
  and verification afterward. That does not authorize this agent to restart,
  activate the app or touch settings now. ADR-0011 stays unchanged, ADR-0013 stays
  draft, and this checklist does not change issue Status or authorize merging.

## Ordered constraint findings

These are delivery blockers or existing paths that must not be used as migration
instructions. They are separate from the acceptance checklist below. No fixes
were made.

### 1. [P1] Migration admission is a comment, not an enforced runtime boundary

**Where:** `apps/desktop/src/main/platform/index.ts:77`,
`apps/desktop/src/main/platform/index.ts:286`,
`apps/desktop/src/main/platform/resident-session.ts:7`,
`apps/desktop/src/main/platform/resident-session.ts:15`,
`apps/desktop/src/main/platform/migration-gate.ts:29`.

**Concrete case:** A caller supplies `startResident` before legacy migration.
Platform checks Windows/helper availability, then the session runs `recover`
before starting `serve`. The policy checker has no production caller here.
Recovery can clear a retained endpoint while an unlocked legacy writer is still
possible; a later legacy cleanup can also clear a newly enabled identical endpoint.
The new journal lock cannot serialize the old one-shot program.

**Required resolution:** Main must gate recovery as well as new admission using
fresh, validated migration evidence. Keep exclusive ownership through the checks,
prior recovery and handoff to the resident; releasing the lock between checking
and admitting invalidates the check. The current separate `recover` then `serve`
processes do not by themselves implement that migration handoff. Until then,
retain the app's disabled experimental route. No manual `migrated=true` override.

### 2. [P1] A consumed RunOnce invocation can fail without scheduling another recovery

**Where:** `apps/desktop/native/win/recovery-registration.h:21`,
`apps/desktop/native/win/recovery-registration.h:25`,
`apps/desktop/native/win/resident.h:302`,
`apps/desktop/native/win/resident.h:194`,
`apps/desktop/native/win/resident.h:250`.

**Concrete case:** Windows removes `ClashKuroResidentCleanup` before launching its
plain RunOnce command. Replay encounters a busy owner, clear/notification failure
or timeout. The journal survives, but these failure paths do not register another
attempt. If no app is subsequently opened, retained bytes alone do not cause
another logon recovery. Lock refusal is correct; claiming a retained scheduled
fallback would be incorrect.

**Required resolution:** Main must define and verify failure retention/retry for
the actual RunOnce lifecycle, including contention and process death. Preserve
the journal/helper and deny new writes meanwhile. Do not introduce an unbounded
retry loop or describe private-key registration tests as RunOnce scheduling tests.
The deletion-before-launch behavior is also documented in
`LOGON-IDENTITY-RESEARCH.md`, source [8].

### 3. [P1] The current app still reaches legacy write-before-registration behavior

**Where:** `apps/desktop/src/main/index.ts:50`,
`apps/desktop/src/main/index.ts:61`,
`apps/desktop/native/win/kuro-sysproxy.c:392`,
`apps/desktop/native/win/kuro-sysproxy.c:415`,
`apps/desktop/src/main/platform/system-proxy.ts:381`.

**Concrete case:** The normal app does not pass `startResident`; startup may
already invoke stale-proxy clear. A later one-shot set writes LAN/RAS before
RunOnce registration. A crash in that interval or a registration failure leaves
no reliable new fallback; the adapter warns rather than failing an otherwise
successful set. This is the existing legacy route, not a regression introduced
by this checklist.

**Required resolution:** Do not launch the current app as a migration preparation
tool or advertise its artifact as the resident candidate. Main must deliver an
explicitly gated migration/app path. Merely moving a single-endpoint registration
earlier is insufficient for an A-to-B endpoint change; preserve the endpoint union
as described in `RECOVERY-DESIGN.md`.

## Rejected restart identity and remaining collector work

**Class-90 BootIdentifier is rejected and must never authorize admission.** The
user reports research identifying it as the BCD OS loader identifier rather than
a unique identifier for each reboot; the returned GUID contained an old date.
The inspected, subsequently rejected work was at
`apps/desktop/native/win/migration-identity.h:7` and
`apps/desktop/src/main/platform/migration-identity.ts:13`. These references locate
the withdrawn attempt and may disappear when main removes/reworks it.

Strict struct/length/nonzero checks, a strict TS parser, a successful local build,
and passing parser/policy tests cannot repair the identifier's wrong meaning.
Failing closed on an unsupported internal ABI does not make a successful query
proof of a reboot. Earlier positive descriptions of this collector are superseded.

Main is investigating documented System log evidence from Kernel-General event
12 / Kernel-Boot event 27 with WMI `LastBootUpTime` and event continuity. That is
an investigation, not an approved collector or verified handoff. Do not accept
those event numbers or a changed timestamp alone. The eventual implementation
must establish the provider/schema meaning, continuity across the preparation
boundary, actual restart semantics on supported Windows 10/11, and rejection of
missing, cleared, inaccessible, conflicting or ambiguous evidence. No elevation
or silent timestamp/uptime fallback. Actual before/after restart comparison is
still user-only and unperformed here.

## What exists versus what remains blocked

| Area | Inspected implementation/evidence | Delivery limit |
| --- | --- | --- |
| Resident lifecycle | `resident.h` has a native window, independent reader/worker/supervisor, irreversible close gate and exact Core Job ownership. | Source inspection is not Windows session delivery/survival evidence. |
| Admission persistence | `resident_admit` appends/flushes endpoint union and registers new recovery before set. The journal handle remains exclusively held until process exit. | Applies to the new protocol only; no protection against legacy writers. |
| Prior replay | `recover` locks before reading; replay has no Core and no set interface. `recoverResident` requires a drained successful report and exit. | Not migration authorization; consumed RunOnce failure remains finding 2. |
| Retained executable | `prepareRecoveryHelper` publishes complete content-addressed bytes without replacing older copies. | Trusted local per-user directory required; no proof against malicious same-user changes. Do not garbage-collect referenced versions. |
| Platform seam | Experimental `startResident` option, API readiness check, pipe rotation, no one-shot proxy fallback in that option. | App does not enable it; admission/ownership handoff is unfinished. |
| Migration policy | Pure `checkMigrationEvidence` validates supplied fields and rejects failure/unknown states. | It neither collects trustworthy evidence nor holds native ownership. Distinct opaque boot strings are not proof. |
| Migration executor | No completed preparation/post-restart executor or validated app handoff in the inspected route. | No runnable migration procedure can be issued yet. |
| Core and real API evidence | Existing coordination tests are fake; Platform fixture uses real Core/fake proxy; isolated WinINet fixture uses real API/fake Core/private registration key. | These cannot be combined into real app/session acceptance. Core reruns belong to the other agent. |

## Same-final-commit CI and artifact identity

Read-only GitHub metadata checked on 2026-11-02 around 20:10 +08:00:
[CI 41440458431](https://github.com/coderhyy/clash-kuro/actions/runs/41440458431)
completed successfully for the full baseline SHA above; both Windows and macOS
jobs succeeded. These artifacts were listed as unexpired:

| Artifact name | GitHub archive digest (`sha256`) |
| --- | --- |
| `kuro-windows-x64` | `845077d865b4d743519a0edc2f2fa9173f1f739d9dbb5954573cb9fc5ae0c39f` |
| `kuro-helper-coordination-evidence` | `251c0dc6be341ef1c51c378ee997bb6d209b4cd82acd44ae3f91bc6b89c0b9fc` |
| `kuro-wininet-recovery-evidence` | `60694c185742d39da8f7f45ad88879119d6a7149a65738a8f1caade27a11c107` |

**Metadata only:** this task did not download, hash, unpack or execute these
artifacts or inspect their enclosed result files. This run predates the current
collector/executor/app work and cannot validate the final delivery. Archive
digests are not helper executable digests. No final run or extraction path is
assigned by this document.

- [ ] Main records the final full commit SHA, clean delivery source state, CI run
  URL/ID/attempt and each required job result. Both required CI jobs and all
  delivery evidence must correspond to that exact revision. Later tracked changes
  require fresh evidence; no mixing an older binary with a newer green run.
- [ ] Record artifact names, IDs, archive digests and actual download/extraction
  locations from that run. Verify downloaded contents, then record extracted app,
  helper, Core and relevant resource hashes. Never reuse a previously downloaded
  helper simply because its filename/version matches.
- [ ] Inspect enclosed coordination, resident, Platform and real-API result files;
  require no rescue/remaining processes for accepted cases. Deliberate rescue
  controls must remain failures with the expected negative-control evidence.
- [ ] Confirm all required evidence files are actually present. The current helper
  artifact uploader uses `if-no-files-found: warn`; its `out/resident-*` pattern
  covers both native resident and `resident-platform-*` output. Inspect the actual
  enclosed Platform result and log rather than inferring their presence or
  acceptance from a green workflow/upload.
- [ ] Resolve or explicitly retain as a blocker the reported Core integration
  failures; use the other agent's final same-revision evidence. This task neither
  reruns Core tests nor declares intermittent failures fixed by an unrelated pass.

## Required resources and paths

These are package-relative expectations derived from `electron-builder.yml:9`,
`electron-builder.yml:32`, `scripts/fetch-core.mjs` and `main/index.ts:40`, not
claims about an already inspected final artifact.

| Required item | Verification before delivery |
| --- | --- |
| Entire `kuro-windows-x64` unpacked application | Keep the complete Electron distribution and bundled app code; discover the actual app executable from the artifact. Do not deliver only a helper EXE. |
| `resources/bin/kuro-sysproxy.exe` | Final x64 GUI helper, built from the delivery revision, with `asInvoker` manifest; hash actual bytes and confirm no extra runtime DLL/toolchain install is needed. |
| `resources/core/mihomo.exe` | Pinned Core from `core.lock.json`; record the extracted executable hash separately from the lock's compressed archive hash. |
| `resources/core/core.lock.json` | Match the delivery revision's lock and retain pinned version/source/hash identity. |
| `resources/core/geo/Country.mmdb`, `GeoSite.dat`, `ASN.mmdb`, `VERSION` | Match the lock and Geo commit; available before app/Runtime Config startup. |
| `resources/licenses/mihomo-LICENSE.txt` | Present with pinned Core licensing material. |
| Retained recovery helper and adjacent `recovery.bin` | Selected trusted, local, per-user location outside a replaceable app version. Current composition selects `<dataDir>/proxy-recovery`; actual canonical path/hash must be recorded by main. Not a promised final absolute path. |
| Migration backup and evidence | Durable user-private location outside the repository and replaceable installation; main must specify the real path/schema, digest and recovery reader. Existing experiment backups are not automatically migration backups. |
| Diagnostic evidence | Record actual paths used for exit/recovery/helper/session evidence. Bare `recover` currently derives `%APPDATA%\Clash Kuro\data\runonce.log`; verify that against delivered app identity and custom data paths. |

- [ ] Retained directory, executable and journal paths pass the existing absolute,
  canonical/non-link/local-directory checks. Directory policy must also exclude
  network/shared or untrusted locations; the native lock checks the final file,
  not every parent directory.
- [ ] Registration's quoted executable and adjacent journal resolve to the same
  retained deployment; command length is accepted. Preserve all versions still
  referenced by pending recovery. Update/uninstall must not remove the only
  usable recovery executable, journal or backup.

## Controlled migration: before the user's restart

**IMPLEMENTATION REQUIRED. Do not execute these as current instructions.** The
preparation stage must be safe even if the user postpones or cancels the restart.
A later restart cannot justify risking a live-writer restore or destroying
recovery evidence beforehand.

- [ ] Keep resident replay, new proxy set, app startup/autostart and automatic
  restart paths closed. Merely launching the current app is unsafe preparation
  because it performs stale-proxy cleanup (finding 3).
- [ ] Establish the current user's identity, complete LAN/RAS inventory, every
  potentially owned old/proposed endpoint, both recovery registrations and actual
  helper/app locations. Missing or uninspectable state blocks mutation.
- [ ] Stop legacy/new app entry points and establish exit of every relevant
  set/clear/recovery writer and its descendants using reliable retained ownership
  evidence. A process-name list, parent exit or a requested kill is insufficient.
  Suppress old autostart/relaunch sources throughout the migration window.
- [ ] Before any destructive step, persist and verify a complete backup: LAN and
  all RAS flags, server, bypass, PAC URL, connection identity, recovery/journal
  state, exact old registration command/type, retained helpers, source revision,
  user identity and the eventual supported restart-preparation evidence. Verify
  integrity and readability; do not back up only LAN or `ProxyEnable`.
- [ ] Main's executor must acquire exclusive recovery ownership and perform any
  authorized old-owned cleanup only after proving no live/possible conflicting
  writer can race it. Query/read back every connection and notification result;
  preserve unrelated settings/endpoints. Never erase ownership records merely to
  make migration appear ready.
- [ ] Retire only the legacy `ClashKuroSysProxyCleanup` entry after preserving its
  exact contents and verifying cleanup/quiescence. Deleting it cannot cancel a
  command already selected/launched by Windows. If that uncertainty remains,
  no concurrent recovery/restore or new owner is permitted; main must provide a
  conservative, explicitly supported preparation path rather than a fixed wait.
- [ ] A prepared result must attest that no newly stranded proxy was created,
  old-owned active settings were safely cleared/verified, unrelated state is
  preserved, backup/helper remain usable, and all new admission remains closed.
  If any part is unproven, retain evidence, report incomplete and do not label the
  machine ready to restart as a cure. Post-restart-only work must be identified
  explicitly, never smuggled into a completed pre-restart result.
- [ ] Capture the immutable preparation record only after successful preparation.
  Re-entry, failed backup/registration/cleanup, interrupted preparation and user
  cancellation must deny admission. Do not ask the user to enter opaque evidence
  fields or edit a prepared/migrated marker.

The existing `wininet-recovery/run.mjs` is a guarded experiment, not this executor.
Its default mode creates a backup without proxy mutation; `--exercise`,
`--resident=...` with exercise, and `--restore=...` can write real settings.
The restore path expects that fixture's endpoint/state rules and never restores
RunOnce. Do not repurpose it as general migration recovery or run it in this task.

## User restart and post-restart admission gate

**BLOCKED pending main's executor, replacement collector and app handoff.**

1. The human performs the agreed Windows restart only after a verified prepared
   result and usable recovery instructions have been delivered. The agent never
   initiates it. Logoff/login, Explorer restart, lock/unlock, RDP disconnect, Fast
   User Switching, sleep/hibernate, or shutdown/power-on with uncertain Fast
   Startup semantics are not accepted substitutes.
2. Before launching a conflicting app/writer, collect fresh supported evidence
   tying this user and actual restart to the preparation record. Class-90
   BootIdentifier, an LSA LUID, a changed wall clock, WMI time alone, an absent
   registry value, elapsed seconds or a user-entered boolean are insufficient.
   Denied/unknown/incomplete event continuity must block, not request elevation.
3. Verify backup, helper and delivery revision/digests still match; legacy
   registration is retired; legacy writers/relaunch sources are absent; relevant
   settings and endpoint inventory are still attributable to this preparation.
   A changed helper/backup or old-version launch requires safe re-preparation.
4. Acquire the same exclusive user-scoped recovery ownership before reading
   current journal/registration state. Validate/recover prior records under that
   ownership. No stale snapshot from before lock acquisition; no forced lock
   deletion. Malformed, torn, unknown-version or oversized records block.
5. Require verified replay success and actual process exit, then transfer ownership
   to the new resident without a gap that invalidates admission. The final
   implementation must show how this works across its actual process boundaries.
   Recovery timeout/kill request, missing report or failed registration keeps new
   Core/proxy admission closed.
6. Only then admit the resident. Before each mutation, persist/flush the old and
   proposed endpoint union and register the retained recovery executable. Verify
   actual Core API readiness separately from helper readiness. No one-shot
   fallback, automatic helper restart, legacy parallel write or downgrade writer.

No migration script name, switch, activation setting or final artifact path is
invented here. Main must replace the blocked stages with the delivered executor's
actual commands/UI, required inputs, expected output, failure exit semantics and
verified paths before asking the user to run them.

## Required denial cases

All denied cases must leave admission closed and preserve diagnostic/recovery
evidence. Use fake operations/private files for implementation tests first.

| Case | Required result |
| --- | --- |
| Preparation incomplete, absent or edited; same boot or unsupported/ambiguous restart evidence | No replay/new writer admission. Class-90 identity never passes. |
| User mismatch, helper/backup digest mismatch, missing retained executable or changed delivery revision | Block; do not silently trust a new path or rewrite old evidence. |
| Legacy registration/process/relaunch possibility present or unknown | Block; absent RunOnce is not completion. No fixed-delay or LSA-enumeration shortcut. |
| Ownership busy; old native call timed out but process still alive | No new writer, restore or lock deletion. Timeout is not cancellation. |
| Admission of endpoint B fails while A exists | No B mutation; A and its usable recovery evidence remain intact. |
| LAN/RAS partial set, query/enumeration/notification error, policy override | No clean success; retain all potentially affected endpoints and recovery. |
| Corrupt/torn/duplicate/unknown journal or endpoint capacity exceeded | Refuse admission; no automatic truncation/reset. |
| Delayed old replay before/after a new same-endpoint owner | Exclusive current-state checks; no clearing/deleting the live owner's state. Legacy replay requires the separate migration barrier. |
| Unrelated proxy endpoint, PAC/bypass drift, connection-list change or another proxy program | No broad clear/restore; preserve foreign state and report the mismatch. |
| Crash at persistence/registration/mutation/handoff boundaries; failed/consumed RunOnce replay | Recoverable retained state or safe refusal, never falsely prepared/clean. Verify actual scheduling separately. |
| Shutdown repeat, late set/reply, invalid IPC or log backpressure | Same original close/deadline; no reopened admission or renewed wait budget. |
| Upgrade/uninstall/downgrade with pending journal/registration or unknown writers | Retain needed recovery bytes; refuse conflicting legacy/downgrade writes. |

## Recovery without racing a live writer

**Requirements for main's delivered recovery procedure, not commands to run now.**

1. Close admission and record the failure, exact session/process ownership and
   backup/helper identity. Preserve the journal, registrations and all referenced
   executable versions. Do not auto-restart the helper or retry with a new budget.
2. Confirm the exact old writer and all descendants have exited before starting
   another mutating process. A timeout, pipe EOF, PID disappearance, parent exit,
   kill return value, missing diagnostic file or stale lockfile timestamp is not
   sufficient. With unknown ownership, stop and retain evidence.
3. Acquire the same native exclusive journal lock; read and validate the current
   record after acquisition. A busy lock refuses recovery. Do not remove, replace
   or truncate the lock/journal to bypass contention. A retained experiment
   `writer.lock` also must not be removed merely because its Node controller died.
4. Prefer owned-endpoint replay through the retained helper. Replay must not start
   Core or accept a caller-invented endpoint list. Require actual exit code 0,
   no signal, a valid drained shutdown report with `ok=true`, `timedOut=false`,
   `coreGone=true`, `corePid=0`, and verified final recovery state. Keep new
   admission closed on any uncertainty, even if a termination request was sent.
5. If full backup restoration is necessary, first prove writer quiescence and
   validate the same user, backup integrity, full connection inventory and current
   state against the exact allowed saved/owned transitions. Hold exclusive
   ownership for all writes, notifications and final readback. Do not overwrite
   foreign endpoint/PAC/bypass changes or import a broad registry export blindly.
6. In isolated fixtures, the external writer Job must be positively empty before
   restoration; a rescued experiment is still failed acceptance. Safe restoration
   after confirmed rescue does not turn the experiment green. On the user's
   machine, main must deliver equivalent reliable ownership/exit evidence rather
   than assume the test watchdog exists in the shipped app.
7. Clear ownership records/registration only after complete, verified cleanup
   under ownership. A partial clear, failed notification, unknown exit or failed
   restoration retains recovery and blocks new writes. Release ownership only
   when no writer can still run; verify post-recovery state before reopening.

If no safe automated recovery exists, stop at read-only evidence collection and
deliver specific human recovery instructions from main. Do not ask the human to
edit settings while an old writer may still run.

## Actual session tests: human only, after delivery gates pass

There is no session-testing authorization to execute in this audit. No remaining
5+5 repetition quota is implied by historical issue notes. Deliver one bounded
initial user case per agreed session operation; expand only for evidence needs.

- [ ] Freeze the final app/helper/CI identity and completed migration/recovery
  procedure. Record Windows edition/build, user, console/RDP context, app window
  or Tray Mode, active endpoint, full LAN/RAS baseline and competing-writer
  absence. RAS absence must be recorded as a coverage gap.
- [ ] The human launches only the verified candidate after post-restart admission.
  Confirm native owner readiness, actual Core readiness, successful set/readback,
  durable recovery registration and retained helper/journal paths before the
  human initiates the agreed logoff or restart/shutdown case.
- [ ] The human performs the actual session operation. No agent-generated
  `WM_QUERYENDSESSION`/`WM_ENDSESSION`, `shutdown.exe`, app activation or automated
  reboot. Private WM_APP/IPC triggers are coordination evidence only.
- [ ] After next login, collect before launching another proxy writer: final
  helper/exit/recovery reports, UTC/PID, `triggerMask`, `queryEvents`, `endEvents`,
  `sessionFlags`, native elapsed duration, Core/process exit evidence and full
  per-connection state. Missing reports remain unknown. Query count >0 shows an
  observed event, not sufficient proof of successful cleanup.
- [ ] Distinguish pre-session clear, later RunOnce recovery, timeout/self-termination,
  forced Core termination and external rescue. RunOnce success after login is
  recovery evidence, not successful pre-logoff cleanup. Nonzero/unknown outcomes
  fail cleanup acceptance even if settings are subsequently restored.
- [ ] Preserve the first failed case and stop for safe recovery/diagnosis before
  repetitions. Do not renew deadlines, waive missing evidence or label the whole
  fixture successful because the helper eventually disappeared.

Native source currently budgets clear through first-close +1500 ms, Core Job
confirmation/diagnostic drain through +2100 ms and report/exit supervision through
+2200 ms; the JS session close uses a 2500 ms parent wait. These are software wait
policies, not universal wall-clock guarantees for loader, filesystem, kernel or
message dispatch. A 0-ms/coarse-tick observation is not instantaneous cleanup.

## Completion record for main

- [ ] Findings 1-3 are resolved or remain explicit delivery blockers; final
  Platform artifact evidence is verified, and rejected class-90 evidence is
  absent from admission and instructions.
- [ ] Preparation is safe before a restart, replacement restart evidence fails
  closed, and post-restart ownership/replay/app handoff is implemented and checked.
- [ ] Final same-commit CI, downloaded resources and evidence identities are filled
  with actual values; no claimed final paths or commands remain hypothetical.
- [ ] User receives the actual before/after/deny/recovery instructions and the
  limited evidence claims before any manual session operation.

Not checked here: builds/tests, downloaded artifact contents, actual restart
comparison, live proxy/RunOnce behavior, Windows 10/11 session survival and RAS
reliability. Until main closes the gates, this document is a bounded delivery
report and checklist, not permission to activate or a verified migration runbook.
