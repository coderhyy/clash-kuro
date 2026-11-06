# Exact Core auto-route RTF_GLOBAL observation

Controlled normal-window source27a1e54f690282e029488024f7c3fd938a97e000 passed both-platform CI42194367408 and independent source/package review. Phone-disconnected baseline passed before fresh installation.

Actual installed App authenticated to ready. Fixed Core created the TUN adapter, but readback rejected the lower IPv4 /1 route. Exact closed tuple matched destination/prefix/family/gateway and held utun identity; actual flags1073809411 (0x40010803) versus expected67587 (0x10803). Sole difference0x40000000=RTF_GLOBAL, defined by macOS SDK route.h. Fixed XNU route.c SA_DEFAULT checks zero destination without checking prefix, and adds GLOBAL to non-host RTM_ADD. This supports only lower IPv4/IPv6 /1 in the fixed plan, not the upper halves or internal /30.

Minimal correction permits optional GLOBAL only on those two keys. Other bits, route keys, gateway, exact interface index/name and observation/recovery checks remain mandatory. Regression replays actual tuple through the real observer; old code rejects, new code accepts, invalid material flags/gateway/interface and GLOBAL on other plan keys still reject. Coordinator fixture now uses the same source-grounded route samples.

Same-session failed-start recovery: SIGTERM exit0, both output EOF, durable child/network-off proof, no work/journal/owner residue. Routes and DNS restored exactly. Two unrelated Apple peer-interface linklocal addresses rotated; after independent saved-diff review, cleanup used a separately pinned stop-only snapshot. Original install baseline preserved, no interface or third-party setting modified. Exact job/install/receipt cleanup completed. Raw network/device/session evidence remains local and is not uploaded.

No traffic probe was attempted. Normal active TUN traffic and shutdown, external IPv6 and abnormal recovery remain unverified. USB/peer-interface dynamics require later compatibility validation; exact whole-baseline comparison in this controlled experiment is not a product requirement to reject all unrelated network changes.

Full local native/upgrade fixtures, fixed Core syntax validation, all eight production admission chains and bounded-output tests passed; no root/service/network activation. Raw execution log remains /private/tmp/kuro-global-full-native.log.
