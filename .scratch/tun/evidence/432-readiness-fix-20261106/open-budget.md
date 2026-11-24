Open response budget fix

Observed 432 native diagnostic: fixed dual-stack utun addresses are not uniquely ready. Launch diagnostics prepared 10:56:45.453; Core initialization at 46.404, shutdown 47.983, final diagnostics 48.010 (~2.56s total). Client old shared2s timer cannot cover private readiness+utun readiness+owned stop+diagnostic persistence before native error reply.

Only open defaults to 15s. Heartbeat/stop remain2s; explicit timeoutMs retains previous override behavior; lease15s and unknown/disconnect semantics unchanged. Four deterministic temp-socket/virtual-clock regressions cover native exact refusal after2.5s, open expires15s/rejects late success, default heartbeat and stop each expire2s. Baseline exact-error regression fails with timeout instead of native reason. Fixed full client suite57/57 and main typecheck0.

15s is finite client patience, not native hard completion proof: Security/fsync and scheduling are not globally bounded. No Core/system operation was run.
