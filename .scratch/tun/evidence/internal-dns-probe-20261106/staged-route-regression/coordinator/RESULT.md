# Host-only DNS readiness before full network activation

Only tun-production-network.m and .test.m change. Requires exact routes.m SHA256 3bbf104cdbaf236d894326758e6fb61cca701195e9727627d41317923145d3bc from the independent route continuation patch.

## Production sequence and authority

readyChild first verifies original held Core interface/dual-stack addresses and full unchanged baseline. It installs only KuroInternalDNSRouteCandidate (198.18.0.2/32 and fdfe:dcba:9876::2/128), requiring protected exact plan/applied2, real readback/live ownership and durable confirmation. Only then the private expected plan is set to host2; unchangedBaseline rechecks complete durable current plan and baseline before the original fixed DNS probe. Internal DNS-ready is set only after probe success and ownership reconfirmation. Second ready and apply without successful readiness are refused.

apply first requires exact complete host2 receipts, unchanged baseline, held addresses/ownership/probe. It calls the fixed no-plan-argument continuation; only after full6 exact receipts/readback are confirmed does the internal expectation become full6. DNS uses existing installPreparedSession with an admission closure that independently requires exact complete full6, live/readback, fixed dual-stack addresses and fixed probe on each admission. It never calls active DNS-key verification before the key exists. Final active confirm requires full6 and the existing exact owned-DNS readback/baseline checks.

Phase state itself confers no authority: each baseline and full admission compares protected journal session/association/routes/applied, uses existing confirmInstalledSession including fsync/live/readback, and only then accepts the exact installed route extras. Unreceipted or conflicting extra routes remain refused. One existing route journal records all host/split entries; recovery remains the existing record-driven primitive, including old v1 four-route journals. The coordinator resets phase only after independent recovery success. Partial/unacknowledged changes preserve conflicts and receipts; no new old-PID/interface cleanup authority.

## Meaningful offline evidence

The fixture now uses actual IPv4 P2P local host .1/32, not invented .0/30. A route-aware send seam executes the original KuroProbeInternalDNS control flow, verifies the exact scoped .2 or ::2 route and otherwise returns EHOSTUNREACH. It feeds only the fixed own DNS answer through the unchanged strict parser; no real network calls. Successful first probe asserts a real temp-file complete host2 receipt and zero DNS/split writes. Actual KuroOwnedRoutes performs journal publication/confirmation/continuation/recovery against fake writable stores.

14 new coordinator cases pass: full positive2->6->DNS; first/second host failure; probe failure; initial sync failure; first split failure; lost split ACK preserved until simulated exited-interface absence; apply without readiness; repeated ready; host-only active-confirm refusal; baseline change; unreceipted host; changed journal plan; ready then stop without apply recovers host2 and permits a clean next preflight. Existing 22 syscall diagnostic and full ProductionNetworkTests also pass, with six-route assertions and real P2P shapes updated.

Old production coordinator plus the identical new route primitive and route-aware test fails the first positive case with stage=send errno=65, sent=-1/40. Baseline-native snapshot, strict compile, RED and final GREEN logs/commands are retained. Strict production compile is also exit0. No Core, installation, PF_ROUTE, live interface/network read/write or service was executed.

## Callers / integration

Production helper ready/apply/recover hooks keep existing signatures and need no changes. Generic DNS/route primitives are not redefined. Parent owns tun-admission.test.m P2P+route-aware seven-chain fixture and candidate-startup.test.ts routeAdds6. This focused verification does not claim those integrated chains or real root/traffic acceptance.
