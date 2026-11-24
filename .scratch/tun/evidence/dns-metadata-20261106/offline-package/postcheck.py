from pathlib import Path
import subprocess,xml.etree.ElementTree as ET,json,struct,hashlib,re
r=Path('/private/tmp/kuro-offline-package-432d134b8ecd');src=Path('/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro');e=r/'expanded';p=e/'Payload';i=p/'Library/Application Support/Clash Kuro/Privileged/Inbox';m=json.loads((r/'package.json').read_text());v=json.loads((r/'verification.json').read_text());manifest=json.loads((i/'manifest.json').read_text());commit='432d134b8ecd244483126795be850b64782c2209'
hash=lambda b:hashlib.sha256(b).hexdigest()
lock=json.loads(subprocess.check_output(['git','show',commit+':apps/desktop/core.lock.json'],cwd=src));assert lock['mihomo']['version']==manifest['core']['version'];assert lock['mihomo']['targets'][m['target']]['sha256']==manifest['core']['archiveSha256']
b=subprocess.check_output(['/usr/bin/lsbom','-p','fmug',str(e/'Bom')],text=True);(r/'bom.txt').write_text(b);rows=[x.split('\t') for x in b.splitlines()];assert all(len(x)==4 and x[2]=='0' and x[3]=='0' for x in rows);assert all(x[0]=='.' or x[0].startswith('./Library') or x[0]=='./._Library' for x in rows);assert not any('TunDiagnostics' in x[0] or '/Upgrade/' in x[0] or '/LaunchDaemons/' in x[0] for x in rows)
xml=ET.parse(e/'PackageInfo').getroot();assert xml.attrib['identifier']=='dev.kuro.tun.disabled';assert xml.attrib['install-location']=='/' and xml.attrib['relocatable']=='false' and xml.attrib['auth']=='root';assert len(xml.find('relocate'))==0 and len(xml.find('bundle-version'))==0;bundles=xml.findall('bundle');strict={x.attrib['id'] for x in xml.find('strict-identifier')};assert len(bundles)==9 and all(x.attrib['path'].startswith('./Library/Application Support/Clash Kuro/Client/Clash Kuro.app') and x.attrib['id'] in strict for x in bundles)
for name in ['helper','mihomo']:
 magic,cpu=struct.unpack('<II',(i/name).read_bytes()[:8]);assert magic==0xfeedfacf and cpu==0x100000c
 result=subprocess.run(['/usr/bin/codesign','--verify','--strict',str(i/name)],capture_output=True,text=True);assert result.returncode==0,result.stderr
 result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(i/name)],capture_output=True,text=True);(r/f'{name}-codesign.txt').write_text(result.stdout+result.stderr);assert result.returncode==0
for name in ['Library','Library/Application Support','Library/Application Support/Clash Kuro','Library/PrivilegedHelperTools']:assert (p/name).stat().st_mode&0o777==0o755
pkg=src/'apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-432d134b8ecd.pkg';actual=hash(pkg.read_bytes());assert actual==m['packageSHA256'];assert m['productionActivation'] is True and m['startAvailable'] is True and m['realTunAccepted'] is False
result=subprocess.run(['/usr/sbin/pkgutil','--check-signature',str(pkg)],capture_output=True,text=True);(r/'package-signature.txt').write_text(result.stdout+result.stderr);assert 'no signature' in (result.stdout+result.stderr).lower()
source_paths=['apps/desktop/native/mac/tun-session.m','apps/desktop/native/mac/tun-service.m','apps/desktop/native/mac/tun-install.m','apps/desktop/native/mac/tun-production-network.m','apps/desktop/native/mac/kuro-tun-helper.m','apps/desktop/native/mac/tun-network.m','apps/desktop/native/mac/tun-routes.m','apps/desktop/scripts/package-macos-helper.mjs','apps/desktop/scripts/macos-client-pin.mjs','apps/desktop/scripts/build-macos-helper.mjs','apps/desktop/src/main/index.ts','apps/desktop/src/main/runtime-verification.ts']
pending=['apps/desktop/native/mac/kuro-tun-helper.m'];discovered=set()
while pending:
 path=pending.pop()
 if path in discovered:continue
 discovered.add(path)
 for name in re.findall(r'#(?:import|include) \"([^\"]+)\"',(src/path).read_text()):
  relative=str(Path(path).parent/name)
  if (src/relative).is_file() and relative.endswith(('.m','.h')):pending.append(relative)
source_paths=sorted(set(source_paths)|discovered)
sources={}
for path in source_paths:
 original=subprocess.check_output(['git','show',commit+':'+path],cwd=src);present=(src/path).read_bytes();assert original==present,path;sources[path]=hash(original)
helper=(i/'helper').read_bytes();needles=['installation','freshReceiptSHA256','runtimeSHA256','cacheOrigin','cacheCheckpoint','validated-restart-v1','recorded work directory was replaced or reappeared; preserve all objects','origin-only cache requires an explicit installed writer validator; preserve work','supervision installation manifest/receipt/helper/Core binding failed','old writer is not bound to this exact protected fixed-Core installation/runtime/cache origin','/Library/Application Support/Clash Kuro/TunDiagnostics']
for marker in needles:assert marker.encode() in helper,marker
(r/'source-and-field-checks.json').write_text(json.dumps({'sourceCommit':commit,'sourceFiles':sources,'embeddedNativeFields':needles,'doesNotProveReproducibleBuild':True},indent=2))
v.update({'packageBytes':pkg.stat().st_size,'packageMetadataSHA256':hash(Path(str(pkg)+'.json').read_bytes()),'actualPackageSHA256':actual,'bomEntries':len(rows),'bomAllIntendedUID':0,'bomAllIntendedGID':0,'fixedBundleCount':len(bundles),'relocatable':False,'packageSignature':'unsigned (expected local candidate)','machoArchitecture':'arm64 helper and Core','archivePinMatchesCommittedCoreLock':True,'sourceCommitFilesMatch':sources,'nativeEmbeddedClosedFieldsPresent':needles,'scriptsExecuted':False,'diagnosticsPayloadEntries':0,'status':'no offline blocker'})
(r/'verification.json').write_text(json.dumps(v,indent=2));print(json.dumps({k:v[k] for k in ['status','sourceCommit','actualPackageSHA256','packageMetadataSHA256','bomEntries','fixedBundleCount','inventoryEntries','client']},indent=2))
