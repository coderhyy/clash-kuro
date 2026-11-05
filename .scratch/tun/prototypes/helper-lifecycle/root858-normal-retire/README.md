# root858 normal-job retirement — prepared, not executed

This independent recovery entry requires **new explicit user approval**. Previous root858 normal/kill authorization does not authorize running it. It applies only to the already completed normal epoch 91EE2723-A085-485F-A9E9-E24155642B5B, frozen source85834ab8bc8d45c24f232883133a58d13b2daa6f, whose native normal receipt and job exit0 passed but whose original observer emitted JSON number1 and caused driver rejection. It does not patch that frozen package or continue/retry any Core stage.

Expected script SHA256: 29c5fc0ae37902f77a89ed1f03ff2fcaeabe4dbad541d096d24ab6432a61fd27

Read-only verification:

```sh
/usr/bin/shasum -a 256 /private/tmp/kuro-root858-normal-retire-candidate/retire-normal-root858.py
```

**Only after the new approval**, administrator command (fixed; no arguments):

```sh
sudo /usr/bin/python3 -I /private/tmp/kuro-root858-normal-retire-candidate/retire-normal-root858.py
```

Allow roughly 10–30 seconds plus the password prompt. Save full terminal output. The sole permitted mutation is `/bin/launchctl bootout system/dev.kuro.tun.lifecycle-a` after repeated proof of exact normal job runs1/not-running/exit0/no live PID/no terminating signal, recorded supervisor/Core PID ESRCH and complete empty group, exact protected normal installation and approval, normal-success receipt and unchanged root0600 normal evidence under root0700 directories, and owner/session-work absence. A final independent readback must prove job absent and processes/group absent. No bootstrap, kickstart, Core/fixture execution, PID/PGID signal, file deletion, new installed file, chmod or directory removal occurs. The entire installation, approval, original logs/owner/work/cache and both Core copies remain untouched.

If the job is already absent, the same entry only verifies and reports; it does not create/restart a job. It refuses partial installations, kill attempts/evidence, wrong epoch/path/pins/receipt, unknown/live/reused PIDs/groups, changed normal evidence and any present job lacking exact normal exit0. A failed bootout or uncertain final readback stops and preserves all resources. No retry of normal/kill or broader recovery is authorized by this entry.

Pinned dependencies, checked before any Python source executes:

- /private/tmp/kuro-lifecycle-core-review-85834ab/core-driver.py SHA25688e2c6b830b51c48498c6c44d32a2a17eeb5700b006854b2b5d4ac9b4836668f
- /private/tmp/kuro-lifecycle-core-review-85834ab/experiment-a.py SHA2564b1c05025816da23ffe702eaaaa7598c12d4663c0c8836c608f059479ee64953
- /private/tmp/kuro-root858-cleanup-candidate/cleanup-root858.py SHA256768d0938c0d0e321f8152c0328c8a629d0e30379ad57aa3052f1094ccfe482dc

Imports execute the already-verified bytes in memory, including the driver's nested utility import, avoiding a second mutable source-file read for execution. Only `review`, `installed`, `normal_receipt`, `normal_job_passed`, fixed job helpers and independent libproc `processes_absent` are used. The cleanup module's cleanup entry is never called. Numeric1 is not accepted as a normal receipt boolean, and the original native observer is not invoked/coerced. Kernel observer rejects any existing PID (including reused identity) and any nonempty/incomplete/negative group observation; this does not prove arbitrary detached descendants absent.

Offline command:

```sh
/usr/bin/python3 -m unittest discover -s /private/tmp/kuro-root858-normal-retire-candidate -p test_retire.py -v
```

6 tests passed, including actual normal evidence shape and strict boolean rejection, exact mocked bootout/absent retry, failed/missing/wrong/live job status, process/installation rejection, changed evidence, failed bootout/postread and changed module pin. Fixtures include pinned public source modules/approval and only the nonsecret normal process/success fields. Tests redirect all installation paths or mock validators and every launchctl call; no real job, Core, root action or installed resource is touched. Real execution remains untested and separately authorized.
