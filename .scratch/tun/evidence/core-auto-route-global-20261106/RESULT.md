# Exact Core auto-route RTF_GLOBAL observation

Controlled normal-window source27a1e54f690282e029488024f7c3fd938a97e000 passed both-platform CI42194367408 and independent source/package review. Phone-disconnected baseline passed before fresh installation.

Actual installed App authenticated to ready. Fixed Core created the TUN adapter, but readback rejected the lower IPv4 /1 route. Exact closed tuple matched destination/prefix/family/gateway and held utun identity; actual flags1073809411 (0x40010803) versus expected67587 (0x10803). Sole difference0x40000000=RTF_GLOBAL, defined by macOS SDK route.h. Fixed XNU route.c SA_DEFAULT checks zero destination without checking prefix, and adds GLOBAL to non-host RTM_ADD. This supports only lower IPv4/IPv6 /1 in the fixed plan, not the upper halves or internal /30.

Minimal correction permits optional GLOBAL only on those two keys. Other bits, route keys, gateway, exact interface index/name and observation/recovery checks remain mandatory. Regression replays actual tuple through the real observer; old code rejects, new code accepts, invalid material flags/gateway/interface and GLOBAL on other plan keys still reject. Coordinator fixture now uses the same source-grounded route samples.

Same-session failed-start recovery: SIGTERM exit0, both output EOF, durable child/network-off proof, no work/journal/owner residue. Routes and DNS restored exactly. Two unrelated Apple peer-interface linklocal addresses rotated; after independent saved-diff review, cleanup used a separately pinned stop-only snapshot. Original install baseline preserved, no interface or third-party setting modified. Exact job/install/receipt cleanup completed. Raw network/device/session evidence remains local and is not uploaded.

No traffic probe was attempted. Normal active TUN traffic and shutdown, external IPv6 and abnormal recovery remain unverified. USB/peer-interface dynamics require later compatibility validation; exact whole-baseline comparison in this controlled experiment is not a product requirement to reject all unrelated network changes.

Full local native/upgrade fixtures, fixed Core syntax validation, all eight production admission chains and bounded-output tests passed; no root/service/network activation. Raw execution log remains /private/tmp/kuro-global-full-native.log.

## dd312 controlled retry

Exact source dd312b63bb890cf97a14edecfd18addfa1a2a818, package SHA764e0061317e88767cec9431f4ab6f6262e31f81325f01adf06b0ca1979aa6c9; both-platform CI42198982549 and actual package review passed. Same approved Profile, disconnected-phone baseline, fresh install. Actual App reached ready; route readiness and internal DNS checks proceeded beyond the previous GLOBAL refusal. Resolver publication then failed with `temporary DNS write was not independently confirmed; journal retained`.

Core logs contain background connections classified MATCH,DIRECT, proving delivery into this Core but not successful outbound forwarding. Several TCP ENETUNREACH messages occurred before the final shutdown log; their timing does not resolve possible cleanup races. No controlled flow probe completed. Fixed runtime interface binding remains enabled and must not be relaxed based on these logs.

Same-session recovery passed: SIGTERM exit0, both output EOF, durable child/route/DNS-off proof, exact baseline route/DNS restoration. App exited after proof; accurate job/native uninstall and exact receipt cleanup succeeded. No install/process/job residue. Raw evidence remains local at /private/tmp/kuro-dd312b6-window-952rhs4a; retained protected diagnostics are local only.

Source review found the DNS generic error overwrites three distinct failures: readback backend error, value mismatch, and post-write admission error. Next minimal diagnostic change preserves the real branch/reason without changing acceptance, retrying, or adding network reads. Full TUN start/traffic/normal stop remains unverified.
