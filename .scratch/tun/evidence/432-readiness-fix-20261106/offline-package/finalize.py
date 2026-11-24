from pathlib import Path
import os,json,subprocess,hashlib,gzip,shutil
src=Path('/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro');r=Path('/private/tmp/kuro-offline-package-7c3511f1193d');commit='7c3511f1193df258fb123b0fc9eef844b0a3cef7';h=lambda b:hashlib.sha256(b).hexdigest()
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=src,text=True).strip()==commit
assert not subprocess.check_output(['git','status','--porcelain','--untracked-files=all','--','apps/desktop','packages'],cwd=src).strip()
files={}
for entry in subprocess.check_output(['git','ls-tree','-r','-z',commit,'--','apps/desktop','packages'],cwd=src).split(b'\0'):
 if not entry:continue
 metadata,name=entry.split(b'\t',1);mode,kind,digest=metadata.split();assert kind==b'blob';path=name.decode();f=src/path
 data=os.readlink(f).encode() if mode==b'120000' else f.read_bytes();assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==digest.decode(),path
 files[path]=h(data)
lock=json.loads((src/'apps/desktop/core.lock.json').read_text());pin=lock['mihomo']['targets']['darwin-arm64']['sha256'];archive=(src/'apps/desktop/resources/.cache'/pin).read_bytes();assert h(archive)==pin
exe=h(gzip.decompress(archive));v=json.loads((r/'verification.json').read_text());assert exe==v['coreSHA256']
helperlock=json.loads((src/'apps/desktop/native/mac/helper.lock.json').read_text());assert helperlock['targets']['darwin-arm64']['sha256']==v['helperSHA256']
base=src/'.scratch/tun/evidence/432-readiness-fix-20261106';logpath=Path('/private/tmp/kuro-7c3511f-native.log');buildlog=logpath.read_text();assert 'PASS native JSON candidate accepted by fixed Core -t' in buildlog
assert 'Tests  7 passed | 4 skipped' in buildlog and 'PASS 94 assertions' in buildlog and '102 deterministic' in buildlog
native=json.loads((src/'apps/desktop/resources/mac/arm64/kuro-tun-helper.build.json').read_text());assert native['tests'] and not native['coreSyntaxSkipped']
applog=Path('/private/tmp/kuro-7c3511f-app.log');assert 'vite v' in applog.read_text()
proof={'status':'passed','sourceCommit':commit,'checkedTrackedSourceFiles':len(files),'sourceDirectories':['apps/desktop','packages'],'currentTrackedAndUntrackedSourceClean':True,'committedBlobMatches':files,'coreArchiveSHA256':pin,'decompressedArchiveSHA256':exe,'privilegedCoreMatchesCachedLockedArchive':True,'helperLockMatchesActualHelper':True,'nativeBuildTests':True,'nativeBuildCoreSyntaxSkipped':False,'appBuildLogPath':str(applog),'appBuildLogSHA256':h(applog.read_bytes()),'buildLogPath':str(logpath),'buildLogSHA256':h(logpath.read_bytes()),'buildLogObserved':['fixed Core -t syntax passed (build log only; reviewer did not run Core)','7/7 explicitly invoked native/client admission chains passed','102 deterministic upgrade interruptions passed','94 output assertions passed'],'notReproducibleBuildClaim':True}
(r/'source-build-provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
v.update({'sourceTrackedFilesMatched':len(files),'sourceCurrentClean':True,'privilegedCoreEqualsCachedLockedArchive':True,'helperLockMatchesActualHelper':True,'appBundleEqualsOriginalBuildInventory':True,'compiledOutMatchesExtractedASAR':True,'offlineReviewerRanCore':False,'offlineReviewerInstalledOrLaunched':False,'ci':{'status':'CI pending primary verification; offline reviewer did not query CI'}})
(r/'verification.json').write_text(json.dumps(v,indent=2)+'\n')
result=f'''# 7c3511f1193d offline package review

**Passed: no offline package blocker found.** CI is independently tracked by the primary session; this review does not mark CI complete.

- Source: `{commit}`; all {len(files)} tracked files under `apps/desktop` and `packages` match committed blobs; those source directories are clean.
- Package SHA256: `{v['actualPackageSHA256']}`; package metadata SHA256 `{v['packageMetadataSHA256']}`.
- Helper SHA256: `{v['helperSHA256']}`; actual Inbox/preflight/installer/recovery copies, generated helper lock and native build record agree.
- Privileged Core SHA256: `{exe}` equals decompressed cached archive SHA256 `{pin}` from committed Core lock. Reviewer did not execute Core.
- App CDHash: `{v['client']['cdhash']}`; source/candidate mode in sealed ASAR, actual executable/Info/ASAR pins and {v['inventoryEntries']}-entry client inventory agree with manifest, sidecars and original signed App build. Five compiled output files exactly match extracted ASAR.
- App seal/runtime/entitlements/fuses/ASAR static verifier passes. Native/App build records bind this commit, sourceClean and actual hashes. Native tests=true/coreSyntaxSkipped=false; existing clean build log records fixed Core syntax, seven admission chains, 102 upgrade interruptions and 94 output assertions; reviewer only read results.
- Native binary includes the fixed `SKIP_SYSTEM_IPV6_CHECK=true` literal and matches the source/build identity; expanded ASAR compiled entry matches the new open-only 15s response budget. These static checks do not prove real IPv6 utun creation or startup success.
- Fixed fresh scripts and protocol2/manifest/client bindings agree. Plist Disabled=true, RunAtLoad=false, KeepAlive=false, AbandonProcessGroup=false, release length {v['releaseLength']}, exact program path {v['programPathBytes']} bytes. Metadata disabled/serviceAutoStart=false means no service autostart; startAvailable/productionActivation=true permit only authenticated admitted finite sessions, not automatic activation.
- BOM has {v['bomEntries']} entries with intended root:wheel metadata and nine fixed nonrelocatable bundles. Shared ancestors0755, Privileged/Inbox0700, Inbox metadata0600/executables0755. No preinstalled launchd job or diagnostic payload. Native uninstall retention message is present; sibling TunDiagnostics is preserved by source exact-target cleanup.

App-bundled ordinary Core is Electron re-signed; it matches original App inventory and is distinguished from privileged Inbox Core's upstream archive hash. The package is locally unsigned/ad-hoc as specified; no Developer ID/notarization claim. BOM ownership is intended metadata, not installed-filesystem proof. No App/helper/Core or installer script was executed, no install/job/network changes occurred. This result does not establish real startup authorization, TUN, writer-exit, network recovery, runtime uninstall or upgrade acceptance. Full expanded App/raw machine network data are not archived in repository evidence.
'''
(r/'RESULT.md').write_text(result)
dest=base/'offline-package';dest.mkdir(mode=0o700,exist_ok=False)
names=['RESULT.md','verification.json','source-and-field-checks.json','source-build-provenance.json','asar-and-build-check.json','commands.json','verify.mjs','postcheck.py','extra-check.mjs','finalize.py','verify.stdout.log','verify.stderr.log','postcheck.stdout.log','postcheck.stderr.log','extra-check.stdout.log','extra-check.stderr.log','expand.stdout.log','expand.stderr.log','package-signature.txt','helper-codesign.txt','mihomo-codesign.txt']
for name in names:shutil.copyfile(r/name,dest/name);os.chmod(dest/name,0o600)
checks={name:h((dest/name).read_bytes()) for name in names};(dest/'SHA256SUMS').write_text(''.join(f'{sha}  {name}\n' for name,sha in sorted(checks.items())));os.chmod(dest/'SHA256SUMS',0o600)
print(json.dumps({'status':'passed','evidence':str(dest),'sourceFiles':len(files),'packageSHA256':v['actualPackageSHA256'],'verificationSHA256':checks['verification.json'],'resultSHA256':checks['RESULT.md'],'sha256Sums':h((dest/'SHA256SUMS').read_bytes())},indent=2))
