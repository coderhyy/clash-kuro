# Root no-network window — pending one explicit authorization

Source: `69728e6abeb27f45f1bbea5b47b5e638d5f0ae9e`.
Exact review: `/private/tmp/kuro-lifecycle-core-review-69728e6`.
The [freeze](freeze.json) records approval, executable, driver, cleanup, archive and Core hashes. Complete SHA256SUMS passed; final independent review and CI are recorded in the freeze. No real Core/system action has run from this candidate.

## Requested window (15–20 minutes)

The administrator handles system authorization prompts. Main serially runs each exact review driver operation using `/usr/bin/python3 -I`, the same review path and approval SHA `3b29916ebe575c4679159b8241e89974e37779fd27aba330b62f8a9e8852902d`, recording output/exit and reviewing evidence before continuing:

1. Recheck all hashes, current exact job/process absence, installation identities and archive collision. `archive-old`: only remove the old four approved installation files, then exclusively rename `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA` to `TunLifecycleExperimentA-root858-preserved`. Preserve every old diagnostic/identity file. Unknown objects or partial installation reject.
2. `install`: fresh dedicated helper binary, plist and normal/kill Core copies under the same four fixed locations and protected experiment data directory. Existing objects reject; no job/Core starts at installation.
3. `normal`: run the exact no-TUN/no-DNS/no-IP-listener Core session, private interface/typed readbacks, held-child stop/reap, complete group/owner/work absence and actual job exit0. Main independently reviews the raw records. Any failure prevents kill.
4. `prepare-kill`: after normal fully passes, unload its exact job and replace only its plist with the distinct frozen kill epoch. Do not retire normal first.
5. `kill-test`: start the separate kill session; after exact live identity/group/no-IP readback, send one SIGKILL to the launchd job (never recorded PID/PGID). Read identity/group disappearance at one/five seconds; fallback or reap does not count as launchd cleanup.
6. `retire-kill`: confirm exact processes/group absent and unload the exact stopped job; independently confirm absence.
7. `cleanup`: only after both stages pass and fresh independent absence, retire the new four installation files against durable exact identities. Keep approval, logs, owner/work/cache and directories.

## Stop/recovery limits

Any hash/identity/permission mismatch, unknown object, archive collision, incomplete observation, stage failure or timeout stops later starts and success cleanup. `recover-normal` / `recover-kill` use independent current kernel and exact job/install/epoch evidence to unload only an already stopped job; they do not use the native acceptance boolean. No unknown PID signalling, file deletion or Core restart is permitted by recovery. If those conditions cannot be established, preserve evidence and report the specific remaining state. Partial installation is preserved; it is not silently removed by successful-stage cleanup.

This window changes only the dedicated experiment files/job and fixed Core processes. TUN, DNS service, IP proxy listeners, system proxy/routes/DNS, login items, third-party settings, logout/restart/shutdown remain excluded. Bounded no-IP FD observations are not an OS network sandbox. No production App data is used.

Successful completion retains root0700 evidence at the old archive and new experiment BASE, plus ordinary-user output records. New kill owner/work/cache deliberately remain: this is launchd supervision evidence, not proof of production crash recovery or complete uninstall. The first real TUN/network window remains separate.

## Exact retained locations and deletion scope

The four install targets, both for old retirement and successful new cleanup, are:

- `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a`
- `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist`
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/normal/mihomo`
- `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA/kill/mihomo`

Retain `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA-root858-preserved` for old immutable evidence and `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA` for new approval, diagnostics, receipts and kill work/cache. No recursive removal. Keep `/private/tmp/kuro-lifecycle-core-review-69728e6`, old pinned `/private/tmp/kuro-lifecycle-core-review-85834ab`, `/private/tmp/kuro-root858-normal-retire-candidate` and `/private/tmp/kuro-root858-cleanup-candidate` available through the window: the entry checks the exact dependency paths/hashes. These are preserved inputs, not extra installation targets.

Root command form (execute one operation at a time, never an unconditional chain):

```text
/usr/bin/python3 -I /private/tmp/kuro-lifecycle-core-review-69728e6/core-driver.py OPERATION --review /private/tmp/kuro-lifecycle-core-review-69728e6 --approval-sha 3b29916ebe575c4679159b8241e89974e37779fd27aba330b62f8a9e8852902d
```

The administrator supplies authorization through the system prompt; no passwords are recorded. Any partial installation or unverifiable live state is retained and reported. Recovery does not promise to stop an unknown/live process: it is deliberately limited to bootout after independently established absence.
