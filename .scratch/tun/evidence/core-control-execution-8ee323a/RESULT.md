# Non-TUN Core experiment — normal failed; EOF not executed

Authorized source 8ee323a48da5729217a0f730d4de850da867f0d9; exact artifact path and hashes in artifact.json. Preflight: UID501, all six SHA256SUMS entries passed, explicit runner/inventory/Core hashes matched, inventory modes/size/owner matched, no prior attempt/result/success. --inspect prepared / normalPassed:false and matching epoch.

One --normal invocation only. Runner exit2. Core stdout (118 bytes):

    time="2026-11-05T10:32:20.614955000+08:00" level=fatal msg="Parse config error: yaml: found unknown escape character"

Core stderr empty. Core termination observed, exit1, signal:null, request:none. Failure stage private-version-readiness; no API ready, finite operation readbacks or normal stop success. DiagnosticError empty; both streams EOF/readErrno0, no truncation. Specific offending escape not established by this execution; preserved redacted config contains escaped slash sequences, which is an offline investigation lead, not a proven causal byte. No config change, rebuild, retry, -t or EOF performed.

Guardian reports groupAbsent:true and Core/owner/work absent. Independent proc_pidinfo for Core21629 and worker/group anchor21628 returned0/ESRCH. Exact runtime base /private/tmp/kuro-core-bkpsAy is0700/UID501 and retains only fixed mihomo (matching authorized digest), per failure evidence policy. No owner.json/session-work/config/socket remains. This readback does not prove absence of all possible detached descendants.

Independent diagnostics /private/tmp/kuro-core-evidence-pUMvdX is0700/UID501 with all five regular nonsymlink files0600: redacted config, launch metadata, stdout, stderr, diagnostics. These and stage result/manifests are copied here; residual-readback.json records modes/hashes/process query. Logs retained intentionally. No installation, service or login/system network mutation was performed. No additional signaling or deletion was necessary or attempted.

This authorization ends after this failure and residual audit. Next smallest work is offline verification of config serialization against the fixed YAML parser, followed by a new candidate and separate authorization; no launch/configuration cause beyond the observed parser error is asserted.
