# Bounded held-utun IPv6 multicast compatibility

Only tun-production-network.m and .test.m change. Actual 11902 refusal: ff00::%25/8, utun6/25, flags 25166081 (0x01800101), link-local gateway. No live observation was performed by this candidate.

## Fixed primary source

Apple XNU commit f6217f891ac0bb64f3d375211650a4c1ff8ca1ea; downloaded source metadata contains Git blob SHA and immutable URLs:
- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/netinet6/in6.c#L2138 — IFF_MULTICAST address-configuration branch.
- in6.c:2194–2213 creates link-local all-nodes ff02::/32, :2267–2290 creates interface-local ff01::/32, :2313–2340 explicitly creates ff00::/8. Each uses ia_addr as gateway, UP|CLONING, and the same scoped ifindex. The kernel does not promise that ia_addr is always link-local; only the observed link-local case is admitted here.
- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/netinet6/in6_rmx.c#L191 — IPv6 multicast destination adds RTF_MULTICAST.
- https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/route.c#L1886 — nonzero scoped request adds RTF_IFSCOPE (independently cross-checked by reviewer).

## Exact admission and authority

Only three canonical destinations, zone equal to held ifindex: ff00::%N/8, ff01::%N/32, ff02::%N/32. Family6, held name and index, normalized flags exactly UP|CLONING|MULTICAST|IFSCOPE. A fresh independent interface snapshot must have exactly one link-local /64 address on that same running point-to-point interface; canonical address plus zone must equal gateway. Missing/duplicate/wrong prefix/wrong interface/address/flags/zone or unrecognized multicast stays rejected. Existing complete baseline matching, Core ownership, dual-stack readiness, DNS and physical baseline checks remain.

No journal or route deletion authority added. Companion routes are observed extras, not split-route targets. Fixture recovery leaves all three companion routes untouched and only removes the original four journalled split routes plus owned DNS key. Their real lifecycle/disappearance remains a controlled-window acceptance check.

## Offline verification

Strict production and focused test compile pass. Focused ProductionNetworkTests passes, including 15 new cases, original 3 diagnostic/4 metadata/8 recovered readback/18 upstream and existing apply/recovery cases. Baseline production source with the same new test fails the first positive case; baseline source snapshot is retained. All writable route/DNS stores and interface/Core ownership observations are fixtures; no Core, network, install or system commands executed.

Independent downstream IPv4 and IPv6 /1 PRCLONING correction is integrated separately in tun-routes.m/test. Request flags are unchanged; expected readback requires exactly the kernel-added PRCLONING bit, still rejecting unexpected scope or other material differences. See route-readback/RESULT.md and freeze.json. Both patches passed independent review; neither establishes actual traffic or later real startup gates.
