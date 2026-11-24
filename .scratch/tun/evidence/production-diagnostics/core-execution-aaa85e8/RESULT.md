# Real non-TUN normal and EOF passed after shared capture integration

Source commit `aaa85e82376cd7a99009730a06c6cae8f231b21a`; both macOS and Windows [CI run 41977728604](https://github.com/coderhyy/clash-kuro/actions/runs/41977728604) completed successfully.

Frozen directory: `/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/core-control-experiment-aaa85e82376cd7a99009730a06c6cae8f231b21a`.

- Runner SHA256: `e85d6f9b8d41ab9bc0192b60a1b22d4f16c7d23f1054781ee53f76768ef6a3b6`.
- Inventory SHA256: `3e468529db99f87f820294d5ee95d75b5067ae929069ab8c813bfc2fda09a3ce`.
- Fixed Core v1.19.33 SHA256: `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`.
- Epoch: `62A5C7A2-373A-4785-9323-6DCBAFFDA544`.

Before execution, all six SHA256SUMS entries, four inventory entries (bytes/size/mode), 19 current source files and their exact Git blobs, Core pin and `--inspect` were verified. An independent reviewer repeated the offline artifact/source/config checks. The actual frozen signed runner passed its 212 harmless self-test assertions. The first external verification script incorrectly treated inventory's format/files object as an array; it stopped before inspect or Core execution. Correcting that reader allowed the complete checks to pass without changing any artifact.

Under the continuing ordinary-user non-TUN authorization, normal ran first and exited0. Actual version, mode and selector readbacks passed through the finite private Unix interface. The owner-stop request was acknowledged; requested SIGTERM produced actual Core exit0 with no terminating signal. Both captured streams reached EOF without a read error. Cache stayed on its precreated device/inode, owner and mode0600. Independent libproc checks observed ESRCH for Core50289 and worker50286, an empty process group50286, and absence of the entire dedicated runtime base. The same group enumeration method first confirmed the observer's own process was visible, avoiding treating a failed observation as absence.

Only after that complete independent gate, EOF ran and exited0. Its interface checks also passed, followed by owner-connection EOF without stop ACK. SIGTERM again produced actual Core exit0, both streams reached EOF, and same-origin cache checks passed. Independent libproc checks observed ESRCH for Core52845 and worker52844, group52844 empty, and the whole runtime base absent. No extra termination or deletion was needed.

Restricted original diagnostics remain `/private/tmp/kuro-core-evidence-cmOqVt` and `/private/tmp/kuro-core-evidence-AhFj5L` (directories0700, files0600/one link). Redacted configuration digests and complete capture summaries were independently checked. Curated copies, raw runner results, independent observation results and immutable build metadata are adjacent. The immutable artifact's execution booleans describe build time; this record documents the subsequent execution.

These are real ordinary-user Core results after capture/session changes. EOF means the test owner connection closed, not that an actual Electron App exited. Neither stage installed a service, ran root Core, enabled TUN/DNS/IP listeners, changed system proxy/routes/DNS/login items, or tested helper SIGKILL. Empty observed groups do not prove every possible detached descendant absent. Root launchd supervision, TUN data-plane/network cleanup and cross-helper recovery remain separate outstanding verification.
