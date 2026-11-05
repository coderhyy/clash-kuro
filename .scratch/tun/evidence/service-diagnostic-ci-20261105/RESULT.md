# Diagnostic assertion input fix; separate startup uncertainty retained

CI run41985465733 at source7820a60 failed the exact invalid-frame diagnostic assertion. A controlled reproduction using credential prefix `e` made the actual harmless service pipeline write `invalid session frame or sequenc[REDACTED]`, while unexpected remained true. The existing fixture derives that prefix from its executable SHA suffix. The CI binary itself was not recovered, so its exact SHA suffix is not confirmed.

The narrow test-only fix uses prefix `!` only for scenario6. All seven other scenarios keep SHA-suffix credential stress. Exact error text, unexpected context, exact Core digest and secret-redaction assertions remain unchanged; production redaction is unchanged. Author strict compile and eight harmless service scenarios passed; independent non-author review approved this narrow fix. Patch SHA256 `88fe0015ac12d782a83b6aadc575730b3a52e7e7236861b715755fd9ecb12150`; original failure and candidate evidence `/private/tmp/kuro-service-diagnostic-ci-candidate`.

## Independent integration limitation (not resolved)

Main integrated focused test failed before scenario0 readiness, both inside and outside the sandbox. `/private/tmp/kuro-diag-service-CcEm26` records fixture stdout/stderr then exit97 (socket/bind/listen path). `/private/tmp/kuro-diag-service-5ThD2I` records zero output and supervisor TERM15 while the socket was not ready. These are different failures; the earlier sandbox attribution was withdrawn.

A single instrumented temporary build added entry/socket/bind/listen errno observations and passed all eight cases, so it did not capture the failing syscall errno. That pass does not explain or erase the failed original binary. Evidence stays in `/private/tmp/kuro-service-diagnostic-errno`, original integrated binary in `/private/tmp/kuro-service-diagnostic-integration`. No production timeout/validation was relaxed and no repeated trial was used to declare stability. Overall service integration stability remains unverified; the hash-dependent assertion fix is a separate proven improvement. No real Core, system job or network setting was used in these tests.
