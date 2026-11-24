from pathlib import Path
import hashlib,json
r=Path('/private/tmp/kuro-offline-package-dd3f0d4fc277');src=Path('/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro');h=lambda b:hashlib.sha256(b).hexdigest()
checks={}
for name,candidate in [('tun-routes.m','kuro-route-observed-flags-candidate'),('tun-production-network.m','kuro-dns-probe-diagnostics-candidate'),('tun-production-network.test.m','kuro-dns-probe-diagnostics-candidate')]:
 actual=(src/'apps/desktop/native/mac'/name).read_bytes();reviewed=(Path('/private/tmp')/candidate/'native'/name).read_bytes();assert actual==reviewed,name;checks[name]={'sha256':h(actual),'matchesReviewedCandidate':candidate}
helper=(r/'expanded/Payload/Library/Application Support/Clash Kuro/Privileged/Inbox/helper').read_bytes()
markers=['fixed internal IPv%@ DNS static-host probe was not confirmed; stage=%@; elapsedMs=%llu; errno=%d; poll=%d; revents=0x%x; sent=%lld/%lu; received=%lld; header=%@; reason=%@','setsockopt-bound-interface','fcntl-getfl','response-validation','fixed-answer-record-or-address','oversized-datagram','short-header']
for marker in markers:assert marker.encode() in helper,marker
result={'sourceCommit':'dd3f0d4fc27796abfd1bcc633e842018a867d9c5','checks':checks,'nativeDiagnosticLiterals':markers,'reviewedPatchSHA256':'b086a902f63fbe9f501dd4f9fca79863ceb17864f65236c8efff31acc2dcb55a','scope':'exact source and static build identity; no real probe, no new network/admission/recovery authority'}
(r/'diagnostic-source-identity.json').write_text(json.dumps(result,indent=2)+'\n');v=json.loads((r/'verification.json').read_text());v['diagnosticSourcesMatchReviewedCandidates']=result;(r/'verification.json').write_text(json.dumps(v,indent=2)+'\n')
report=(r/'RESULT.md').read_text();report=report.replace('- Actual helper contains the diagnostic-only unexpected-route literal.', '- Actual helper contains the newly reviewed bounded DNS failure-stage/errno diagnostic literals. Its source and test are byte-identical to independently reviewed `b086a902…`, preserving the original exact response validator, 400ms budget, endpoints and options. No real probe was executed.\n- Actual helper contains the diagnostic-only unexpected-route literal.')
(r/'RESULT.md').write_text(report)
print('bounded DNS diagnostic source and actual helper literals PASS')
