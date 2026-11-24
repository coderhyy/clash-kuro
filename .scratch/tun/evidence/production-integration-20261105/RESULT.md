# Shared-tree production subscription integration — 2026-11-05

Parent applied the reviewed cache and subscription patches after real ordinary-UID Core candidate `98f1afb` normal/EOF passed. This check validates the shared TypeScript source, not the earlier `/private/tmp` copy. Exact checked source bytes are listed in [source-sha256.json](source-sha256.json); commands and cwd are in [commands.json](commands.json).

- Subscription focused tests: **4 files, 148/148 passed**, exit 0. State TUN44, macOS transport46, platform41, renderer17. Includes real temporary Unix peer EOF → adapter invalidation → existing state command queue → independent status; still-on readback becomes unknown, proven-off readback synchronizes ordinary Core state read-only. No automatic recover/start or new polling.
- State typecheck: exit 0.
- Desktop main typecheck: exit 0.

The first sandboxed test attempt was blocked by temporary Unix socket `listen EPERM` (22 failed, 85 passed, 41 skipped); its separate `subscription-tests.sandbox.*` logs are retained. The same test command reran outside that filesystem/socket sandbox under the ordinary user and passed all 148. This permission change enabled temporary Unix/loopback fixtures only; no Core, `-t`, installed helper, root installation, TUN, route/DNS, proxy or login operations were executed. No source changes were made by this verification. Native verification is owned by the primary session and is not included in these counts.

Raw output/result: [tests stdout](subscription-tests.stdout.log), [tests stderr](subscription-tests.stderr.log), [tests result](subscription-tests.result.json), [State result](state-typecheck.result.json), [main result](main-typecheck.result.json). These results do not establish real TUN networking, runtime uninstall, upgrades, detached-descendant exit or cross-helper network recovery.
