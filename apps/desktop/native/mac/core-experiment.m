// Explicit ordinary-user experiment. Never linked as a privileged entry point.
#ifndef KURO_CORE_EXPERIMENT
#error core-experiment requires KURO_CORE_EXPERIMENT
#endif
#ifndef KURO_EXPERIMENT_CORE_SHA256
#error build must pin the verified unpacked Core hash
#endif
#ifndef KURO_EXPERIMENT_ARCHIVE_SHA256
#error build must pin the verified Core archive hash
#endif
#import "kuro-tun-helper.m"
#include <sys/proc.h>

static NSString *const ExperimentCorePin=@KURO_EXPERIMENT_CORE_SHA256;
static NSString *const ExperimentArchivePin=@KURO_EXPERIMENT_ARCHIVE_SHA256;
static NSString *const ExperimentGroup=@"Kuro-Experiment";
static volatile sig_atomic_t ExperimentCancelled=0;
static void ExperimentCancel(int value) { (void)value;ExperimentCancelled=1; }
static NSArray *ExperimentGroups(void) { return @[@{@"name":ExperimentGroup,@"type":@"select",@"proxies":@[@"DIRECT",@"REJECT"]}]; }
static NSDictionary *ExperimentConfig(NSString *socketPath,NSString *secret) {
  return @{@"mode":@"direct",@"allow-lan":@NO,@"bind-address":@"127.0.0.1",@"ipv6":@NO,@"log-level":@"warning",
    @"port":@0,@"socks-port":@0,@"mixed-port":@0,@"redir-port":@0,@"tproxy-port":@0,
    @"external-controller":@"",@"external-controller-tls":@"",@"external-controller-pipe":@"",@"external-controller-unix":socketPath,@"secret":secret,
    @"external-ui":@"",@"external-ui-url":@"",@"listeners":@[],@"tunnels":@[],@"proxies":@[],@"proxy-groups":ExperimentGroups(),@"rules":@[@"MATCH,DIRECT"],@"proxy-providers":@{},@"rule-providers":@{},
    @"geo-auto-update":@NO,@"find-process-mode":@"off",@"profile":@{@"store-selected":@NO,@"store-fake-ip":@NO},
    @"tun":@{@"enable":@NO,@"auto-route":@NO,@"auto-detect-interface":@NO,@"dns-hijack":@[]},
    @"dns":@{@"enable":@NO,@"listen":@"",@"nameserver":@[],@"default-nameserver":@[@"127.0.0.1"],@"proxy-server-nameserver":@[],@"direct-nameserver":@[],@"fallback":@[],@"nameserver-policy":@{},@"proxy-server-nameserver-policy":@{},@"use-system-hosts":@NO,@"enhanced-mode":@"redir-host",@"fallback-filter":@{@"geoip":@NO,@"geosite":@[]}},
    @"ntp":@{@"enable":@NO,@"write-to-system":@NO},@"sniffer":@{@"enable":@NO},@"iptables":@{@"enable":@NO},@"tuic-server":@{@"enable":@NO}};
}
static NSString *ExperimentReview(void) { return Executable().stringByDeletingLastPathComponent; }
static NSDictionary *ExperimentManifest(NSString **error) {
  NSString *review=ExperimentReview();
  if(geteuid()==0 || !SafeNode(review,geteuid(),YES,error)) { Fail(error,@"experiment requires a protected ordinary-user review directory");return nil; }
  NSDictionary *value=ReadJSON(review,[review stringByAppendingPathComponent:@"experiment.json"],geteuid(),error);
#if defined(__arm64__)
  NSString *target=@"darwin-arm64";
#else
  NSString *target=@"darwin-x64";
#endif
  if(!Keys(value,@[@"format",@"protocol",@"target",@"coreVersion",@"coreSHA256",@"coreArchiveSHA256",@"runnerSHA256",@"epoch"]) || !KuroNumber(value[@"format"],1,1) || !KuroNumber(value[@"protocol"],1,1) || ![value[@"target"]isEqual:target] || ![value[@"coreVersion"]isEqual:@"v1.19.33"] || ![value[@"coreSHA256"]isEqual:ExperimentCorePin] || ![value[@"coreArchiveSHA256"]isEqual:ExperimentArchivePin] || !Match(value[@"runnerSHA256"],@"\\A[0-9a-f]{64}\\z") || ![value[@"epoch"]isKindOfClass:NSString.class]) { Fail(error,@"fixed experiment receipt does not match compiled Core pins");return nil; }
  NSUUID *epoch=[[NSUUID alloc]initWithUUIDString:value[@"epoch"]];
  NSData *runner=ReadProtected(review,Executable(),geteuid(),error),*core=ReadProtected(review,[review stringByAppendingPathComponent:@"mihomo"],geteuid(),error);
  if(!epoch || ![epoch.UUIDString isEqual:value[@"epoch"]] || !runner || !core || !MachExecutable(core) || ![Hash(runner)isEqual:value[@"runnerSHA256"]] || ![Hash(core)isEqual:ExperimentCorePin]) { Fail(error,@"experiment artifact bytes or epoch changed");return nil; }
  return value;
}
static NSDictionary *ExperimentIdentity(pid_t pid,pid_t parent,pid_t group,NSString **error) {
  struct proc_bsdinfo info={0};
  int observed=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info));
  if(observed!=sizeof(info) || info.pbi_pid!=(uint32_t)pid || info.pbi_uid!=geteuid() || (parent>0 && info.pbi_ppid!=(uint32_t)parent) || info.pbi_pgid!=(uint32_t)group) { Fail(error,[NSString stringWithFormat:@"direct identity unavailable pid=%d read=%d errno=%d uid=%u parent=%u expected=%d group=%u expected=%d",pid,observed,errno,info.pbi_uid,info.pbi_ppid,parent,info.pbi_pgid,group]);return nil; }
  return @{@"pid":@(pid),@"startSeconds":@(info.pbi_start_tvsec),@"startMicros":@(info.pbi_start_tvusec),@"processGroup":@(group)};
}
static BOOL ExperimentSame(NSDictionary *expected,pid_t parent,NSString **error) {
  return expected && [ExperimentIdentity([expected[@"pid"]intValue],parent,[expected[@"processGroup"]intValue],error)isEqual:expected];
}
static BOOL ExperimentAbsent(NSDictionary *identity) {
  struct proc_bsdinfo info={0};errno=0;
  return proc_pidinfo([identity[@"pid"]intValue],PROC_PIDTBSDINFO,0,&info,sizeof(info))==0&&errno==ESRCH;
}
static BOOL ExperimentNoIP(NSDictionary *identity,NSString **error) {
  if(!ExperimentSame(identity,getpid(),error))return NO;
  struct proc_fdinfo descriptors[1024];
  int used=proc_pidinfo([identity[@"pid"]intValue],PROC_PIDLISTFDS,0,descriptors,sizeof(descriptors));
  if(used<=0 || used>=(int)sizeof(descriptors) || used%(int)sizeof(*descriptors))return Fail(error,@"Core FD readback is unavailable or incomplete");
  for(NSUInteger i=0;i<(NSUInteger)used/sizeof(*descriptors);i++)if(descriptors[i].proc_fdtype==PROX_FDTYPE_SOCKET) {
    struct socket_fdinfo socketInfo={0};
    if(proc_pidfdinfo([identity[@"pid"]intValue],descriptors[i].proc_fd,PROC_PIDFDSOCKETINFO,&socketInfo,sizeof(socketInfo))!=sizeof(socketInfo))return Fail(error,@"Core socket FD raced or could not be inspected");
    if(socketInfo.psi.soi_family==AF_INET || socketInfo.psi.soi_family==AF_INET6 || socketInfo.psi.soi_family==AF_SYSTEM)return Fail(error,@"Core has an IP or kernel-control socket; non-TUN experiment refused");
  }
  return ExperimentSame(identity,getpid(),error);
}
static BOOL ExperimentSend(int fd,NSDictionary *value) {
  NSMutableData *data=[JSONData(value)mutableCopy];[data appendBytes:"\n" length:1];
  return data.length<=MessageLimit&&send(fd,data.bytes,data.length,MSG_NOSIGNAL|MSG_DONTWAIT)==(ssize_t)data.length;
}
static NSDictionary *ExperimentRead(int fd,uint64_t deadline,NSString **error) {
  NSMutableData *data=[NSMutableData data];
  while(data.length<=MessageLimit && KuroMonotonicMilliseconds()<deadline) {
    struct pollfd ready={.fd=fd,.events=POLLIN};int count=poll(&ready,1,50);
    if(count<0&&errno==EINTR)continue;if(count<0)return nil;if(!count)continue;
    unsigned char byte;ssize_t got=recv(fd,&byte,1,MSG_DONTWAIT);
    if(got<0&&(errno==EAGAIN||errno==EINTR))continue;if(got<=0)return nil;
    if(byte=='\n') { id value=KuroDecodeJSON(data,MessageLimit,error);return [value isKindOfClass:NSDictionary.class]?value:nil; }
    [data appendBytes:&byte length:1];
  }
  Fail(error,@"bounded experiment peer frame deadline exceeded");return nil;
}
static NSArray *ExperimentInventory(NSString *base) {
  NSMutableArray *result=[NSMutableArray array];
  for(NSString *name in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:base error:NULL]) {
    NSString *path=[base stringByAppendingPathComponent:name];struct stat info={0};
    if(lstat(path.fileSystemRepresentation,&info)) { [result addObject:@{@"name":name,@"type":@"unobservable"}];continue; }
    [result addObject:@{@"name":name,@"type":S_ISDIR(info.st_mode)?@"directory":S_ISREG(info.st_mode)?@"file":S_ISSOCK(info.st_mode)?@"socket":@"other",@"mode":@(info.st_mode&07777),@"size":@(info.st_size)}];
    if([name isEqual:@"session-work"])for(NSString *child in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:path error:NULL]) [result addObject:@{@"name":[name stringByAppendingPathComponent:child],@"type":@"retained-work-entry"}];
  }
  return result;
}
static BOOL ExperimentRemoveWork(NSString *base,NSString *digest,NSDictionary *socketIdentity,NSString **error) {
  NSString *work=[base stringByAppendingPathComponent:@"session-work"],*config=[work stringByAppendingPathComponent:@"config.json"],*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
  if(!SafeChain(base,work,geteuid(),YES,error))return NO;
  NSArray *names=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:work error:NULL];if(!names)return Fail(error,@"work inventory unavailable");
  for(NSString *name in names)if(![@[@"config.json",@"core.sock"]containsObject:name])return Fail(error,@"unknown Core work file preserved; manual review required");
  if(Exists(config)&&![Hash(ReadProtected(base,config,geteuid(),error))isEqual:digest])return Fail(error,@"Core config identity changed; work preserved");
  struct stat socketInfo={0};
  if(Exists(socketPath) && (!socketIdentity || lstat(socketPath.fileSystemRepresentation,&socketInfo) || !S_ISSOCK(socketInfo.st_mode) || socketInfo.st_uid!=geteuid() || (unsigned long long)socketInfo.st_dev!=[socketIdentity[@"device"]unsignedLongLongValue] || socketInfo.st_ino!=[socketIdentity[@"inode"]unsignedLongLongValue]))return Fail(error,@"Core socket identity not proven; work preserved");
  if(Exists(config)&&unlink(config.fileSystemRepresentation))return NO;
  if(Exists(socketPath)&&unlink(socketPath.fileSystemRepresentation))return NO;
  return !rmdir(work.fileSystemRepresentation)||Fail(error,@"Core work directory removal not proven");
}
static NSDictionary *ExperimentFixtureManifest(void) {
  return @{@"epoch":@"00000000-0000-4000-8000-000000000001",@"coreSHA256":Hash([NSData dataWithContentsOfFile:Executable()]),@"runnerSHA256":Hash([NSData dataWithContentsOfFile:Executable()])};
}
static int ExperimentWorker(BOOL fixture) {
  if(geteuid()==0 || getpgrp()!=getpid())return 90;
  NSString *error=nil;pid_t parent=getppid();
  KuroPeerIdentity *peer=[KuroPeerIdentity observePeer:3 error:&error];
  char parentPath[PROC_PIDPATHINFO_MAXSIZE]={0};
  if(!peer || proc_pidpath(parent,parentPath,sizeof(parentPath))<=0 || ![Executable()isEqual:@(parentPath)])return 91;
  NSDictionary *launch=ExperimentRead(3,KuroMonotonicMilliseconds()+2000,&error);
  NSDictionary *manifest=fixture?ExperimentFixtureManifest():ExperimentManifest(&error);
  if(!manifest || !Keys(launch,@[@"format",@"stage",@"epoch",@"base"]) || !KuroNumber(launch[@"format"],1,1) || !([@[@"normal",@"eof"]containsObject:launch[@"stage"]] || (fixture&&[launch[@"stage"]isEqual:@"fixture-worker-exit"])) || ![launch[@"epoch"]isEqual:manifest[@"epoch"]] || ![launch[@"base"]isKindOfClass:NSString.class])return 92;
  NSString *base=launch[@"base"];char canonical[PATH_MAX];
  if(![base hasPrefix:@"/private/tmp/kuro-core-"] || !realpath(base.fileSystemRepresentation,canonical) || ![base isEqual:@(canonical)] || !SafeNode(base,geteuid(),YES,&error))return 93;
  NSArray *initial=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:base error:NULL];
  if(![[NSSet setWithArray:initial?:@[]] isEqual:[NSSet setWithObject:@"mihomo"]])return 94;
  NSString *core=[base stringByAppendingPathComponent:@"mihomo"],*work=[base stringByAppendingPathComponent:@"session-work"],*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
  NSData *coreBytes=ReadProtected(base,core,geteuid(),&error);
  if(!coreBytes || ![Hash(coreBytes)isEqual:manifest[@"coreSHA256"]])return 95;
  NSString *secret=NSUUID.UUID.UUIDString;NSData *config=JSONData(ExperimentConfig(socketPath,secret));NSString *digest=Hash(config);
  if(mkdir(work.fileSystemRepresentation,0700) || !WriteNew([work stringByAppendingPathComponent:@"config.json"],config,0600,&error))return 96;
  KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:base owner:geteuid()];
  __block NSDictionary *socketIdentity=nil;NSDictionary *identity=nil;id version=nil;BOOL success=NO,spawned=NO;
  if(![session setLaunchEvidence:@{@"configSHA256":digest,@"coreSHA256":manifest[@"coreSHA256"],@"template":@"core-control-experiment-v1"} error:&error])return 97;
  spawned=[session spawnExecutable:core arguments:@[@"-d",work,@"-f",[work stringByAppendingPathComponent:@"config.json"]] workingDirectory:work beforeResume:^BOOL(NSString **failure) {
    return peer.isLive && getppid()==parent && SafeChain(base,work,geteuid(),YES,failure);
  } afterReap:^BOOL(NSString **failure) { return ExperimentRemoveWork(base,digest,socketIdentity,failure); } error:&error];
  if(spawned) {
    identity=ExperimentIdentity(session.child,getpid(),getpgrp(),&error);
    if(!ExperimentSend(3,@{@"event":@"spawned",@"identity":identity?:@{},@"session":session.identifier}))goto finish;
    KuroSessionHook verify=^BOOL(NSString **failure) {
      if(!ExperimentSame(identity,getpid(),failure) || !SafeChain(base,work,geteuid(),YES,failure))return NO;
      struct stat info={0};if(lstat(socketPath.fileSystemRepresentation,&info)||!S_ISSOCK(info.st_mode)||info.st_uid!=geteuid()||info.st_nlink!=1)return Fail(failure,@"private Core socket not ready");
      NSDictionary *observed=@{@"device":@((uint64_t)info.st_dev),@"inode":@(info.st_ino)};
      if(socketIdentity)return [socketIdentity isEqual:observed]||Fail(failure,@"private Core socket changed");
      if(![session recordWorkSocket:observed error:failure])return NO;socketIdentity=observed;return YES;
    };
    uint64_t deadline=KuroMonotonicMilliseconds()+3000;
    do { error=nil;version=KuroCoreControlRequest(socketPath,secret,ExperimentGroups(),verify,@{@"operation":@"version"},&error);if(version)break;usleep(10000); }while(KuroMonotonicMilliseconds()<deadline&&peer.isLive);
    if(!version || !ExperimentNoIP(identity,&error))goto finish;
    for(NSString *mode in @[@"rule",@"direct"]) {
      if(!KuroCoreControlRequest(socketPath,secret,ExperimentGroups(),verify,@{@"operation":@"mode",@"mode":mode},&error) || ![KuroCoreControlRequest(socketPath,secret,ExperimentGroups(),verify,@{@"operation":@"readMode"},&error)[@"mode"]isEqual:mode])goto finish;
    }
    for(NSString *selection in @[@"REJECT",@"DIRECT"]) {
      if(!KuroCoreControlRequest(socketPath,secret,ExperimentGroups(),verify,@{@"operation":@"select",@"group":ExperimentGroup,@"proxy":selection},&error) || ![KuroCoreControlRequest(socketPath,secret,ExperimentGroups(),verify,@{@"operation":@"readSelection",@"group":ExperimentGroup},&error)[@"now"]isEqual:selection])goto finish;
    }
    if(!ExperimentNoIP(identity,&error) || !ExperimentSend(3,@{@"event":@"ready",@"session":session.identifier,@"configSHA256":digest,@"coreVersion":version[@"version"],@"noIPReadbacks":@2}))goto finish;
    if(fixture&&[launch[@"stage"]isEqual:@"fixture-worker-exit"])_exit(73);
    success=[session superviseSocket:3 leaseMilliseconds:5000 identityValid:^BOOL {return peer.isLive&&getppid()==parent;} error:&error];
  }
finish:
  if(!session.off) { NSString *stopError=nil;if(![session stop:&stopError])error=stopError?:error; }
  BOOL off=session.off&&!Exists(work),absent=identity&&ExperimentAbsent(identity);
  NSDictionary *result=@{@"event":@"done",@"success":@(success&&off&&absent),@"session":session.identifier,@"configSHA256":digest,@"coreVersion":version[@"version"]?:@"unconfirmed",@"coreAbsent":@(absent),@"ownerAbsent":@(!Exists([base stringByAppendingPathComponent:@"owner.json"])),@"workAbsent":@(!Exists(work)),@"termination":session.terminationEvidence,@"error":error?:@"",@"inventory":ExperimentInventory(base)};
  (void)ExperimentSend(3,result);close(3);return success&&off&&absent?0:2;
}
static NSArray *ExperimentGroupMembers(pid_t group,NSString **error) {
  pid_t pids[64]={0};int bytes=proc_listpids(PROC_PGRP_ONLY,(uint32_t)group,pids,sizeof(pids));
  if(bytes<0 || bytes>=(int)sizeof(pids) || bytes%(int)sizeof(pid_t)) { Fail(error,@"experiment process group cannot be fully observed");return nil; }
  NSMutableArray *members=[NSMutableArray array];
  for(NSUInteger i=0;i<(NSUInteger)bytes/sizeof(pid_t);i++)if(pids[i]>0)[members addObject:@(pids[i])];return members;
}
// The supervisor remains our unreaped direct child until all group work is done.
// No record loaded from disk can authorize this signal path.
static BOOL ExperimentHeldAnchor(pid_t worker,NSDictionary *anchor,NSString **error) {
  if(worker<=0 || [anchor[@"pid"]intValue]!=worker)return Fail(error,@"invalid guardian child anchor");
  uint64_t deadline=KuroMonotonicMilliseconds()+100;
  do {
    siginfo_t status={0};if(waitid(P_PID,(id_t)worker,&status,WEXITED|WNOHANG|WNOWAIT))return Fail(error,@"guardian no longer holds its unreaped direct child");
    // libproc can hide a zombie between this wait sample and its own readback.
    // Retry only observation; no signal is authorized by an ambiguous sample.
    if(status.si_pid==worker || ExperimentSame(anchor,getpid(),NULL))return YES;
    usleep(1000);
  }while(KuroMonotonicMilliseconds()<deadline);
  return Fail(error,@"guardian child identity/exit transition is not observable");
}
static BOOL ExperimentGroupCleanup(pid_t worker,NSDictionary *anchor,NSDictionary *core,NSString **error) {
  if(worker<=0 || worker==getpgrp() || !ExperimentHeldAnchor(worker,anchor,error))return NO;
  // Let a successful worker return naturally before any termination request.
  uint64_t natural=KuroMonotonicMilliseconds()+500;
  while(KuroMonotonicMilliseconds()<natural) { siginfo_t status={0};if(waitid(P_PID,(id_t)worker,&status,WEXITED|WNOHANG|WNOWAIT))return Fail(error,@"guardian lost its child anchor");if(status.si_pid==worker)break;usleep(5000); }
  for(NSUInteger attempt=0;attempt<3;attempt++) {
    NSArray *members=ExperimentGroupMembers(worker,error);if(!members)return NO;BOOL live=NO;
    for(NSNumber *member in members) {
      pid_t pid=member.intValue;if(pid==worker)continue;
      if(!core || pid!=[core[@"pid"]intValue] || !ExperimentSame(core,0,error))return Fail(error,@"unknown or detached group identity; guardian refuses group signals");
      struct proc_bsdinfo info={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info))return NO;
      if(info.pbi_status!=SZOMB)live=YES;
    }
    siginfo_t status={0};if(waitid(P_PID,(id_t)worker,&status,WEXITED|WNOHANG|WNOWAIT))return Fail(error,@"guardian lost its unreaped supervisor anchor");
    if(!live&&status.si_pid==worker)return YES;
    if(attempt==2)return Fail(error,@"bounded guardian process-group cleanup is not proven");
    if(!ExperimentHeldAnchor(worker,anchor,error) || killpg(worker,attempt?SIGKILL:SIGTERM))return Fail(error,@"guardian group termination failed");
    uint64_t until=KuroMonotonicMilliseconds()+(attempt?1000:300);while(KuroMonotonicMilliseconds()<until)usleep(5000);
  }
  return NO;
}
// A crash before the spawn frame can leave a suspended Core. Recover its
// identity only from the still-held live experiment group and fixed executable;
// a receipt PID is never accepted. Unknown group members stop cleanup entirely.
static NSDictionary *ExperimentDiscoverCore(pid_t worker,NSDictionary *anchor,NSString *base,NSDictionary *manifest,NSString **error) {
  if(!ExperimentHeldAnchor(worker,anchor,error))return nil;
  NSArray *members=ExperimentGroupMembers(worker,error);NSDictionary *core=nil;
  for(NSNumber *member in members)if(member.intValue!=worker) {
    if(core) { Fail(error,@"multiple unannounced group members preserved");return nil; }
    pid_t pid=member.intValue;char path[PROC_PIDPATHINFO_MAXSIZE]={0};struct proc_bsdinfo info={0};
    NSString *fixed=[base stringByAppendingPathComponent:@"mihomo"];
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info) || (info.pbi_ppid!=(uint32_t)worker&&info.pbi_ppid!=1) ||
      proc_pidpath(pid,path,sizeof(path))<=0 || ![fixed isEqual:@(path)] || ![Hash(ReadProtected(base,fixed,geteuid(),error))isEqual:manifest[@"coreSHA256"]]) { Fail(error,@"unannounced group executable/parent is unknown; preserved");return nil; }
    core=ExperimentIdentity(pid,0,worker,error);
    if(!core || [core[@"startSeconds"]unsignedLongLongValue]<[anchor[@"startSeconds"]unsignedLongLongValue] || !ExperimentSame(core,0,error))return nil;
  }
  return core;
}
static NSDictionary *ExperimentSetupBlocked(NSString *base,NSString *message) {
  return @{@"status":@"blocked",@"base":base,@"groupAbsent":@NO,@"error":message?:@"setup failed; review exact retained directory",@"inventory":ExperimentInventory(base)};
}
static NSDictionary *ExperimentGuardian(NSString *stage,NSDictionary *manifest,BOOL fixture,NSString **error) {
  char temporary[]="/private/tmp/kuro-core-XXXXXX";if(!mkdtemp(temporary))return nil;NSString *base=@(temporary);
  NSString *source=fixture?Executable():[ExperimentReview()stringByAppendingPathComponent:@"mihomo"];
  NSData *bytes=ReadProtected(ExperimentReview(),source,geteuid(),error);
  if(!bytes || ![Hash(bytes)isEqual:manifest[@"coreSHA256"]] || !WriteNew([base stringByAppendingPathComponent:@"mihomo"],bytes,0755,error))return ExperimentSetupBlocked(base,error&&*error?*error:@"fixed Core copy failed before spawn");
  int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return ExperimentSetupBlocked(base,@"socketpair failed before spawn");
  posix_spawnattr_t attr;posix_spawn_file_actions_t actions;posix_spawnattr_init(&attr);posix_spawn_file_actions_init(&actions);
  int setup=posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_START_SUSPENDED|POSIX_SPAWN_CLOEXEC_DEFAULT);setup|=posix_spawnattr_setpgroup(&attr,0);
  setup|=posix_spawn_file_actions_adddup2(&actions,pair[1],3);
  char *arguments[]={(char *)Executable().fileSystemRepresentation,fixture?"--fixture-worker":"--worker",NULL};
  char *environment[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t worker=0;
  int spawned=setup?:posix_spawn(&worker,arguments[0],&actions,&attr,arguments,environment);
  posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);close(pair[1]);
  if(spawned) { close(pair[0]);return ExperimentSetupBlocked(base,@"suspended supervisor spawn failed"); }
  NSDictionary *anchor=ExperimentIdentity(worker,getpid(),worker,error),*core=nil,*ready=nil,*done=nil;
  if(!anchor) {
    close(pair[0]);siginfo_t held={0};
    // No SIGCONT has occurred. Only our exact unreaped direct child is signalled.
    if(!waitid(P_PID,(id_t)worker,&held,WEXITED|WNOHANG|WNOWAIT)) { (void)kill(worker,SIGKILL);(void)waitpid(worker,NULL,0); }
    return ExperimentSetupBlocked(base,@"suspended supervisor identity unavailable; retained files require review");
  }
  BOOL resumed=!kill(worker,SIGCONT);
  if(resumed)resumed=ExperimentSend(pair[0],@{@"format":@1,@"stage":stage,@"epoch":manifest[@"epoch"],@"base":base});
  uint64_t deadline=KuroMonotonicMilliseconds()+15000;
  while(resumed&&!ExperimentCancelled&&KuroMonotonicMilliseconds()<deadline) {
    NSDictionary *event=ExperimentRead(pair[0],deadline,error);if(!event)break;
    if([event[@"event"]isEqual:@"spawned"]) { core=event[@"identity"];if(!ExperimentSame(core,worker,error))break; }
    else if([event[@"event"]isEqual:@"ready"]&&!ready) {
      ready=event;
      if(!core || !ExperimentSame(core,worker,error))break;
      if([stage isEqual:@"eof"])shutdown(pair[0],SHUT_WR);
      else if([stage isEqual:@"fixture-worker-exit"]) {}
      else if(!ExperimentSend(pair[0],@{@"version":@2,@"operation":@"stop",@"session":event[@"session"],@"sequence":@1}))break;
    } else if([event[@"event"]isEqual:@"done"]) {done=event;break;}
    // The version-2 stop acknowledgement is followed by the worker's result.
    else if(!([event[@"version"]isEqual:@2]&&[event[@"sequence"]isEqual:@1]))break;
  }
  close(pair[0]);
  if(!core)core=ExperimentDiscoverCore(worker,anchor,base,manifest,error);
  BOOL group=ExperimentGroupCleanup(worker,anchor,core,error);int status=0;
  if(group) { if(waitpid(worker,&status,0)!=worker)group=NO; }
  if(group) { NSArray *remaining=ExperimentGroupMembers(worker,error);group=remaining&&remaining.count==0&&(!core||ExperimentAbsent(core)); }
  BOOL pass=group&&done&&ready&&[done[@"success"]boolValue]&&WIFEXITED(status)&&WEXITSTATUS(status)==0;
  NSMutableDictionary *result=[@{@"format":@1,@"epoch":manifest[@"epoch"],@"stage":stage,@"status":pass?@"passed":@"blocked",@"base":base,@"groupAbsent":@(group),@"coreSHA256":manifest[@"coreSHA256"],@"runnerSHA256":manifest[@"runnerSHA256"],@"coreStdIO":@"discarded-to-dev-null",@"guardianLimit":@"live guardian only; SIGKILL of guardian or detached processes is not covered",@"error":error&&*error?*error:@""}mutableCopy];
  if(core)result[@"coreIdentity"]=core;
  if(done)result[@"worker"]=done;if(ready)result[@"readback"]=ready;
  if(pass) {
    NSString *corePath=[base stringByAppendingPathComponent:@"mihomo"];NSArray *names=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:base error:NULL];
    if(![[NSSet setWithArray:names?:@[]]isEqual:[NSSet setWithObject:@"mihomo"]] || ![Hash(ReadProtected(base,corePath,geteuid(),error))isEqual:manifest[@"coreSHA256"]] || unlink(corePath.fileSystemRepresentation) || rmdir(base.fileSystemRepresentation)) { result[@"status"]=@"blocked";result[@"error"]=@"unexpected work/root files preserved"; }
  }
  return result;
}
static BOOL ExperimentSuccess(NSDictionary *value,NSDictionary *manifest,NSString *stage) {
  if(!Keys(value,@[@"format",@"epoch",@"stage",@"status",@"coreSHA256",@"runnerSHA256",@"session",@"configSHA256",@"coreVersion",@"coreAbsent",@"ownerAbsent",@"workAbsent",@"groupAbsent",@"termination",@"coreStdIO",@"noIPReadbacks"]) || !KuroNumber(value[@"format"],1,1) || ![value[@"stage"]isEqual:stage] || ![value[@"status"]isEqual:@"passed"] || ![value[@"epoch"]isEqual:manifest[@"epoch"]] || ![value[@"coreSHA256"]isEqual:manifest[@"coreSHA256"]] || ![value[@"runnerSHA256"]isEqual:manifest[@"runnerSHA256"]] || !Match(value[@"configSHA256"],@"\\A[0-9a-f]{64}\\z") || ![value[@"session"]isKindOfClass:NSString.class] || ![[[NSUUID alloc]initWithUUIDString:value[@"session"]].UUIDString isEqual:value[@"session"]] || ![value[@"coreVersion"]isKindOfClass:NSString.class] || ![value[@"coreStdIO"]isEqual:@"discarded-to-dev-null"] || ![value[@"noIPReadbacks"]isEqual:@2])return NO;
  for(NSString *key in @[@"coreAbsent",@"ownerAbsent",@"workAbsent",@"groupAbsent"])if(!KuroBool(value[key])||![value[key]boolValue])return NO;
  NSDictionary *termination=value[@"termination"];
  if(!Keys(termination,@[@"request",@"observed",@"exitCode",@"signal"]) || ![termination[@"observed"]isEqual:@YES] || ![@[@"none",@"SIGTERM",@"SIGKILL"]containsObject:termination[@"request"]])return NO;
  return (termination[@"signal"]==NSNull.null && KuroNumber(termination[@"exitCode"],0,255)) ||
    (termination[@"exitCode"]==NSNull.null && KuroNumber(termination[@"signal"],1,NSIG-1));
}
static int ExperimentRun(NSString *stage) {
  NSString *error=nil;NSDictionary *manifest=ExperimentManifest(&error);if(!manifest) { fprintf(stderr,"BLOCKED %s\n",error.UTF8String);return 1; }
  NSString *review=ExperimentReview();
  if([stage isEqual:@"eof"]&&!ExperimentSuccess(ReadJSON(review,[review stringByAppendingPathComponent:@"normal-success.json"],geteuid(),&error),manifest,@"normal")) { fprintf(stderr,"BLOCKED same-epoch normal-success.json is required before EOF\n");return 1; }
  NSString *attempt=[review stringByAppendingPathComponent:[stage stringByAppendingString:@"-attempt.json"]];
  if(!WriteNew(attempt,JSONData(@{@"format":@1,@"epoch":manifest[@"epoch"],@"stage":stage}),0600,&error)) { fprintf(stderr,"BLOCKED stage already attempted or receipt directory changed\n");return 1; }
  signal(SIGINT,ExperimentCancel);signal(SIGTERM,ExperimentCancel);signal(SIGPIPE,SIG_IGN);
  NSDictionary *result=ExperimentGuardian(stage,manifest,NO,&error);
  if(!result)result=@{@"status":@"blocked",@"error":error?:@"experiment setup failed before ownership was established"};
  (void)WriteNew([review stringByAppendingPathComponent:[stage stringByAppendingString:@"-result.json"]],JSONData(result),0600,NULL);
  BOOL passed=[result[@"status"]isEqual:@"passed"];
  if(passed) {
    NSDictionary *worker=result[@"worker"],*readback=result[@"readback"];
    NSDictionary *success=@{@"format":@1,@"epoch":manifest[@"epoch"],@"stage":stage,@"status":@"passed",@"coreSHA256":manifest[@"coreSHA256"],@"runnerSHA256":manifest[@"runnerSHA256"],@"session":worker[@"session"],@"configSHA256":worker[@"configSHA256"],@"coreVersion":worker[@"coreVersion"],@"coreAbsent":worker[@"coreAbsent"],@"ownerAbsent":worker[@"ownerAbsent"],@"workAbsent":worker[@"workAbsent"],@"groupAbsent":@YES,@"termination":worker[@"termination"],@"coreStdIO":@"discarded-to-dev-null",@"noIPReadbacks":readback[@"noIPReadbacks"]};
    passed=ExperimentSuccess(success,manifest,stage)&&WriteNew([review stringByAppendingPathComponent:[stage stringByAppendingString:@"-success.json"]],JSONData(success),0600,&error);
  }
  NSData *output=JSONData(result);fwrite(output.bytes,1,output.length,stdout);puts("");
  return passed?0:2;
}
#import "core-experiment.test.m"
int main(int argc,const char **argv) {
  @autoreleasepool {
    if(geteuid()==0 || argc<2) { fprintf(stderr,"ordinary-user only: --self-test | --inspect | --normal | --eof\n");return 1; }
    if(argc==5&&!strcmp(argv[1],"-d")&&!strcmp(argv[3],"-f"))return ExperimentFixtureCore(argv[2],argv[4]);
    if(argc!=2)return 1;
    if(!strcmp(argv[1],"--worker"))return ExperimentWorker(NO);
    if(!strcmp(argv[1],"--fixture-worker"))return ExperimentWorker(YES);
    if(!strcmp(argv[1],"--self-test"))return ExperimentSelfTests();
    if(!strcmp(argv[1],"--normal"))return ExperimentRun(@"normal");
    if(!strcmp(argv[1],"--eof"))return ExperimentRun(@"eof");
    if(!strcmp(argv[1],"--inspect")) {
      NSString *error=nil;NSDictionary *manifest=ExperimentManifest(&error);if(!manifest) { fprintf(stderr,"BLOCKED %s\n",error.UTF8String);return 1; }
      NSDictionary *normal=ReadJSON(ExperimentReview(),[ExperimentReview()stringByAppendingPathComponent:@"normal-success.json"],geteuid(),NULL);
      NSData *output=JSONData(@{@"status":@"prepared",@"receipt":manifest,@"normalPassed":@(ExperimentSuccess(normal,manifest,@"normal")),@"stage3":@"not implemented or authorized"});fwrite(output.bytes,1,output.length,stdout);puts("");return 0;
    }
    return 1;
  }
}
