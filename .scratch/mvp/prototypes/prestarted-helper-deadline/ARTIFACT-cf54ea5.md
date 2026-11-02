# Intermediate Windows artifact assessment: cf54ea5

Date: 2026-11-02. **Disposition: HOLD. Intermediate evidence only; NOT a final
delivery or manual/session-test candidate.** Successful CI and verified artifact
identity do not close migration, ownership, restart or rollback gates.

## Scope and immutable baseline

- Assessed commit: `cf54ea512b619436ea9d255d90db93e2719c1e30`.
- This task writes only this assessment and ignored evidence under
  `D:\clash-kuro\out\artifact-cf54ea5-41469260599`.
- Source reads are pinned to the commit using `git show`/`git grep`, with exact
  Git blobs retained under `source-cf54ea5/` in that evidence directory. Known
  coordinated migration-gate, resident-owner and build-script work after this
  revision is excluded from the assessment and is not covered by this run.
- No downloaded executable, packaged app, collector, Core or experiment was run
  locally. No System Proxy, notification, RunOnce, Core/session or migration-state
  changes; no builds, application tests, commits or pushes. Verification consists
  of downloads, hashes, static parsing and reading the existing CI results.
- The existing `DELIVERY-CHECKLIST.md` is unchanged. Its committed snapshot is
  reviewed below; this report does not check off its gates or supply ready-to-run
  user instructions.

## CI and downloaded archive identity

[CI run 41469260599](https://github.com/coderhyy/clash-kuro/actions/runs/41469260599),
attempt **1**, event `pull_request`, branch `codex/08-windows-sysproxy`, reports
`head_sha=cf54ea512b619436ea9d255d90db93e2719c1e30`, `completed/success`.
Created `2026-11-02T15:12:13Z`; final run update `2026-11-02T15:15:58Z`.

| Required job | Result | Job ID |
| --- | --- | --- |
| Windows | completed/success | `125358201833` |
| macOS | completed/success | `125358202145` |

All three downloaded archives below were unexpired when queried. Their artifact
metadata independently identifies the same run and full head SHA. Local archive
SHA-256 values equal the API `digest` values, with matching byte lengths.

| Artifact | Artifact ID | Archive bytes | Verified archive SHA-256 |
| --- | --- | --- | --- |
| `kuro-windows-x64` | `13153089998` | 194859504 | `0ee21795703b0f86cd0fb040c6ffd00d93b55d3ebcfed10e6582d0fb15194de0` |
| `kuro-helper-coordination-evidence` | `13153757984` | 22419 | `86375b64cd4e3e5a2572e9c39d42aa5552309fd45f038bf37b5b9c2431346c6e` |
| `kuro-wininet-recovery-evidence` | `13154852648` | 2773 | `71465958b307058ced924484bb789c65bb818758ee70e0530c5e79e91e03ac4b` |

Actual archive paths are
`D:\clash-kuro\out\artifact-cf54ea5-41469260599\<artifact-name>.zip`;
each is extracted into the adjacent directory with the exact artifact name.
These are inspection locations, not installation, retained-recovery or migration
backup locations. The macOS archive was not downloaded or inspected.

The enclosed `kuro-windows-x64\build-identity.json` records the full assessed SHA,
run ID `41469260599`, `residentEnabledByDefault=false`, and helper/collector
hashes that match the actual extracted bytes. The pinned workflow explicitly
checks out the PR head and compares packaged helper/collector hashes with the
runner's built helper and collector input before writing this stamp.

This establishes consistent run/package identity within the CI trust boundary.
It is not a signed provenance attestation or an independent reproducible build.

## Extracted package, helper and collector

The package contains the full unpacked Electron distribution, actual entry point
`Clash Kuro.exe`, `resources/app.asar`, helper and collector, pinned Core and lock,
all three Geo resources plus `VERSION`, and the mihomo license. Package metadata
is `@kuro/desktop`, version `0.1.0`, main entry `out/main/index.js`.

The following are extracted-file hashes, distinct from archive hashes:

| Path relative to `kuro-windows-x64` | Bytes | SHA-256 |
| --- | --- | --- |
| `build-identity.json` | 310 | `06c24439a3cde49ff3a7d0c90ff6c2ce0a2bf7c941447b529bfb5d3b656eb41a` |
| `Clash Kuro.exe` | 249798656 | `c0c68f59b600157b590838e80d884235aea6373233da36f7ad08c20defdec1f2` |
| `resources/app.asar` | 1151083 | `ebcd282f2b36e9bae86af571f4d093b23209239e6410c52ae0c3d9847f3b2941` |
| `resources/bin/kuro-sysproxy.exe` | 43520 | `2e57dc1df3a36a54c5661ef2c090d8175573dbdc563ae1648de16d09a94b138e` |
| `resources/bin/collect-migration-evidence.ps1` | 4306 | `46ea99e744ebaf72244b24034d10b8f8f3899e67bc6a1ff0128b51df5aa9157e` |
| `resources/core/mihomo.exe` | 61304320 | `a4fbf2b8bc2b5416ce2d0d392ac59f2e0a234ea4fcf635b66bd21e62ea9641b9` |
| `resources/core/core.lock.json` | 2143 | `742cb3bd030030ba9d9a714dc9e2dca7fec20ff44a97847eaccc103224d81266` |
| `resources/core/geo/Country.mmdb` | 7651117 | `9a485c40b6fda868f3d3b981f928b8ab3d1e400fac1bf9cc8d27ebc08ae9bb0b` |
| `resources/core/geo/GeoSite.dat` | 4353587 | `b4d3807aa45b4f5532ae236672f244a562452622483c0b489c63dd2aadaa821f` |
| `resources/core/geo/ASN.mmdb` | 9000080 | `3169b9ea7dad762f6837b95408dadc1173f47be33be2d83b6c90e67a57a7eb2e` |
| `resources/core/geo/VERSION` | 40 | `f2b19dde321d63fa2215b6531dfaaccb2eee76ea0df48f7cd954fbbfd8bd4101` |
| `resources/licenses/mihomo-LICENSE.txt` | 35149 | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |

`file-hashes.json` retains all **128** extracted package/evidence file identities.

### Helper PE and runtime dependencies

Static `llvm-readobj` inspection and independent header assertions agree:

- Valid `MZ`/`PE` signatures; machine `0x8664` AMD64; optional header `0x20b`
  PE32+; subsystem `2` Windows GUI.
- Embedded RT_MANIFEST resource ID 1, language 1033, requests
  `level="asInvoker" uiAccess="false"`. Manifest text matches the assessed source
  after checkout line-ending normalization. The declared compatibility GUID is
  the Windows 10 compatibility identifier; that is not Windows 10/11 session
  acceptance evidence.
- Certificate table is empty: this helper is unsigned, consistent with the MVP
  packaging policy. No privilege/elevation requirement is introduced by its
  manifest.
- Imports: `ADVAPI32.dll`, `KERNEL32.dll`, `RASAPI32.dll`, `USER32.dll`,
  `WININET.dll`, and UCRT API sets for environment, heap, locale, math, private,
  runtime, stdio and string. No imported libgcc/libwinpthread/MinGW support DLL
  is present. This is static dependency evidence, not a loader test across every
  supported Windows build.

The collector is a PowerShell script, **not a PE executable**. Its static
PowerShell parse reports zero syntax errors; the script was not executed.
Its raw packaged hash matches the stamp. Compared with the pinned Git blob
(`735dd0df7d5b1e36b2addf2407edc81d7af3ef13467b7bbcc17a7251a2192ecb`),
the bytes differ only by exact LF-to-CRLF Windows checkout conversion. The
packaged Core lock has the same checkout-only distinction; no content difference
was accepted by normalization beyond that conversion.

The collector reads account/install identity, native uint64 uptime, System
events/checkpoint, CIM boot time, both recovery registrations and a conservative
known-process screen. It does not prepare migration, retire registration,
restore settings, prove writer exclusion or authorize admission.

ASAR metadata and the main entry were read as data, with the entry's embedded
SHA-256 checked. The packaged main contains the migration marker guard and the
explicit unavailable-resident error. Pinned source confirms the guard precedes
Platform creation; no-marker startup still takes the legacy route. Presence of
the helper and collector therefore does not make this a resident-enabled app.

For Core identity only, the pinned upstream v1.19.33 Windows ZIP was separately
downloaded and hashed:
`fb0b960eff568459502d4ebe53e9cca203053d86ec9024fe935f19615d74d9aa`,
matching the lock. Its `mihomo-windows-amd64-v1.exe` entry hashes identically to
the packaged `mihomo.exe`. Geo hashes and license match the lock; `VERSION`
contains Geo commit `10f120b9f0cd1bcae8b8ff88b3f999237b919702`.
No Core process or integration test was started locally.

## Enclosed CI evidence and its limits

| Evidence actually inspected | Concrete result | Acceptance limit |
| --- | --- | --- |
| `runs/1793632465396/results.json` | 18/18 fixture cases pass; `accepted=true`; every supervisor has `watchdogKilled=false`, `lingeringChildren=false`, `remaining=0`. | Includes intentional timeout/error outcomes; passing the fixture does not mean every cleanup succeeded. Fake operations. |
| `runs/1793632505640-negative/results.json` | Both rescue controls have `pass=false`, `accepted=false`, `negativeControlsObserved=true`, `watchdogKilled=true`; eventual `remaining=0`. | Correct negative-control failures remain failures, including the case where helper cleanup preceded rescue of its hung carrier. |
| `resident-1793632488975/results.json` and adjacent case evidence | Eight native scenarios. Normal, late-set and diagnostics-stall exit 0. Clear-hang, set-hang, replay-registration, register-hang and late-clear exit 42 as expected. All supervisors show no rescue/lingering children and zero remaining. | Compile-time fake operations/registration; validates coordination, denial and recovery behavior, not live user settings or sessions. |
| `resident-platform-1793632502083/result.json`, `supervisor.json`, `test.log` | Actual result and log are present. Real Core/Platform integration test passes; root exit 0, no rescue/lingering children, zero remaining. | Real bundled Core with fake proxy/recovery registration; private close path, no OS session. |
| All five `verified*.json` in `kuro-wininet-recovery-evidence` | Each reports `restoredAndVerified=true`, `runOnceUnchanged=true`, one connection, flags 3 to 1. Recover reports successful Core-free shutdown; serve reports successful shutdown and private registration verification. | Real WinINet on an isolated runner, single connection, test executables with fake/no Core or substituted registration. No real RunOnce scheduling, RAS sample or OS session. |

In the late-clear case, `cleanupDurationMs=1609`, `ok=false`, `timedOut=true`,
exit 42. It is not relabeled successful because cleanup eventually returned.
Follow-up recovery evidence does not erase the original timeout.

The Platform test log is specifically the bundled mihomo integration test,
executed through the pinned `platform-test.mjs` with `KURO_RESIDENT_FAKE`.
Its source exercises the resident Platform seam, real API/streams and channel
rotation. It is not a production app-launch or migration-handoff result.

The CI Windows desktop suite reports **26 files passed, 334 tests passed,
1 skipped**. The skipped test is the opt-in actual read-only boot collector
comparison; the Windows test step does not set its opt-in variable. Parser/mock
tests and 85 preparation tests are useful but do not supply an actual
before/after-restart result. No local test rerun was performed here.

The real-API artifact contains the five verified summaries, not the underlying
runner backup files or individual supervisor reports. Pinned fixture code checks
writer Job emptiness before restoration and rejects rescued cycles; the run
logs record restored-state verification. Those claims cannot be expanded into a
locally inspected complete raw trace or a migration rollback backup.

## Delivery checklist review

### Reboot purpose and updated evidence boundary

The checklist correctly treats a controlled human Restart as a migration barrier
against old one-shot writers and already-selected RunOnce commands that do not
participate in the new native journal lock. Absence of a registration or a
process-name snapshot cannot establish that such work is finished. Restart is
not a cure for incomplete preparation, lost backup or an unsafe live restore,
and is not itself evidence of pre-logoff cleanup reliability.

Its blanket description of the replacement collector as still under
investigation is historical at this commit. `migration-boot.ts:69` now implements
a bounded v2 comparison: fresh unsigned uint64 uptime must strictly decrease
against the completed preparation receipt's **after** sample; machine digest and
SID must match; the saved System checkpoint/digest must survive; corroborating
kernel/boot records must be newer. Equality or greater uptime denies even after
a genuine Restart. Long delay after Restart is an accepted false negative; no
wall-clock, BootType, boolean or timestamp fallback is justified.

The bounded comparison still requires separately recorded controlled human
Restart attestation and trusted fresh collection/receipt provenance. It is not
an authenticated physical-machine identity or a production admission decision.
Cloned/rolled-back VM state and same-user tampering remain trust limits. Class-90
BootIdentifier remains rejected; no such implementation reference was found in
the assessed desktop source. The comparison was not exercised across an actual
Restart in this task or demonstrated by these CI artifacts.

### Pre/post conditions remain delivery requirements, not user steps

| Stage | Required safety property | State at cf54ea5 |
| --- | --- | --- |
| Before preparation | Admission/relaunch closed; actual user and full LAN/RAS/endpoint/registration inventory; reliable exclusion of old writers and descendants. | Marker startup denial exists, but process-name screening and absent values are not writer exclusion. No delivered coordinator supplies the caller-owned exclusion prerequisite. |
| Durable preparation | Verified complete backup outside replaceable app/data locations; retained helper identity; only owned settings cleared/read back; exact legacy registration preserved before retirement. Preparation must remain safe if Restart is postponed. | `prepareProxyMigration` and `readPreparedMigration` now exist, with durable markers, helper copies, snapshots, registry export, hashes and checked receipts. They are unconnected internal building blocks, not a delivered executor. |
| Preparation boundary | Publish prepared only after verified cleanup/retirement and final evidence; interrupted, corrupt or mismatched state keeps admission closed. | Helper APIs check and retain evidence, but their caller must establish exclusion. A broad registry export is backup evidence, not a safe restore mechanism. No actual machine preparation was verified. |
| After Restart | Fresh same-user/install evidence tied to receipt.after; validated backup/helper/revision; legacy registration/writer/relaunch absence; no uncertain identity or continuity fallback. | Pure comparison and receipt rehashing exist. No non-test caller wires these to production replay/admission, and no real Restart pair is enclosed. |
| Prior replay and handoff | Acquire current native ownership before reading/replay; hold it through verified recovery and resident handoff; no gap admitting another writer. Require actual process exit and successful drained report. | `resident-session.ts:15` runs recover separately, then spawns serve. The migration/ownership handoff remains incomplete in this revision. |
| Manual session acceptance | Frozen final app/helper/CI, actual Core readiness, settings readback, retained recovery paths, then bounded human-only session cases and post-login evidence. | Not reached. These artifacts use private/fake/test combinations; no Windows 10/11 user session or RAS acceptance is established. |

The checklist's statement that no preparation executor exists needs this narrow
qualification: preparation and receipt-validation APIs have been added. That
does not close the missing caller/coordinator, exclusion, post-restart handoff or
rollback work. The checklist's HOLD remains correct.

## Concrete blockers carried forward

1. **No final candidate identity.** This run covers only cf54ea5, not the expected
   parallel migration-gate/resident-owner/build work or later integration. Final
   same-revision CI and freshly inspected downloads remain outstanding.
2. **No enforced migration coordinator or ownership handoff at this revision.**
   `migration-preparation.ts:148` explicitly leaves writer exclusion to its
   caller. Pinned non-test call-site search finds no production caller of
   preparation, restart verification or migration admission policy. Separate
   recover/serve processes leave an ownership boundary that needs implementation
   and evidence. A name screen cannot authorize a pre-restart clear/restore.
3. **The app cannot admit the new resident.** `migration-startup.ts:9` rejects
   `--experimental-resident`; any migration marker blocks legacy startup. With no
   marker, main still constructs the legacy Platform and reaches stale cleanup
   (`main/index.ts:68`). Legacy native set still writes settings before old
   RunOnce registration (`kuro-sysproxy.c:392`, `kuro-sysproxy.c:415`). Launching
   this app is not migration preparation or resident acceptance.
4. **Restart evidence is bounded and not operationally connected.** The v2 reset
   witness is implemented, but the actual collector test was skipped in this
   Windows run, no trusted real pre/post Restart pair is enclosed, and no
   coordinator binds receipt.after, fresh evidence and manual Restart attestation
   to native ownership. Distinct opaque policy boot strings are insufficient.
5. **Failed consumed RunOnce replay is not a scheduled retry guarantee.**
   `recovery-registration.h:21` registers a plain value; `resident.h:194`
   explicitly retains a failed replay journal for app/manual recovery and does
   not self-register. Preserving bytes alone cannot guarantee another login
   invocation. Delivered failure/recovery behavior must account for this; the
   private-key fixtures do not test Windows scheduling.
6. **No delivered safe rollback or actual session acceptance.** Complete trusted
   paths, ownership/exit checks, allowed restoration transitions and failure
   outputs are not supplied as an executable migration recovery procedure. Real
   Core/fake proxy and real WinINet/fake Core cannot be combined into real
   app/session acceptance. Actual human session results and RAS coverage remain
   absent.

These blockers apply to the pinned intermediate revision. They do not assess or
reject coordinated changes being developed afterward.

## Safe rollback assessment

The existing checklist correctly puts writer quiescence and exclusive ownership
before any recovery or restore. A timeout, kill request, vanished parent/PID,
pipe EOF or absent RunOnce value is not completion evidence. No recovery may
bypass contention by deleting a lock, journal or migration marker.

The required delivery behavior remains: preserve backup, registrations, journal
and every referenced helper version; validate user, helper/backup digests and
complete current LAN/RAS state; obtain the same exclusive ownership; prefer
owned-endpoint replay; verify actual exit and final state; keep admission closed
on error or uncertainty. Full restoration additionally needs a validated mapping
of saved/owned transitions that preserves unrelated endpoint, PAC and bypass
changes. Cleanup/registration records can be removed only after verified cleanup.

The experiment's `wininet-recovery/run.mjs` restore path is not general migration
rollback: it operates under fixture endpoint/snapshot guards and does not restore
RunOnce. Runner backup paths in `verified*.json` are neither local backups nor
delivered user recovery resources. Blind registry import, reinstall/downgrade,
deleting the marker or starting an older writer would not establish safe rollback.

No current rollback command or user Restart/session instruction is approved or
presented as ready by this report. The hold applies until the owning integration
work supplies and verifies those concrete paths and behaviors.

## Evidence locations and verification record

Evidence root: [artifact-cf54ea5-41469260599](D:/clash-kuro/out/artifact-cf54ea5-41469260599).

- `run.json`, `jobs.json`, `artifacts.json`, `ci.log`: GitHub metadata and logs.
- `downloads.json`, the three ZIPs and matching extracted directories: downloaded
  bytes, digest matches and actual extraction locations.
- [inspection.json](D:/clash-kuro/out/artifact-cf54ea5-41469260599/inspection.json),
  `file-hashes.json`, `source-hashes.json`, `source-cf54ea5/`: static findings,
  extracted-byte inventory and immutable source baseline.
- [helper-pe.txt](D:/clash-kuro/out/artifact-cf54ea5-41469260599/helper-pe.txt),
  `helper.manifest.xml`, `collector-syntax.json`: static PE/resource/script checks.
- `asar-inventory.json`, `packaged-main.js`, `platform-test-plain.log`: static
  package contents and the enclosed Platform result log.
- `core-provenance.json` and `upstream-mihomo-windows-amd64-v1-v1.19.33.zip`:
  independent archive-to-packaged-Core hash comparison, without execution.
- `inspect.cjs`: evidence-only verifier. Its assertion checks passed, covering
  identity hashes, checkout content, resources, PE/manifest/import metadata,
  ASAR entry integrity and the scoped CI outcomes described above.

Not checked: local binary execution, actual collector output, live migration or
rollback, real Restart/logoff/shutdown behavior, later source changes or RAS.
Residual risk: verified intermediate bytes and green fixture results do not make
this build safe to activate as the new resident or deliver for manual acceptance.
