# IPv4-only physical uplink compatibility — offline verification

The production preflight no longer requires an IPv6 default route when a verified IPv4 physical default exists. If present, IPv6 default still must share physical interface name/index. With no IPv6 default, literal IPv6 endpoints require a provably preserved more-specific route, including public IPv6 literals; Profile endpoints retain the bound physical egress and system scoped resolvers retain their scope. No DNS field/provider is removed or replaced.

Local dual-stack utun, four split routes, both internal DNS addresses, A/AAAA readiness and network recovery remain required. Existing conflict, reject/blackhole, multiple-default and physical-interface gates remain. Full baseline comparison refuses a newly appearing IPv6 default during startup.

Original source fails the added IPv4-only positive. Candidate adds 18 scenarios (admission/apply/confirm/recovery, literals in all DNS fields/policies/proxy/system, scope/path ambiguity/drop, interface/default changes, DNS/route preservation). Author focused tests plus original production network fixtures and strict compile-only passed. Non-author reviewer checked exact patch/source/tests and evidence; main repeated focused tests and strict production compilation on integrated shared source. No Core, service or network operation was used.

Author patch SHA256 `4ef5ee675eefd6fae33771d1e050cc401befb781673944bb422af2be32444cd6`; raw candidate and red/green evidence `/private/tmp/kuro-ipv4-upstream-candidate`; main integrated binaries `/private/tmp/kuro-ipv4-integration` (production binary not executed).

Not a real network acceptance: domains still resolve using the admitted Profile, and tests do not prove external AAAA reachability. IPv6-only physical uplinks and separate dual-family physical defaults remain unsupported. The frozen 4abee24 production package does not include this change.
