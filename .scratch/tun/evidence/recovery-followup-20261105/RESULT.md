# Recovery and upgrade follow-up

Base source `27096937ad48320ac3cb47546cff39001fa60bd1`. Two disjoint agents implemented the changes; one non-author reviewer verified both exact frozen patches and code/test evidence. No new component, persistent receipt schema, ticket, kill authority or architecture was added.

## Old group rejection

Patch SHA256 `69e7544201e365af98c42ca21366da85b860d367b75b7b48bd06740bd2c711c3`.

The baseline reproducer uses a mocked recorded-Core ESRCH and reads the actual current nonempty process group. Existing code accepted an exact final-cache receipt and removed work/owner despite that nonempty group. This was an isolated fixture, not a real Core failure experiment. The fix adds bounded `proc_listpids(PROC_PGRP_ONLY)` observation at every restart `stillAbsent` check, refusing nonempty, errno, truncated and malformed observations. Production always uses the actual kernel reader; only KURO_TESTING can substitute it. Reused group identifiers conservatively block; no group is killed or adopted. Empty groups are only another necessary condition, not writer-exit proof. Origin-only cache remains rejected.

Author focused owner/work/cache checks and actual read-only nonempty group observation passed; strict production compilation passed without executing the helper. The reviewer verified patch/source hashes and inspected the reproducer and logs without rerunning them.

## Upgrade retirement durability

Patch SHA256 `7997079cecdf56a6bed170a1722dc3a89d31ae18a15392afceb5697d9bbcceb0`.

After final approval unlink, fsync failure previously allowed the no-record retry to report success without synchronizing. Both original retirement and a no-record retry now synchronize the same fixed parent, after all existing layout/identity/off-proof checks. Tests cover consecutive sync failures, changed App preservation before retry sync, actual successful fsync, fresh recovery CLI and exact uninstall. Author upgrade fixtures and existing transaction interruption cases passed (44.787s); independent reviewer found no blocker.

## Delivery boundary

04/06/08 top sections now distinguish current code, evidence and missing work; history remains. 08 consolidates the root non-network window, first normal TUN/App-quit window prerequisites, and still-missing helper-death writer recovery and actual upgrade acceptance. Root858 artifacts and frozen production4abee package remain unchanged. No ordinary-user real Core rerun, Core-t, new package, installation, service or system network experiment was performed in this follow-up. These fixes are not inside the older4abee package; a relevant future acceptance must use a newly frozen candidate rather than relabeling old artifacts.

Main integrated verification: strict production and test clang builds passed. Complete native fixture suite ran once with KURO_SKIP_CORE_SYNTAX=1 and exited0; combined upgrade suite exited0, including new retirement retry and prior transaction interruptions. Main ran no real Core/-t or system mutation. Native stderr contains expected negative-case diagnostics; successful process exit is recorded separately from those messages. No rebuilt production artifact is claimed.
