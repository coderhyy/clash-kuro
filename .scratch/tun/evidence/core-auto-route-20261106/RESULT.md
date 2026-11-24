# Core auto-route integration (offline)

Manual PF_ROUTE mutation, encoder and ACK handling are removed. Core is the sole route writer; helper DNS remains. Root generates four fixed /1 route-address ranges; pinned sing-tun requests its additional IPv4 /30. Five requests and modeled samples do not prove five installed routes.

Pre-CONT intent binds the full route/DNS baseline to session, fixed Core/config/runtime digests and held process identity. Actual held utun and bounded fixed route readback precede internal DNS probing/helper DNS. Missing routes alone may wait within the original 1.5s deadline; ambiguity, conflicting material properties, read failure or identity loss refuse. Fixed mihomo hub/hub.go:55–82 creates its controller before executor.ApplyConfig; executor.go:107–108 configures listeners/TUN afterward, so /version alone is not network readiness.

Stop/recovery never deletes routes. Accurate Core teardown precedes baseline/absence proof; fresh recorded intent retirement requires existing writer-exit closure and complete owner binding. Current route absence cannot retire an intent while its writer remains live. Legacy v1 records are absence-only. A persisted stopped proof can be reread after owner unlink only when no route journal remains and owner is explicitly ENOENT; this does not grant historical reap authority.

First full native run exposed that legitimate stopped-proof replay after owner unlink had been over-rejected. The narrow absent-owner case was corrected and the second full native run passed, including eight production adapter/store/native admission chains. Fresh start/stop succeeds with simulated system backends; partial route startup fails, never applies DNS, and recovers ready/off with owner/work absent. Fixed Core -t passed (process/temp config only, no TUN activation).

The real network window is still pending. No auto-route traffic, actual route disappearance, LAN/split DNS, external IPv6, helper-kill or upgrade acceptance is claimed here. Existing unrelated ordinary fixture timeout investigation remains separate.
