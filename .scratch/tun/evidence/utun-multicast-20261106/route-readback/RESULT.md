# Exact Darwin route readback flags

Request flags remain UP|STATIC|PROTO2 plus existing gateway/host flags. Expected readback adds PRCLONING exactly for non-host routes, both IPv4 and IPv6. No new ignored flags: DONE/IFREF remain the only bookkeeping mask; missing PRCLONING, extra IFSCOPE/CLONING/HOST/MULTICAST/GATEWAY/REJECT/BLACKHOLE/WASCLONED/DYNAMIC, missing UP/STATIC/PROTO2, and PRCLONING on host routes are rejected.

Pinned Apple XNU f6217f891ac0bb64f3d375211650a4c1ff8ca1ea: route.c2355 invokes rnh_addaddr; in_rmx.c711 binds in_addroute,140–141 adds PRCLONING; in6_rmx.c800 binds in6_addroute,195–197 same rule. Neither exempts PROTO2. rtsock.c470–478 takes interface scope from rtm_index only with RTF_IFSCOPE; our fixed requests omit that bit, so unexpected scoped readback is still rejected.

The common fake store now independently models that XNU rule for every add/readback/delete, including existing production coordinator fixtures. Pure RTM_GET packet decoding tests also explicitly model the kernel bit instead of roundtripping our request header unchanged.

GREEN strict clang+RouteTests+existing ProductionNetworkTests exit0 (including four split route install/confirm/live recovery, partial recovery and preserved LAN/DNS; all existing multicast/DNS/IPv4-only cases pass). RED same coordinator, same kernel-like backend, only old production tun-routes.m: real apply refuses first route readback and retains journal. No Core, route socket, sysctl, service, or system network was executed. This is a source-backed isolated regression, not a completed real TUN window.
