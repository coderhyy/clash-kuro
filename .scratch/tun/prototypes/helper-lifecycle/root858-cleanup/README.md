# root858 exact file retirement — prepared, not executed

Use only after frozen source 85834ab8bc8d45c24f232883133a58d13b2daa6f completes normal, independently checked normal job exit0, the distinct kill stage and its 1s/5s group observations, then **retire-kill** confirms the exact job absent. This does not handle failed normal, partial installation, live/reused/unknown process identities, missing kill evidence or failed group cleanup. Preserve those states instead of running cleanup.

The independent script does not alter or rebuild /private/tmp/kuro-lifecycle-core-review-85834ab. It accepts no path or operation arguments. Python 3 standard library plus macOS libproc and fixed /bin/ls, /bin/launchctl are required; it uses read-only launchctl print, never bootstrap/bootout/kill. No Core or experimental executable is executed by this script.

## Review and authorized window

First verify the standalone script SHA256 (expected: 768d0938c0d0e321f8152c0328c8a629d0e30379ad57aa3052f1094ccfe482dc):

```sh
/usr/bin/shasum -a 256 /private/tmp/kuro-root858-cleanup-candidate/cleanup-root858.py
```

Only after the user explicitly authorizes the root858 normal/kill window including retirement and the exact four-file cleanup, run the reviewed script once after retire-kill:

```sh
sudo /usr/bin/python3 -I /private/tmp/kuro-root858-cleanup-candidate/cleanup-root858.py
```

Save the full terminal output with the experiment logs. Allow roughly 30–60 seconds for cleanup and filesystem checks, plus the administrator prompt; this estimate has not been measured under root. Stop on BLOCKED. Do not chmod/fix/delete conflicting objects or signal recorded PIDs/PGIDs. A retry of this same exact script is allowed only for the specifically reviewed interrupted-cleanup case with unchanged evidence and still-proven absence; it repeats all process/job checks.

## Deletes exactly four files

1. /Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist — exact frozen kill-stage plist, root0644.
2. /Library/Application Support/Clash Kuro/TunLifecycleExperimentA/normal/mihomo — pinned Core, root0755.
3. /Library/Application Support/Clash Kuro/TunLifecycleExperimentA/kill/mihomo — same pinned Core, root0755.
4. /Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a — pinned frozen fixture, root0755.

All ancestors must remain root-protected, without symlinks/write permissions/ACLs. BASE and normal/kill evidence directories must be 0700. First deletion requires all four files present and an exclusive root0600 cleanup-approved-root858.json record fsynced inside BASE with their dev/inode/owner/group/mode/nlink/size/time/hash and exact evidence hashes. Record creation/sync failure removes nothing. Each invocation validates all remaining identities before any unlink, independently rechecks both stage processes and complete groups and exact job absence before every unlink, then fsyncs that target parent. Missing targets are accepted only with this intact cleanup record; retry still synchronizes the parent. Replacement objects, including byte-identical changed inodes, are rejected and preserved. Unknown/partial cleanup records are never overwritten.

Preserves BASE, its original approval, original logs, normal/kill stage evidence, kill owner/session-work/cache, unknown files, all directories/shared parents and the new cleanup approval. There is no recursive removal and no production App/helper/userData or network change. Retained original sensitive evidence stays inside the existing root0700 directories; do not upload it unredacted. This is installation-file retirement, not full evidence removal or a production recovery proof.

## Offline validation only

```sh
/usr/bin/python3 -m unittest discover -s /private/tmp/kuro-root858-cleanup-candidate -p test_cleanup.py -v
```

12 tests passed, including four interrupted-unlink recovery paths, durable approval before deletion, identity/mode/symlink/unknown preservation, partial-install refusal, process/job unknown refusal, malformed/negative/overflow libproc group responses and real read-only self-PID rejection. File fixtures run as the ordinary user with temporary paths; root ownership/ACL/job observations are injected. Successful fixture deletion does not prove real root/macOS job acceptance. The production process observer performs no signals, rejects any existing PID including reused identities, and requires fully empty groups; it does not prove arbitrary detached descendants absent.
