# Stream/origin synchronization candidate

Only `apps/desktop/src/main/platform/mihomo.integration.test.ts` changes. Each stream now requires both its validated frame and a subsequent complete local HTTP200 response with exact body `local test origin`; its existing5-second deadline, traffic stimulus, teardown and strict assertions remain. A502 never satisfies the new gate. Restart still requires a newly completed response.

Evidence: evaluating the actual extracted closure against a held real loopback HTTP response deterministically fails baseline (resolves before body), while candidate passes. The second candidate fixture keeps a real502 pending until4999ms and rejects at5000ms. Differential:1 expected baseline failure+2 candidate passes. Candidate-only:2 passed. Main TypeScript check:exit0.

The evidence harness is temporary, not part of the one-file product patch. It controls stream transport delivery; it does not run actual Core or Windows. This proves the ordering defect and its local correction, not that every historical502 arose solely from scheduling. The collector10-second timeout has no demonstrated cause and is unchanged. Keep this patch separate from the current TUN candidate freeze.
