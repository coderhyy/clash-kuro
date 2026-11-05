# Exact-owned DNS recovery and durable cleanup retries

Base: `7ea44e7d5ea52e04fe08a26a1d247c4be3a3d371`. Implementation frozen by the commit containing this record; integrated checks and artifact identities follow separately.

Two disjoint implementation agents and one non-author reviewer examined the final patches. Session patch SHA256 `8ba5fd3ea0b32ffa4f78e78b68e8eff9a5ebd5de23fbe330517c263ca6d55d54`; network/service patch SHA256 `0b2f9926b0db89ffd2efae2cbdeba57c87a57d9ccfc675a0f58b542d79cd189d`.

- Socket checkpoint equality retries directory fsync. Absent owner/network journals also require successful directory sync before off.
- Held stop retains the original owner bytes/hash/PID cleanup proof after its own successful unlink. Failed sync blocks off/proof; retry only syncs after checking no new owner/work/network footprint. It neither reconstructs proof from absence nor repeats cleanup/signals.
- Fresh production recovery reuses exact-owned DNS cleanup: protected closed journal, generated UUID key, fixed value, repeated journal/value observations and no additional unknown own-prefix key. Changed values/receipts remain preserved. Routes remain absence-only, with no new deletion authority. DNS/routes attempt independently and report separate failures.
- Service attempts bounded residual-network recovery before old Core/work gates. Live/unknown old Core and origin-only cache still fail overall recovery; fresh recovery never creates held-child stop evidence.

Focused ordinary-UID checks: session strict production compile and all SessionTests including four new durability scenarios passed; network/service strict production/test compile and full native fixture suite passed with Core syntax explicitly skipped in the isolated agent copy (18.540 seconds). Fourteen added cases cover real temporary journals and fake-store deletion positive paths, changed/unknown preservation, sync retry, aggregate failures and service old-owner/cache gates. Independent reviewer verified frozen bytes and inspected code/tests/logs, with no blocking finding; did not independently rerun the tests. Main must run the combined native suite with pinned Core syntax enabled.

Limits: no installed helper, root job, real DNS/route writes or real TUN exercised. SCDynamicStore offers no public conditional-remove CAS; repeated checks do not claim immunity to arbitrary concurrent malicious root. DNS cleanup alone is not Core/route shutdown proof. Origin-only cache remains preserved without trustworthy writer-exit/final receipt evidence.
