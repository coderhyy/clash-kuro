# Supervised restart owner: reject a live or unobservable old helper

Integrated two-file patch `2df6d422d597191fe9eca6b2cd3b92d349abfe14185d146569283b5faa9e286e` adds one refusal gate to the existing restart `stillAbsent` callback. For receipts with supervision provenance, the recorded parent must return exactly0/ESRCH. Same-instance live, reused PID, denied/partial/unknown observation all preserve owner/work. Checks repeat at every existing checkpoint; legacy has no additional helper lookup. No signals, identity adoption, cleanup capability or new receipt fields.

The original baseline fails the new live-helper regression. Author focused tests cover10 existing owner cases and11 new supervised/legacy cases, including helper reappearance after network/before/during work cleanup and before owner retirement. They use actual temporary owner files and injected libproc observations; no real root/Core/launchd/network behavior is inferred. Independent reviewer verified patch/hash/callers and test assertions with no blocking findings.

Production strict compilation and integrated test compilation passed. Test-only compilation retains the existing unused-function exemption because the test translation unit excludes production entrypoints; production compile has no exemption.

This does not authorize origin-only cache snapshot/cleanup, establish all writers absent or grant a fresh stopped proof. The production service's independent residual DNS recovery path remains unchanged. Remaining implementation: trustworthy production installed/loaded supervision binding, durable finite cache recovery checkpoint and truthful post-crash uninstall/upgrade evidence.

Main integrated full native fixture suite passed exit0 in20.710s, with `KURO_SKIP_CORE_SYNTAX=1`. New11 supervisor cases and final native-suite PASS are present in `/private/tmp/kuro-supervisor-absence-integrated/stdout.log`; stderr and result.json are retained alongside. No actual Core or system operation ran.

Exact source3728bc7 subsequently passed both macOS and Windows CI; see `ci.json`. This is isolated/build/integration evidence, not another root or network experiment.
