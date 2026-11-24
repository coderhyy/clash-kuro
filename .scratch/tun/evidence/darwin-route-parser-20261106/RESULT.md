# Darwin route decoder compatibility fix

Only `tun-routes.m` and `tun-routes.test.m`. Shared source not modified.

Captured current production decoder rejects 52 of 62 real RTM_GET packets: 42 compact masks whose second byte is `ff`, and 10 local IPv6 host routes whose destination KAME scope differs from lo0 route egress. First failures are offsets144 (127/8 mask05ffffffff) and3144 (LOCAL|HOST link-local address zone14 via route index1).

Mask family now comes from destination only; length bounds, zero-fill and contiguous-mask checks remain. Destination scope may differ from egress only for LOCAL|HOST IPv6 records; explicit/KAME conflict, nonlocal mismatches and gateway scope checks remain rejected. Desired route schema and compare-delete authority are unchanged.

Four fixed sanitized wire fixtures are exposed as `DarwinRouteFixturePackets()` for the separate existing admission chain. No original private raw dump is included in the patch. Existing route tests plus new wire negatives pass; original decoder fails the same new tests. Complete local raw replay (11004bytes/62routes, SHA31dc246df7bd48d66d3852f4356e192206339c53fdaee86b3c08fc05dbb7ed03) passes with candidate. Strict production compile passes.

Only offline bytes and ordinary-UID temporary journal fixtures were executed. No sysctl/PF_ROUTE, real Core, root/service/system network operations. This is parser evidence; the separate actual admission chain and a new frozen candidate acceptance remain necessary. No preflight compatibility policy was widened.
