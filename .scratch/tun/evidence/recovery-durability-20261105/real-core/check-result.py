import ctypes,errno,hashlib,json,os,stat,sys
from pathlib import Path
stage=sys.argv[1]
assert stage in ('normal','eof')
evidence=Path('/private/tmp/kuro-core-recovery-4a8c7ac')
r=json.loads((evidence/(stage+'.stdout.json')).read_text())
assert r['stage']==stage and r['status']=='passed' and r['groupAbsent'] is True
w=r['worker'];assert w['success'] is True and w['coreAbsent'] is True and w['ownerAbsent'] is True and w['workAbsent'] is True
assert w['termination']=={'exitCode':0,'observed':True,'request':'SIGTERM','signal':None}
assert w['stopProof']['acknowledged'] is (stage=='normal')
assert r['readback']['coreVersion']=='v1.19.33' and r['readback']['noIPReadbacks']==2
assert not w['diagnosticError']
assert w['stopProof']['trigger']==('owner-stop' if stage=='normal' else 'owner-eof')
assert w['error'] in (('',) if stage=='normal' else ('','session closed'))
lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
lib.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32];lib.proc_pidpath.restype=ctypes.c_int
lib.proc_listpids.argtypes=[ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_int];lib.proc_listpids.restype=ctypes.c_int
checks=[]
for pid in [r['coreIdentity']['pid'],r['coreIdentity']['processGroup']]:
 b=ctypes.create_string_buffer(4096);ctypes.set_errno(0);n=lib.proc_pidpath(pid,b,len(b));e=ctypes.get_errno();checks.append({'pid':pid,'proc_pidpath':n,'errno':e});assert n==0 and e==errno.ESRCH

def members(group):
 buf=(ctypes.c_int*4096)();n=lib.proc_listpids(2,group,buf,ctypes.sizeof(buf));assert 0<=n<ctypes.sizeof(buf) and n%4==0
 return [p for p in list(buf)[:n//4] if p>0]
assert os.getpid() in members(os.getpgrp())
group=members(r['coreIdentity']['processGroup']);assert not group
base=Path(r['base']);assert str(base).startswith('/private/tmp/kuro-core-') and not os.path.lexists(base)
d=Path(r['diagnosticsDirectory']);s=d.lstat();assert str(d).startswith('/private/tmp/kuro-core-evidence-') and stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode)==0o700 and s.st_uid==os.getuid()
for name in ['config.redacted.json','launch.json','stdout.log','stderr.log','diagnostics.json','cache-precreation.json']:
 f=d/name;s=f.lstat();assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1 and s.st_uid==os.getuid()
x=json.loads((d/'diagnostics.json').read_text());assert not x['diagnosticError'] and x['failureStage'] is None and x['termination']==w['termination']
assert hashlib.sha256((d/'config.redacted.json').read_bytes()).hexdigest()==x['redactedConfigSHA256']
for stream in ('stdout','stderr'):
 c=x['capture'][stream];assert c['eof'] is True and c['readErrno']==0 and c['retainedBytes']<=65536
 assert (d/(stream+'.log')).stat().st_size==c['retainedBytes']
c=json.loads((d/'cache-precreation.json').read_text());assert all(c[k] is True for k in ['reaped','sameInode','sameMode','sameOwner']) and not c['error']
result={'stage':stage,'processChecks':checks,'processGroupMembers':group,'runtimeBaseAbsent':True,'diagnosticsDirectory':str(d),'diagnosticsProtected':True,'diagnosticsComplete':True,'cacheOriginPreserved':True,'passed':True}
(evidence/(stage+'-independent.json')).write_text(json.dumps(result,indent=2))
print(json.dumps(result))
