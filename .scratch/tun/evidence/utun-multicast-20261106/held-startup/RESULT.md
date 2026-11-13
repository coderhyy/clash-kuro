# Held checkpoint fixture startup diagnosis

The standard failure at tun-service.test.m700 is scenario12 in HeldStopCheckpointTests. ServiceHooks.ready verifies direct child identity; applyNetwork/recoverNetwork are isolated successful hooks. This case never consumes route flags or a route store. Existing code search found no alternate old request flags used as expected readback.

Saved failed fixture: `/private/tmp/ks-T7F5MU/s12/.../TunDiagnostics/3B652F81-8D0D-4A91-A805-E340E17E1186`. Already-redacted summary reports `private Core socket is not an owned Unix socket`, stage `private Core version readiness`, stderr/stdout zero bytes, observed SIGTERM15. Launch filesystem time to final summary is approximately1.02s; private socket path is99bytes (capacity104). No entry marker was captured. That is not proof the child was scheduled, entered main, failed bind, or that a scheduler race caused failure.

Actual order: posix_spawn START_SUSPENDED → held identity/journal/prepare → resume gate → SIGCONT succeeds → service starts1s deadline → repeated socketProtected(lstat) / typed GET-version attempts with10ms loop until deadline. Socket absence rejects an individual request, not the whole startup immediately. Child fixture entry → runtime/cache validation → socket/bind/listen → accept/version-request → reply. Therefore no missing startup wait was found.

One authorized ordinary-UID focused invocation of existing13 held-stop tests passed, including scenario12 real open/stop/recovery/uninstall. The temporary wrapper adds earliest-main-entry instrumentation. No real Core, system services or network configuration ran. No root-cause RED→GREEN repair is claimed.

Optional two-line diagnostic-only patch attaches this specific open assertion to the existing already-redacted report with measured elapsed. Original deadline/strict assertion/cleanup unchanged. Do not classify it as fixing startup stability or PRCLONING.
