# Integrated root-window preparation (no system experiment)

The six-file window patch `1a8056c7e32657cb48ba552954ba759b5be7c52b4336ee582361e01b728840d8` is integrated. Independent review confirmed exact bytes against the frozen candidate. Main ran the integrated driver suite: 21 tests passed in 1.892s (including actual Foundation JSON and nested fixed cleanup regression); integrated archive suite: 9 tests passed in 0.217s. These tests use explicit kernel/job/root-permission substitutes and temporary files; they are not root Core or launchd evidence.

One review now contains `archive-old → install → normal → prepare-kill → kill-test → retire-kill → cleanup`, with separate `recover-normal` / `recover-kill` stopped-job recovery. Acceptance retains strict booleans. Recovery requires independent current kernel absence and exact job/install/epoch evidence and only unloads the job. It cannot turn a failed stage into accepted evidence or delete files.

Old858 archival first records exact file/evidence identities durably, removes only the four dedicated installation files, and exclusively renames the evidence directory to `TunLifecycleExperimentA-root858-preserved`. Unknown objects, partial installations, identity changes and destination collisions reject. Interrupted unlink/fsync or rename/fsync can resume only against the same durable receipt. No actual archival or new root experiment has occurred.

The frozen review path and hashes will be recorded after committing and preparing these sources. The complete root window still needs approval; the first TUN/network window is separate. Production origin-only cache cleanup remains gated; neither fixtures nor an empty process group prove detached writers absent.
