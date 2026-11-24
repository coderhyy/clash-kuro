# dd3f0d4 real DNS diagnostic window

CI42165003811 both platforms passed; standard native/actual package offline review and same-production readonly baseline passed. Baseline remained approved router DNS192.168.0.1, third-party App/Core absent. Exact package SHA142cc4ea49dcda32c154a110844151a8f068474ed56e081d20362251816b6599.

Fresh install/actual App pin/seal and authenticated ready/off passed. One App TUN start produced the exact error: `fixed internal IPv4 DNS static-host probe was not confirmed; stage=send; elapsedMs=1; errno=65; poll=0; revents=0x0; sent=-1/40; received=-1; header=; reason=`. Darwin errno65=EHOSTUNREACH. This proves the bound probe could not send to the fixed internal DNS target before route application; no DNS response or public test flow was received/sent. It does not establish TUN traffic acceptance.

Exact Core SIGTERM/exit0, complete logs, restored network and durable held stop proof. App exited normally, job bootout/uninstall and exact receipt install-time1793941115 cleanup completed. All installation paths/processes/job/receipt independently absent; proxy/DNS/DNS-store byte-equal baseline and production stable route baseline matches. Diagnostic evidence/user data preserved. See real-result.json and private-window-inventory.json.

Implementation now proceeds under continuous same-scope authorization: two fixed internal host routes must be recorded+readback before probes, then strictly extend same ledger to six routes before system DNS. No change to DNS provider, Profile, disabled Core OS-DNS writer mode, timeout, or response checks. Prior ordinary-child timeout remains separately unresolved.
