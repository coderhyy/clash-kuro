# Exact-owned DNS recovery and durable cleanup retries

Base: `7ea44e7d5ea52e04fe08a26a1d247c4be3a3d371`. Implementation frozen by the commit containing this record; integrated checks and artifact identities follow separately.

Two disjoint implementation agents and one non-author reviewer examined the final patches. Session patch SHA256 `8ba5fd3ea0b32ffa4f78e78b68e8eff9a5ebd5de23fbe330517c263ca6d55d54`; network/service patch SHA256 `0b2f9926b0db89ffd2efae2cbdeba57c87a57d9ccfc675a0f58b542d79cd189d`.

- Socket checkpoint equality retries directory fsync. Absent owner/network journals also require successful directory sync before off.
- Held stop retains the original owner bytes/hash/PID cleanup proof after its own successful unlink. Failed sync blocks off/proof; retry only syncs after checking no new owner/work/network footprint. It neither reconstructs proof from absence nor repeats cleanup/signals.
- Fresh production recovery reuses exact-owned DNS cleanup: protected closed journal, generated UUID key, fixed value, repeated journal/value observations and no additional unknown own-prefix key. Changed values/receipts remain preserved. Routes remain absence-only, with no new deletion authority. DNS/routes attempt independently and report separate failures.
- Service attempts bounded residual-network recovery before old Core/work gates. Live/unknown old Core and origin-only cache still fail overall recovery; fresh recovery never creates held-child stop evidence.

Focused ordinary-UID checks: session strict production compile and all SessionTests including four new durability scenarios passed; network/service strict production/test compile and full native fixture suite passed with Core syntax explicitly skipped in the isolated agent copy (18.540 seconds). Fourteen added cases cover real temporary journals and fake-store deletion positive paths, changed/unknown preservation, sync retry, aggregate failures and service old-owner/cache gates. Independent reviewer verified frozen bytes and inspected code/tests/logs, with no blocking finding; did not independently rerun the tests. Main must run the combined native suite with pinned Core syntax enabled.

Limits: no installed helper, root job, real DNS/route writes or real TUN exercised. SCDynamicStore offers no public conditional-remove CAS; repeated checks do not claim immunity to arbitrary concurrent malicious root. DNS cleanup alone is not Core/route shutdown proof. Origin-only cache remains preserved without trustworthy writer-exit/final receipt evidence.

## Integrated execution on 4a8c7acff81f1c52e9dfab221363638161e952bd

Main combined native build/test passed with KURO_REQUIRE_CORE=1 and KURO_SKIP_CORE_SYNTAX unset, including real pinned Core -t and all upgrade/output tests. Hardened Electron finite-session App built and sealed from the same clean source. Fresh pkg SHA256 `06e67370180d243c414ce471b3c0b7af66f44feb88959b9d1bcaf54c44bd2d5f`; helper SHA256 `28f7d71bbf34587d289ff4c19095f1f779e2bdfba79b011f6380069d8b570391`. These are build results, not installation or TUN acceptance.

The new frozen ordinary-user runner was independently checked against six SHA256SUMS entries, four inventory entries and 19 source blobs. Runner SHA256 `fb1b5d17f9a6bb7d32d78b2d5bbbac79a384ae7353b9bfa638141135d8620bef`, epoch `804990BC-7BF7-4658-8EE2-5AB3A686B00C`; exact Core remains v1.19.33 / `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`.

The first harmless self-test inside the sandbox failed with fixture exit94 at its Unix bind/listen branch, before real Core. The failed diagnostic/result were retained. Repeating the same frozen harmless self-test outside the sandbox passed all 212 assertions. No candidate bytes changed.

Real normal then passed: private interface/mode/selector readbacks, two NoIP observations, owner-stop acknowledged, SIGTERM -> Core exit0/no signal. Independent proc_pidpath observed ESRCH for Core82257/worker82256; exact group empty and entire runtime base absent. Only after that gate, real EOF ran and passed: owner-eof/no ACK, SIGTERM -> Core exit0/no signal; Core83040/worker83039 ESRCH, group empty, runtime base absent. The independent reader initially rejected expected EOF diagnostic text `session closed`; source/trigger review corrected that reader, and only the read-only check was repeated. No Core rerun, extra signal or deletion occurred.

Both stream captures reached EOF (stdout490 bytes, stderr0), cache stayed on its precreated inode/owner/mode, and diagnostics remained0700/0600 at `/private/tmp/kuro-core-evidence-eIui64` and `/private/tmp/kuro-core-evidence-DZ8nBJ`. Curated evidence and independent checker are in `real-core/`. EOF is owner-connection closure, not actual Electron exit. No root service, TUN or system network operation was performed.

Independent offline package extraction passed exact payload digests, source/build pins, App seal/runtime/fuses and 611-entry client inventory, fixed fresh scripts/disabled plist and 1,253 root-owned BOM entries. No package scripts or installed binaries were executed. CI run41980439909 failed one existing TypeScript readiness test: expected mixed-port timeout, observed Control Channel timeout. Native CI passed; this source is not reported as CI-green. The test setup is being corrected separately without weakening the production gate.

The subsequent test-only readiness repair binds a real private HTTP API in the test worker after production endpoint removal, preserving a separate accurately owned idle child. It retains the 500ms deadline and mixed-port error assertion, adds actual GET/version + response-finish and child-close assertions, and always closes the API. Focused1/1 and whole platform46/46 passed; independent non-author review found no blocker. CI evidence only proves the final Control Channel timeout, not its exact scheduler history. Production code and native source are unchanged by this repair.
