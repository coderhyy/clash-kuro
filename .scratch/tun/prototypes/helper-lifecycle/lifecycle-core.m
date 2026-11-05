// Compile-time experiment branch only. Reuse config/capture/held session; never call its guardian.
#define main KuroUnusedCoreExperimentMain
#import "../../../../apps/desktop/native/mac/core-experiment.m"
#undef main
static NSString *const LCLabel=@"dev.kuro.tun.lifecycle-a";
static NSString *const LCBinary=@"/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a";
static NSString *const LCBase=@"/Library/Application Support/Clash Kuro/TunLifecycleExperimentA";
static NSString *const LCPlist=@"/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist";
static volatile sig_atomic_t LCCancelled=0;
static void LCCancel(int value) {(void)value;LCCancelled=1;}
static BOOL LCStage(NSString *stage) {return [@[@"normal",@"kill"]containsObject:stage];}
static NSDictionary *LCPlistValue(NSDictionary *approval,NSString *stage) {
  return @{@"Label":LCLabel,@"ProgramArguments":@[LCBinary,@"--core-supervisor",stage,approval[[stage stringByAppendingString:@"Epoch"]]],@"RunAtLoad":@NO,@"KeepAlive":@NO,@"AbandonProcessGroup":@NO};
}
static BOOL LCApproval(id value) {
  if(!Keys(value,@[@"format",@"normalEpoch",@"killEpoch",@"fixtureSHA256",@"coreSHA256",@"coreArchiveSHA256",@"normalConfigSHA256",@"killConfigSHA256"]) || !KuroNumber(value[@"format"],1,1))return NO;
  for(NSString *stage in @[@"normal",@"kill"]) {
    NSString *epoch=value[[stage stringByAppendingString:@"Epoch"]];NSUUID *uuid=[epoch isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:epoch]:nil;
    if(!uuid||![uuid.UUIDString isEqual:epoch])return NO;
  }
  if([value[@"normalEpoch"]isEqual:value[@"killEpoch"]])return NO;
  for(NSString *field in @[@"fixtureSHA256",@"coreSHA256",@"coreArchiveSHA256",@"normalConfigSHA256",@"killConfigSHA256"])if(!Match(value[field],@"\\A[0-9a-f]{64}\\z"))return NO;
  return [value[@"coreSHA256"]isEqual:ExperimentCorePin]&&[value[@"coreArchiveSHA256"]isEqual:ExperimentArchivePin];
}
static BOOL LCControlled(id value) {
  if(!Keys(value,@[@"request",@"observed",@"exitCode",@"signal"])||!KuroBool(value[@"observed"])||![value[@"observed"]boolValue]||![@[@"SIGTERM",@"SIGKILL"]containsObject:value[@"request"]])return NO;
  if(KuroNumber(value[@"exitCode"],0,0))return value[@"signal"]==NSNull.null;
  return value[@"exitCode"]==NSNull.null&&KuroNumber(value[@"signal"],[value[@"request"]isEqual:@"SIGTERM"]?SIGTERM:SIGKILL,[value[@"request"]isEqual:@"SIGTERM"]?SIGTERM:SIGKILL);
}
static BOOL LCNormalResultValid(id value,NSDictionary *approval) {
  if(!Keys(value,@[@"format",@"stage",@"epoch",@"status",@"approvalSHA256",@"coreSHA256",@"fixtureSHA256",@"childReaped",@"workAbsent",@"ownerAbsent",@"termination",@"error"]) || !KuroNumber(value[@"format"],1,1) || ![value[@"stage"]isEqual:@"normal"] || ![value[@"status"]isEqual:@"passed"] || ![value[@"epoch"]isEqual:approval[@"normalEpoch"]] || ![value[@"approvalSHA256"]isEqual:Hash(JSONData(approval))] || ![value[@"coreSHA256"]isEqual:approval[@"coreSHA256"]] || ![value[@"fixtureSHA256"]isEqual:approval[@"fixtureSHA256"]] || ![value[@"error"]isEqual:@""] || !LCControlled(value[@"termination"]))return NO;
  for(NSString *key in @[@"childReaped",@"workAbsent",@"ownerAbsent"])if(!KuroBool(value[key])||![value[key]boolValue])return NO;
  return YES;
}
static NSDictionary *LCObservation(NSDictionary *expected);
static NSDictionary *LCNormalReceipt(NSDictionary *approval,NSString *normal) {
  NSDictionary *value=ReadJSON(LCBase,[normal stringByAppendingPathComponent:@"normal-success.json"],0,NULL);
  NSDictionary *evidence=ReadJSON(LCBase,[normal stringByAppendingPathComponent:@"evidence.json"],0,NULL);
  if(!LCNormalResultValid(value,approval)||![evidence[@"epoch"]isEqual:approval[@"normalEpoch"]])return nil;
  for(NSUInteger sample=0;sample<2;sample++) {
    NSArray *members=ExperimentGroupMembers([evidence[@"supervisor"][@"processGroup"]intValue],NULL);
    if(![LCObservation(evidence[@"supervisor"])[@"state"]isEqual:@"absent"]||![LCObservation(evidence[@"child"])[@"state"]isEqual:@"absent"]||!members||members.count||Exists([normal stringByAppendingPathComponent:@"owner.json"])||Exists([normal stringByAppendingPathComponent:@"session-work"]))return nil;
  }
  return value;
}
static NSDictionary *LCInstalled(NSString *stage,NSString *epoch,NSString **error) {
  if(geteuid()!=0 || !LCStage(stage) || ![Executable()isEqual:LCBinary] || !SafeChain(@"",LCBase,0,YES,error))return nil;
  NSDictionary *approval=ReadJSON(@"",[LCBase stringByAppendingPathComponent:@"approval.json"],0,error);
  NSData *self=ReadProtected(@"",LCBinary,0,error),*core=ReadProtected(@"",[[LCBase stringByAppendingPathComponent:stage]stringByAppendingPathComponent:@"mihomo"],0,error);
  NSDictionary *plist=[NSPropertyListSerialization propertyListWithData:ReadProtected(@"",LCPlist,0,error) options:NSPropertyListImmutable format:NULL error:NULL];
  if(!LCApproval(approval)||![approval[[stage stringByAppendingString:@"Epoch"]]isEqual:epoch]||![Hash(self)isEqual:approval[@"fixtureSHA256"]]||![Hash(core)isEqual:ExperimentCorePin]||![plist isEqual:LCPlistValue(approval,stage)]) {Fail(error,@"fixed experiment installation/pins/stage are not approved");return nil;}
  if([stage isEqual:@"kill"]&&!LCNormalReceipt(approval,[LCBase stringByAppendingPathComponent:@"normal"])) {Fail(error,@"protected normal success receipt is required before independent kill epoch");return nil;}
  return approval;
}
static BOOL LCGroup(pid_t child,NSString **error) {
  if(getpgrp()!=getpid())return Fail(error,@"supervisor must retain its launchd job group");
  NSArray *members=ExperimentGroupMembers(getpgrp(),error);
  NSSet *expected=child?[NSSet setWithArray:@[@(getpid()),@(child)]]:[NSSet setWithObject:@(getpid())];
  return (members&&[[NSSet setWithArray:members]isEqual:expected])||Fail(error,@"unexpected/incomplete job process group; no group signals permitted");
}
static NSDictionary *LCObservation(NSDictionary *expected) {
  if(!Keys(expected,@[@"pid",@"startSeconds",@"startMicros",@"processGroup",@"executable"])||!KuroNumber(expected[@"pid"],2,INT_MAX)||!KuroNumber(expected[@"processGroup"],2,INT_MAX)||!KuroNumber(expected[@"startSeconds"],1,9007199254740991ULL)||!KuroNumber(expected[@"startMicros"],0,999999)||![expected[@"executable"]isKindOfClass:NSString.class])return @{@"state":@"unknown"};
  struct proc_bsdinfo info={0};errno=0;int count=proc_pidinfo([expected[@"pid"]intValue],PROC_PIDTBSDINFO,0,&info,sizeof(info));int failure=errno;
  if(count==0&&failure==ESRCH)return @{@"state":@"absent"};
  char path[PROC_PIDPATHINFO_MAXSIZE]={0};
  if(count!=sizeof(info)||proc_pidpath([expected[@"pid"]intValue],path,sizeof(path))<=0)return @{@"state":@"unknown"};
  BOOL same=info.pbi_uid==geteuid()&&info.pbi_start_tvsec==[expected[@"startSeconds"]unsignedLongLongValue]&&info.pbi_start_tvusec==[expected[@"startMicros"]unsignedLongLongValue]&&info.pbi_pgid==[expected[@"processGroup"]unsignedIntValue]&&[expected[@"executable"]isEqual:@(path)];
  return @{@"state":same?@"same-instance-live":@"identity-mismatch-do-not-signal"};
}
static int LCRun(NSDictionary *approval,NSString *base,NSString *core,NSString *stage,BOOL fixture) {
  NSString *error=nil,*epoch=approval[[stage stringByAppendingString:@"Epoch"]],*work=[base stringByAppendingPathComponent:@"session-work"],*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
  NSArray *initial=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:base error:NULL];
  if(!LCStage(stage)||!initial||![[NSSet setWithArray:initial]isEqual:[NSSet setWithObject:core.lastPathComponent]]||!SafeChain(base,base,geteuid(),YES,&error)||!WriteNew([base stringByAppendingPathComponent:@"attempt.json"],JSONData(@{@"stage":stage,@"epoch":epoch}),0600,&error)||!SyncInstallDirectory(base,&error))return 2;
  NSData *runtime=ExperimentConfigData(socketPath,epoch);BOOL ready=NO,normalStop=NO,passed=NO;
  NSDictionary *identity=nil;__block NSDictionary *socketIdentity=nil;
  KuroCoreOutput *capture=[[KuroCoreOutput alloc]initWithSecrets:@[epoch]];KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:base owner:geteuid()];
  session.experimentStdoutDescriptor=capture?[capture writer:0]:-1;session.experimentStderrDescriptor=capture?[capture writer:1]:-1;
  __block BOOL cleanupAllowed=NO;__block NSString *failureStage=@"setup";
  do {
    if(!capture||(!fixture&&![Hash(runtime)isEqual:approval[[stage stringByAppendingString:@"ConfigSHA256"]]])) {error=@"fixed runtime/capture mismatch";break;}
    if(!ExperimentSave(base,@"config.redacted.json",ExperimentConfigData(socketPath,@"[REDACTED]"),&error)||!ExperimentSave(base,@"launch.json",JSONData(@{@"argv":@[core,@"-d",work,@"-f",[work stringByAppendingPathComponent:@"config.json"]],@"environmentKeys":@[@"PATH",@"LANG"],@"inheritsEnvironment":@NO,@"inheritedGroup":@(getpgrp()),@"coreSHA256":approval[@"coreSHA256"],@"configSHA256":Hash(runtime)}),&error))break;
    if(mkdir(work.fileSystemRepresentation,0700)||!WriteNew([work stringByAppendingPathComponent:@"config.json"],runtime,0600,&error)||![session setLaunchEvidence:@{@"configSHA256":Hash(runtime),@"coreSHA256":approval[@"coreSHA256"],@"template":@"core-control-experiment-v1"} error:&error])break;
    failureStage=@"spawn";__weak KuroOwnedSession *weak=session;
    BOOL spawned=[session spawnExecutable:core arguments:@[@"-d",work,@"-f",[work stringByAppendingPathComponent:@"config.json"]] workingDirectory:work beforeResume:^BOOL(NSString **problem) {return !LCCancelled&&LCGroup(weak.child,problem);} afterReap:^BOOL(NSString **problem) {
      if(![capture finishTo:base error:problem])return NO;
      NSDictionary *cache=ExperimentCacheIdentity(base,problem);
      if(Exists([work stringByAppendingPathComponent:@"cache.db"])&&!cache)return NO;
      NSDictionary *checkpoint=@{@"format":@1,@"stage":stage,@"epoch":epoch,@"termination":weak.terminationEvidence,@"output":capture.statistics,@"cleanupAllowed":@(cleanupAllowed),@"cacheIdentity":cache?:(id)NSNull.null,@"failureStage":failureStage};
      if(!ExperimentSave(base,@"reaped.json",JSONData(checkpoint),problem)||!SyncInstallDirectory(base,problem))return NO;
      if(!cleanupAllowed)return Fail(problem,@"failed experiment work preserved after held-child reap");
      return ExperimentRemoveWork(base,Hash(runtime),socketIdentity,cache,problem);
    } error:&error];
    [capture closeWriters];if(!spawned)break;
    identity=ExperimentIdentity(session.child,getpid(),getpgrp(),&error);char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(!identity||proc_pidpath(session.child,executable,sizeof(executable))<=0||![core isEqual:@(executable)])break;
    failureStage=@"private-readiness";
    KuroSessionHook verify=^BOOL(NSString **problem) {
      if(!ExperimentSame(identity,getpid(),problem)||!LCGroup(session.child,problem)||!SafeChain(base,work,geteuid(),YES,problem))return NO;
      struct stat info={0};if(lstat(socketPath.fileSystemRepresentation,&info)||!S_ISSOCK(info.st_mode)||info.st_uid!=geteuid()||info.st_nlink!=1)return Fail(problem,@"fixed Core socket is not observable");
      NSDictionary *observed=@{@"device":@((uint64_t)info.st_dev),@"inode":@(info.st_ino)};
      if(socketIdentity)return [observed isEqual:socketIdentity]||Fail(problem,@"fixed Core socket changed");
      if(![session recordWorkSocket:observed error:problem])return NO;socketIdentity=observed;return YES;
    };
    uint64_t deadline=KuroMonotonicMilliseconds()+5000;id version=nil;
    do {error=nil;version=KuroCoreControlRequest(socketPath,epoch,ExperimentGroups(),verify,@{@"operation":@"version"},&error);if(version)break;usleep(10000);}while(!LCCancelled&&KuroMonotonicMilliseconds()<deadline);
    ready=[version[@"version"]isEqual:(fixture?@"fixture-1":@"v1.19.33")];
    if(!ready||!socketIdentity||!ExperimentNoIP(identity,&error)||!LCGroup(session.child,&error))break;
    // Exercise only the existing closed local broker; no URLs or network data.
    failureStage=@"typed-readback";
    if(!KuroCoreControlRequest(socketPath,epoch,ExperimentGroups(),verify,@{@"operation":@"readMode"},&error)||!KuroCoreControlRequest(socketPath,epoch,ExperimentGroups(),verify,@{@"operation":@"readSelection",@"group":ExperimentGroup},&error)||!ExperimentNoIP(identity,&error))break;
    NSDictionary *supervisor=ExperimentIdentity(getpid(),getppid(),getpgrp(),&error);if(!supervisor)break;
    NSMutableDictionary *parent=[supervisor mutableCopy],*child=[identity mutableCopy];parent[@"executable"]=Executable();child[@"executable"]=core;
    failureStage=@"evidence";
    if(!ExperimentSave(base,@"evidence.json",JSONData(@{@"format":@1,@"stage":stage,@"epoch":epoch,@"coreSHA256":approval[@"coreSHA256"],@"fixtureSHA256":approval[@"fixtureSHA256"],@"supervisor":parent,@"child":child,@"startedMilliseconds":@(KuroMonotonicMilliseconds())}),&error)||![capture checkpointTo:base error:&error]||!SyncInstallDirectory(base,&error))break;
    if([stage isEqual:@"normal"]) {
      failureStage=@"held-stop";normalStop=YES;cleanupAllowed=YES;
      passed=[session stop:&error]&&session.off&&!Exists(work)&&ExperimentAbsent(identity)&&LCGroup(0,&error)&&ExperimentControlledTermination(session.terminationEvidence);
      break;
    }
    failureStage=@"await-job-kill";
    // Only launchd can produce this stage's success, measured independently.
    // The supervisor never signals its own group or adopts recorded PIDs.
    deadline=KuroMonotonicMilliseconds()+30000;
    while(!LCCancelled&&KuroMonotonicMilliseconds()<deadline) {
      if(!LCGroup(session.child,&error)||!ExperimentNoIP(identity,&error)||![capture checkpointTo:base error:&error])break;
      usleep(100000);
    }
    error=error?:@"job kill not observed in finite window; held stop is fallback, not group-cleanup proof";
  }while(NO);
  if(session.child||!session.off) {NSString *failure=nil;cleanupAllowed=normalStop&&ready;if(![session stop:&failure])error=error?:failure;}
  NSString *captureFailure=nil;if(!capture||![capture finishTo:base error:&captureFailure]) {passed=NO;error=error?:captureFailure?:@"capture unavailable";}
  BOOL childReaped=KuroBool(session.terminationEvidence[@"observed"])&&[session.terminationEvidence[@"observed"]boolValue],workAbsent=!Exists(work),ownerAbsent=!Exists([base stringByAppendingPathComponent:@"owner.json"]);
  passed=passed&&childReaped&&workAbsent&&ownerAbsent&&!error;
  NSDictionary *result=@{@"format":@1,@"stage":stage,@"epoch":epoch,@"status":passed?@"passed":@"blocked",@"approvalSHA256":Hash(JSONData(approval)),@"coreSHA256":approval[@"coreSHA256"],@"fixtureSHA256":approval[@"fixtureSHA256"],@"childReaped":@(childReaped),@"workAbsent":@(workAbsent),@"ownerAbsent":@(ownerAbsent),@"termination":session.terminationEvidence,@"error":error?:@""};
  NSString *saved=nil;if(!ExperimentSave(base,@"result.json",JSONData(result),&saved)||!SyncInstallDirectory(base,&saved))passed=NO;
  if(passed&&!LCNormalResultValid(result,approval))passed=NO;
  if(passed&&(!ExperimentPublishSuccess(base,@"normal",result,nil,&saved)||!SyncInstallDirectory(base,&saved)))passed=NO;
  if(!passed)fprintf(stderr,"BLOCKED %s (%s)\n",(error?:saved?:@"incomplete experiment").UTF8String,failureStage.UTF8String);
  NSData *encoded=JSONData(result);fwrite(encoded.bytes,1,encoded.length,stdout);puts("");return passed?0:2;
}
static int LCInspect(NSDictionary *approval,NSString *stage) {
  NSString *base=[LCBase stringByAppendingPathComponent:stage];NSDictionary *evidence=ReadJSON(LCBase,[base stringByAppendingPathComponent:@"evidence.json"],0,NULL);
  if(![evidence[@"epoch"]isEqual:approval[[stage stringByAppendingString:@"Epoch"]]])return 2;
  NSString *error=nil;NSArray *members=ExperimentGroupMembers([evidence[@"supervisor"][@"processGroup"]intValue],&error);
  NSDictionary *result=@{@"epoch":evidence[@"epoch"],@"supervisor":LCObservation(evidence[@"supervisor"]),@"child":LCObservation(evidence[@"child"]),@"groupMembers":members?:@[],@"groupObservationKnown":@(members!=nil),@"elapsedMilliseconds":@(KuroMonotonicMilliseconds()-[evidence[@"startedMilliseconds"]unsignedLongLongValue]),@"workExists":@(Exists([base stringByAppendingPathComponent:@"session-work"])),@"ownerExists":@(Exists([base stringByAppendingPathComponent:@"owner.json"])),@"error":error?:@""};
  NSData *data=JSONData(result);fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
}
static int LCSelfTest(void) {
  if(geteuid()==0)return 2;
  // A real harmless child runs this binary's existing no-TUN JSON/socket fixture.
  char temporary[]="/private/tmp/kuro-core-lifecycle-XXXXXX";if(!mkdtemp(temporary))return 2;
  NSString *base=@(temporary),*core=[base stringByAppendingPathComponent:@"fixture"];
  NSString *error=nil;if(!WriteNew(core,[NSData dataWithContentsOfFile:Executable()],0755,&error))return 2;
  NSDictionary *approval=@{@"format":@1,@"normalEpoch":NSUUID.UUID.UUIDString,@"killEpoch":NSUUID.UUID.UUIDString,@"fixtureSHA256":Hash([NSData dataWithContentsOfFile:Executable()]),@"coreSHA256":Hash([NSData dataWithContentsOfFile:Executable()]),@"coreArchiveSHA256":ExperimentArchivePin};
  // The outer fixture establishes a disposable group only for local tests. The
  // actual supervisor LCRun never changes PGID and production still inherits job.
  pid_t child=fork();if(child<0)return 2;
  if(!child) {if(setpgid(0,0))_exit(2);_exit(LCRun(approval,base,core,@"normal",YES));}
  int status=0;if(waitpid(child,&status,0)!=child||!WIFEXITED(status)||WEXITSTATUS(status))return 2;
  NSDictionary *result=ReadJSON(base,[base stringByAppendingPathComponent:@"result.json"],geteuid(),&error);
  if(!LCNormalResultValid(result,approval))return 2;
  for(NSString *key in @[@"childReaped",@"workAbsent",@"ownerAbsent"]) {NSMutableDictionary *bad=[result mutableCopy];bad[key]=@1;if(LCNormalResultValid(bad,approval))return 2;}
  NSMutableDictionary *bad=[result mutableCopy],*termination=[result[@"termination"]mutableCopy];termination[@"observed"]=@1;bad[@"termination"]=termination;if(LCNormalResultValid(bad,approval))return 2;
  if(!WriteNew([base stringByAppendingPathComponent:@"unknown"],[@"preserve"dataUsingEncoding:NSUTF8StringEncoding],0600,&error)||LCRun(approval,base,core,@"normal",YES)!=2||![[NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:@"unknown"]]isEqual:[@"preserve"dataUsingEncoding:NSUTF8StringEncoding]])return 2;
  NSMutableDictionary *wrong=[approval mutableCopy];wrong[@"normalEpoch"]=NSUUID.UUID.UUIDString;if(LCNormalResultValid(result,wrong))return 2;
  if(!Exists([base stringByAppendingPathComponent:@"normal-success.json"])||Exists([base stringByAppendingPathComponent:@"session-work"])||Exists([base stringByAppendingPathComponent:@"owner.json"]))return 2;
  printf("PASS harmless fixed-child fixture, inherited group, noTUN config/private socket, held stop and bounded evidence: %s\n",base.UTF8String);return 0;
}
int main(int argc,const char **argv) {
  @autoreleasepool {
    if(argc==5&&!strcmp(argv[1],"-d")&&!strcmp(argv[3],"-f")&&geteuid()!=0)return ExperimentFixtureCore(argv[2],argv[4],"");
    if(argc==2&&!strcmp(argv[1],"--self-test"))return LCSelfTest();
    if(argc==4&&!strcmp(argv[1],"--config")&&geteuid()!=0) {
      NSString *stage=@(argv[2]),*epoch=@(argv[3]);if(!LCStage(stage)||![[[NSUUID alloc]initWithUUIDString:epoch].UUIDString isEqual:epoch])return 2;
      NSData *data=ExperimentConfigData([[[LCBase stringByAppendingPathComponent:stage]stringByAppendingPathComponent:@"session-work"]stringByAppendingPathComponent:@"core.sock"],epoch);fwrite(data.bytes,1,data.length,stdout);return 0;
    }
    if(argc!=4||(strcmp(argv[1],"--core-supervisor")&&strcmp(argv[1],"--core-inspect")))return 2;
    NSString *stage=@(argv[2]),*epoch=@(argv[3]);
    NSString *error=nil;NSDictionary *approval=LCInstalled(stage,epoch,&error);if(!approval) {fprintf(stderr,"BLOCKED %s\n",error.UTF8String);return 2;}
    if(!strcmp(argv[1],"--core-inspect"))return LCInspect(approval,stage);
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,LCCancel);signal(SIGINT,LCCancel);
    return LCRun(approval,[LCBase stringByAppendingPathComponent:stage],[[LCBase stringByAppendingPathComponent:stage]stringByAppendingPathComponent:@"mihomo"],stage,NO);
  }
}
