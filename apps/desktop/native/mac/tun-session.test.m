// Deterministic observer: explicit ESRCH means only the recorded process is
// absent. It does not establish descendant/process-group exit or signal any PID.
static NSUInteger RestartObservation,RestartMode,RestartReappearAt;
static int RestartReader(int pid,int flavor,uint64_t arg,void *buffer,int size) {
  CHECK(pid==12345 && flavor==PROC_PIDTBSDINFO && arg==0 && size==sizeof(struct proc_bsdinfo));
  RestartObservation++;
  NSUInteger mode=RestartReappearAt && RestartObservation>=RestartReappearAt ? 2 : RestartMode;
  if(mode==0) { errno=ESRCH;return 0; }
  if(mode==3) { errno=EPERM;return 0; }
  if(mode==4) { errno=0;return 1; }
  struct proc_bsdinfo *value=buffer; memset(value,0,sizeof(*value));
  value->pbi_pid=(uint32_t)pid;value->pbi_start_tvsec=100;value->pbi_start_tvusec=mode==2?21:20;
  return sizeof(*value);
}
static NSUInteger RestartGroupMode;
static int RestartGroupReader(uint32_t type,uint32_t group,void *buffer,int size) {
  CHECK(type==PROC_PGRP_ONLY && group==12344 && size==64*(int)sizeof(pid_t));
  memset(buffer,0,(size_t)size);errno=0;
  if(RestartGroupMode==1){((pid_t *)buffer)[0]=23456;return sizeof(pid_t);}
  if(RestartGroupMode==2){errno=EPERM;return 0;}
  if(RestartGroupMode==3)return -1;
  if(RestartGroupMode==4)return size;
  if(RestartGroupMode==5)return 1;
  if(RestartGroupMode==6){((pid_t *)buffer)[0]=-1;return sizeof(pid_t);}
  return 0;
}
static NSMutableDictionary *RestartRecord(void) {
  NSString *digest=Hash(Bytes(@"fixture executable"));
  return [@{@"format":@1,@"session":@"00000000-0000-4000-8000-000000000001",@"pid":@12345,@"parent":@12344,@"startSeconds":@100,@"startMicros":@20,@"executableSHA256":digest,@"phase":@"prepared",@"processGroup":@12344,
    @"launch":@{@"configSHA256":Hash(Bytes(@"app config")),@"coreSHA256":digest,@"template":@"macos-dual-stack-v1"}} mutableCopy];
}
static void RestartOwnerTests(void) {
  for(NSUInteger scenario=0;scenario<10;scenario++) {
    char temporary[]="/tmp/kuro-restart-owner-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=[NSString stringWithUTF8String:canonical],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSMutableDictionary *record=RestartRecord();
    if(scenario==1)record[@"extra"]=@YES;
    if(scenario==2)FixtureDirectory([directory stringByAppendingPathComponent:@"session-work"]);
    Put(journal,JSONData(record),0600);
    NSData *original=[NSData dataWithContentsOfFile:journal];
    RestartObservation=0;RestartMode=scenario>=3&&scenario<=6?scenario-2:0;RestartReappearAt=scenario==7?3:0;
    KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;observed.fixtureRestartGroupReader=RestartGroupReader;
    __block NSUInteger network=0,work=0;
    BOOL ok=[observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) {
      network++;if(scenario==8)return Fail(failure,@"fixture network receipt remains");
      if(scenario==9)Put([directory stringByAppendingPathComponent:@"network-dns.json"],Bytes(@"retained DNS"),0600);
      return YES;
    } workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) { CHECK([owner isEqual:record]);work++;return stillAbsent(failure); } error:&error];
    CHECK(ok==(scenario==0));CHECK(observed.off==ok);CHECK(observed.child==0);
    if(ok)CHECK(!Exists(journal));
    else { CHECK(error.length>0);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:original]); }
    if(scenario>=1&&scenario<=6)CHECK(network==0&&work==0);
    if(scenario==7||scenario==8)CHECK(network==1&&work==0);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  RestartReappearAt=0;RestartMode=0;
  puts("native restart owner: strict/legacy receipts, present/reused/denied/incomplete PID observations, changing observation and retained DNS preserve ownership; ESRCH never proves descendants exited");
}
static NSUInteger RestartSupervisorObservation,RestartSupervisorMode,RestartSupervisorReappearAt;
static int RestartSupervisorReader(int pid,int flavor,uint64_t arg,void *buffer,int size) {
  if(pid==12345)return RestartReader(pid,flavor,arg,buffer,size);
  CHECK(pid==12344 && flavor==PROC_PIDTBSDINFO && arg==0 && size==sizeof(struct proc_bsdinfo));
  RestartSupervisorObservation++;
  NSUInteger mode=RestartSupervisorReappearAt && RestartSupervisorObservation>=RestartSupervisorReappearAt?1:RestartSupervisorMode;
  if(mode==0){errno=ESRCH;return 0;}
  if(mode==3){errno=EPERM;return 0;}
  if(mode==4){errno=0;return 1;}
  if(mode==5){errno=0;return 0;}
  if(mode==6){errno=ESRCH;return -1;}
  struct proc_bsdinfo *value=buffer;memset(value,0,sizeof(*value));
  value->pbi_pid=(uint32_t)pid;value->pbi_start_tvsec=50;value->pbi_start_tvusec=mode==2?61:60;
  return sizeof(*value);
}
static void RestartSupervisorTests(void) {
  for(NSUInteger scenario=0;scenario<11;scenario++) {
    char temporary[]="/tmp/kuro-supervisor-absence-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSMutableDictionary *record=RestartRecord();
    if(scenario!=10) {
      record[@"format"]=@2;
      record[@"work"]=@{@"configSHA256":record[@"launch"][@"configSHA256"],@"socket":NSNull.null};
      record[@"supervision"]=@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":Hash(Bytes(@"helper fixture")),@"startSeconds":@50,@"startMicros":@60};
    }
    CHECK(KuroRestartRecord(record,NULL));Put(journal,JSONData(record),0600);NSData *original=[NSData dataWithContentsOfFile:journal];
    RestartObservation=0;RestartMode=0;RestartReappearAt=0;RestartGroupMode=0;
    RestartSupervisorObservation=0;RestartSupervisorMode=scenario>=1&&scenario<=6?scenario:0;
    RestartSupervisorReappearAt=scenario==7?3:scenario==8?4:scenario==9?5:0;
    KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];session.fixtureRestartReader=RestartSupervisorReader;session.fixtureRestartGroupReader=RestartGroupReader;
    __block NSUInteger networks=0,works=0;
    BOOL ok=[session recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;networks++;return YES;} workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook absent,NSString **failure){CHECK([owner isEqual:record]);works++;return absent(failure);} error:&error];
    CHECK(ok==(scenario==0||scenario==10));CHECK(session.off==ok&&!session.child);CHECK(![session completedStopEvidence:NULL]);
    if(ok)CHECK(!Exists(journal));
    else {CHECK(error.length>0&&[error containsString:@"old helper"]);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:original]);}
    if(scenario>=1&&scenario<=6)CHECK(networks==0&&works==0);
    if(scenario==7)CHECK(networks==1&&works==0);
    if(scenario==8||scenario==9)CHECK(networks==1&&works==1);
    if(scenario==0)CHECK(RestartSupervisorObservation==5);
    if(scenario==10)CHECK(RestartSupervisorObservation==0);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  RestartMode=0;RestartReappearAt=0;RestartSupervisorReappearAt=0;
  puts("native supervisor absence: 11 temporary owner cases; live/reused/unknown helper and reappearance before/during/after cleanup rejected; legacy unchanged; no PID signal or fresh stop proof");
}
static void CacheOriginTests(void) {
  for(NSUInteger scenario=0;scenario<11;scenario++) {
    char temporary[]="/tmp/kuro-origin-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*cache=[work stringByAppendingPathComponent:@"cache.db"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*child=[directory stringByAppendingPathComponent:@"child"],*error=nil;
    Put(child,[NSData dataWithContentsOfFile:Executable()],0755);FixtureDirectory(work);Put([work stringByAppendingPathComponent:@"config.json"],Bytes(@"fixture config"),0600);
    KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];
    if(scenario==1)Put(cache,Bytes(@"unknown existing cache"),0600);
    if(scenario==2)CHECK(!symlink(child.fileSystemRepresentation,cache.fileSystemRepresentation));
    if(scenario==3)session.fixtureFailWorkCacheSync=YES;
    BOOL prepared=[session prepareWorkCache:&error];CHECK(prepared==(scenario!=1&&scenario!=2&&scenario!=3));
    if(!prepared) {
      CHECK(error.length>0 && Exists(cache) && !session.child && Exists(work));
      if(scenario==1)CHECK([[NSData dataWithContentsOfFile:cache]isEqual:Bytes(@"unknown existing cache")]);
      if(scenario==2){struct stat node={0};CHECK(!lstat(cache.fileSystemRepresentation,&node)&&S_ISLNK(node.st_mode));}
      CHECK(![session prepareWorkCache:&error]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);continue;
    }
    NSDictionary *initial=KuroWorkCacheSnapshot(directory,geteuid(),&error);CHECK(initial&&[initial[@"size"]isEqual:@0]&&[initial[@"mode"]isEqual:@0600]);
    CHECK(![session prepareWorkCache:&error]); // No existing file adoption, even by the original object.
    NSDictionary *evidence=@{@"configSHA256":Hash(Bytes(@"fixture config")),@"coreSHA256":Hash([NSData dataWithContentsOfFile:child]),@"template":@"macos-dual-stack-v1"};CHECK([session setLaunchEvidence:evidence error:&error]);
    if(scenario==4){CHECK(!rename(cache.fileSystemRepresentation,[work stringByAppendingPathComponent:@"held-original"].fileSystemRepresentation));Put(cache,NSData.data,0600);}
    if(scenario==8)Put(journal,Bytes(@"unknown owner collision"),0600);
    if(scenario==9)session.fixtureFailOwnerPublish=YES;
    CHECK(![session spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:work beforeResume:^BOOL(NSString **failure){(void)failure;return YES;} afterReap:^BOOL(NSString **failure){(void)failure;return YES;} error:&error]);CHECK(!session.child);
    int output[2],errors[2];CHECK(!pipe(output)&&!pipe(errors));
    CHECK(![session setOutputStdout:output[0] stderr:errors[1] error:&error]);
    CHECK(![session setOutputStdout:output[1] stderr:output[1] error:&error]);
    CHECK([session setOutputStdout:output[1] stderr:errors[1] error:&error]);
    __block BOOL sawOrigin=NO;
    KuroSessionHook cleanup=^BOOL(NSString **failure) {
      NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL),*origin=record[@"work"][@"cacheOrigin"];
      CHECK(KuroWorkCacheOrigin(origin)&&[origin[@"owner"]unsignedLongLongValue]==geteuid());sawOrigin=YES;
      NSDictionary *final=KuroWorkCacheSnapshot(directory,geteuid(),failure);
      if(!final || ![session recordReapedWorkCache:final error:failure])return NO;
      CHECK([KuroWorkCacheSnapshot(directory,geteuid(),NULL)isEqual:final]);
      CHECK(!unlink(cache.fileSystemRepresentation));CHECK(!unlink([work stringByAppendingPathComponent:@"config.json"].fileSystemRepresentation));CHECK(!rmdir(work.fileSystemRepresentation));return YES;
    };
    BOOL spawned=[session spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:work beforeResume:^BOOL(NSString **failure) {
      NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL);CHECK(KuroRestartRecord(record,NULL)&&KuroWorkCacheOrigin(record[@"work"][@"cacheOrigin"]));
      if(scenario==10)return Fail(failure,@"injected owner preparation failure before resume");return YES;
    } afterReap:cleanup resumeGate:^BOOL(KuroSessionHook resume,NSString **failure) {
      if(scenario==5){CHECK(!rename(cache.fileSystemRepresentation,[work stringByAppendingPathComponent:@"held-original"].fileSystemRepresentation));Put(cache,NSData.data,0600);}
      return resume(failure);
    } error:&error];
    CHECK(spawned==(scenario==0||scenario==6||scenario==7));
    if(spawned) {
      if(scenario==6)CHECK(!chmod(cache.fileSystemRepresentation,0400));
      else if(scenario==7){CHECK(!rename(cache.fileSystemRepresentation,[work stringByAppendingPathComponent:@"held-original"].fileSystemRepresentation));Put(cache,Bytes(@"replacement"),0600);}
      else CHECK([Bytes(@"in-place cache initialization")writeToFile:cache atomically:NO]);
      BOOL stopped=[session stop:&error];CHECK(stopped==(scenario==0));
      if(scenario==0){NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL);CHECK(!record);CHECK(session.off);}
    }
    CHECK(!session.child);
    if(scenario!=8){CHECK([session.terminationEvidence[@"observed"]boolValue]);}
    close(output[0]);close(output[1]);close(errors[0]);close(errors[1]);
    if(scenario==0||scenario==10)CHECK(!Exists(work)&&!Exists(cache)&&session.off);
    else CHECK(Exists(work)&&Exists(cache));
    if(scenario!=0&&scenario!=10)CHECK(!session.off); // Failed/unknown ownership never masquerades as off.
    if(scenario==8)CHECK([[NSData dataWithContentsOfFile:journal]isEqual:Bytes(@"unknown owner collision")]);
    if(scenario==9)CHECK(!sawOrigin&&!Exists(journal));
    if(scenario==0||scenario==10)CHECK(sawOrigin);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  // Optional provenance is accepted on old format2, but never substitutes for the final cache receipt.
  NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;
  NSMutableDictionary *work=[@{@"configSHA256":Hash(Bytes(@"config")),@"socket":NSNull.null,@"cacheOrigin":@{@"device":@1,@"inode":@2,@"owner":@(geteuid()),@"mode":@0600}}mutableCopy];record[@"work"]=work;
  CHECK(KuroRestartRecord(record,NULL));work[@"cacheOrigin"]=@{@"device":@1,@"inode":@2,@"owner":@(geteuid()),@"mode":@0644};CHECK(!KuroRestartRecord(record,NULL));
  puts("native cache origin: 11 ordinary-user held-child cases; exclusive0600, sync/publication failures, pre-resume replacement, same-inode writes, changed mode/inode and unknown-owner preservation; no Core/network");
}
static void SessionDurabilityTests(void) {
  // A renamed socket receipt is not accepted until the directory sync succeeds.
  char first[]="/tmp/kuro-socket-durable-XXXXXX";CHECK(mkdtemp(first));char resolved[PATH_MAX];CHECK(realpath(first,resolved));
  NSString *directory=@(resolved),*work=[directory stringByAppendingPathComponent:@"session-work"],*config=[work stringByAppendingPathComponent:@"config.json"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*child=[directory stringByAppendingPathComponent:@"child"],*error=nil;
  FixtureDirectory(work);Put(config,Bytes(@"fixture config"),0600);Put(child,[NSData dataWithContentsOfFile:Executable()],0755);
  KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];
  CHECK(([session setLaunchEvidence:@{@"configSHA256":Hash(Bytes(@"fixture config")),@"coreSHA256":Hash([NSData dataWithContentsOfFile:child]),@"template":@"macos-dual-stack-v1"} error:&error]));
  int output[2],errors[2];CHECK(!pipe(output)&&!pipe(errors));CHECK([session setOutputStdout:output[1] stderr:errors[1] error:&error]);
  CHECK([session spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:work beforeResume:^BOOL(NSString **failure){(void)failure;return YES;} afterReap:^BOOL(NSString **failure){(void)failure;CHECK(!unlink(config.fileSystemRepresentation));CHECK(!rmdir(work.fileSystemRepresentation));return YES;} error:&error]);
  NSDictionary *identity=@{@"device":@1,@"inode":@2};session.fixtureFailDirectorySync=YES;
  CHECK(![session recordWorkSocket:identity error:&error]);CHECK(error.length>0&&!session.off);
  NSData *published=[NSData dataWithContentsOfFile:journal];CHECK([ReadJSON(directory,journal,geteuid(),NULL)[@"work"][@"socket"]isEqual:identity]);
  CHECK(![session recordWorkSocket:identity error:&error]);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:published]);
  session.fixtureFailDirectorySync=NO;CHECK((![session recordWorkSocket:@{@"device":@1,@"inode":@3} error:&error]));CHECK([[NSData dataWithContentsOfFile:journal]isEqual:published]);
  CHECK([session recordWorkSocket:identity error:&error]);CHECK([session stop:&error]&&session.off);close(output[0]);close(output[1]);close(errors[0]);close(errors[1]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  // Unlink followed by failed fsync must remain unknown, even when no file is visible.
  for(NSUInteger existed=0;existed<2;existed++) {
    char path[]="/tmp/kuro-recover-durable-XXXXXX";CHECK(mkdtemp(path));CHECK(realpath(path,resolved));directory=@(resolved);journal=[directory stringByAppendingPathComponent:@"owner.json"];
    if(existed)Put(journal,JSONData(RestartRecord()),0600);
    KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;observed.fixtureRestartGroupReader=RestartGroupReader;observed.fixtureFailDirectorySync=YES;
    RestartObservation=0;RestartMode=0;RestartReappearAt=0;__block NSUInteger networks=0,works=0;
    KuroSessionHook network=^BOOL(NSString **failure){(void)failure;networks++;return YES;};
    KuroRestartWorkCleanup cleanup=^BOOL(NSDictionary *record,KuroSessionHook absent,NSString **failure){CHECK([record isEqual:RestartRecord()]);works++;return absent(failure);};
    CHECK(![observed recoverExitedOwnerWithNetwork:network workCleanup:cleanup error:&error]);CHECK(!Exists(journal)&&!observed.off);CHECK(![observed completedStopEvidence:&error]);
    CHECK(![observed recoverExitedOwnerWithNetwork:network workCleanup:cleanup error:&error]);CHECK(!observed.off);CHECK(works==existed&&networks==2);
    observed.fixtureFailDirectorySync=NO;CHECK([observed recoverExitedOwnerWithNetwork:network workCleanup:cleanup error:&error]);CHECK(observed.off&&works==existed&&networks==3);CHECK(![observed completedStopEvidence:&error]);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  // The same accurately reaped owner can retry only its own completed unlink.
  char held[]="/tmp/kuro-held-durable-XXXXXX";CHECK(mkdtemp(held));CHECK(realpath(held,resolved));directory=@(resolved);journal=[directory stringByAppendingPathComponent:@"owner.json"];child=[directory stringByAppendingPathComponent:@"child"];Put(child,[NSData dataWithContentsOfFile:Executable()],0755);
  KuroOwnedSession *owned=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];__block NSUInteger cleanups=0;
  CHECK([owned spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure){(void)failure;return YES;} afterReap:^BOOL(NSString **failure){(void)failure;cleanups++;owned.fixtureFailDirectorySync=YES;return YES;} error:&error]);pid_t original=owned.child;NSData *heldOwner=[NSData dataWithContentsOfFile:journal];NSDictionary *originalOwner=ReadJSON(directory,journal,geteuid(),NULL);
  CHECK(![owned stop:&error]);CHECK(!owned.child&&!owned.off&&!Exists(journal)&&cleanups==1);CHECK(waitpid(original,NULL,WNOHANG)==-1&&errno==ECHILD);CHECK(![owned completedStopEvidence:&error]);
  CHECK(![owned stop:&error]);CHECK(!owned.off&&cleanups==1&&!owned.child);CHECK(![owned completedStopEvidence:&error]);
  Put(journal,Bytes(@"unknown new owner"),0600);owned.fixtureFailDirectorySync=NO;CHECK(![owned stop:&error]);CHECK(!owned.off&&cleanups==1);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:Bytes(@"unknown new owner")]);CHECK(!unlink(journal.fileSystemRepresentation));
  CHECK([owned stop:&error]&&owned.off&&cleanups==1);NSDictionary *proof=[owned completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(proof));CHECK([proof[@"ownerSHA256"]isEqual:Hash(heldOwner)]&&[proof[@"owner"]isEqual:originalOwner]&&[proof[@"owner"][@"pid"]intValue]==original);CHECK([owned stop:&error]&&cleanups==1);
  CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  puts("native session durability: socket rename, absent owner recovery and held-owner unlink reject repeated sync failure; only successful sync permits acceptance/off, unknown replacement preserved; no Core/network");
}
static void RestartCacheCheckpointTests(void) {
  for(NSUInteger scenario=0;scenario<19;scenario++) {
    char temporary[]="/tmp/kuro-restart-checkpoint-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*cache=[work stringByAppendingPathComponent:@"cache.db"],*config=[work stringByAppendingPathComponent:@"config.json"],*approved=[directory stringByAppendingPathComponent:@"approved-install.json"],*error=nil;
    Put(config,Bytes(@"fixed runtime with private socket/secret"),0600);Put(cache,Bytes(@"initialized bounded cache"),0600);
    NSDictionary *snapshot=KuroWorkCacheSnapshot(directory,geteuid(),&error);CHECK(snapshot);
    NSMutableDictionary *owner=RestartRecord();owner[@"format"]=@2;
    NSDictionary *installation=@{@"release":@"fixture-v1.19.33",@"manifestSHA256":Hash(Bytes(@"manifest")),@"freshReceiptSHA256":Hash(Bytes(@"fresh receipt")),@"coreSHA256":owner[@"executableSHA256"]};
    NSData *approval=JSONData(installation);Put(approved,approval,0600);
    owner[@"supervision"]=@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":Hash(Bytes(@"helper fixture")),@"startSeconds":@50,@"startMicros":@60,@"installation":installation};
    NSMutableDictionary *launch=[owner[@"launch"]mutableCopy];launch[@"runtimeSHA256"]=Hash(Bytes(@"fixed runtime with private socket/secret"));owner[@"launch"]=launch;
    owner[@"work"]=@{@"directory":KuroWorkDirectorySnapshot(directory,geteuid(),NULL),@"configSHA256":launch[@"runtimeSHA256"],@"socket":NSNull.null,@"cacheOrigin":@{@"device":snapshot[@"device"],@"inode":snapshot[@"inode"],@"owner":@(geteuid()),@"mode":@0600}};
    if(scenario==17){NSMutableDictionary *receipt=[owner[@"work"]mutableCopy];receipt[@"cache"]=snapshot;owner[@"work"]=receipt;}
    CHECK(KuroRestartRecord(owner,NULL));Put(journal,JSONData(owner),0600);NSData *original=ReadProtected(directory,journal,geteuid(),NULL);
    if(scenario==16)CHECK(!unlink(cache.fileSystemRepresentation));
    if(scenario==18)CHECK(!unlink(cache.fileSystemRepresentation)&&!unlink(config.fileSystemRepresentation)&&!rmdir(work.fileSystemRepresentation));
    if(scenario==2)Put(approved,Bytes(@"changed approval"),0600);
    if(scenario==5)Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600);
    if(scenario==6)CHECK(!chmod(cache.fileSystemRepresentation,0400));
    if(scenario==11){CHECK(!unlink(cache.fileSystemRepresentation)&&!symlink(config.fileSystemRepresentation,cache.fileSystemRepresentation));}
    if(scenario==13){NSMutableDictionary *supervision=[owner[@"supervision"]mutableCopy];[supervision removeObjectForKey:@"installation"];owner[@"supervision"]=supervision;Put(journal,JSONData(owner),0600);original=ReadProtected(directory,journal,geteuid(),NULL);}
    RestartObservation=0;RestartMode=0;RestartReappearAt=0;RestartSupervisorObservation=0;RestartSupervisorMode=0;RestartSupervisorReappearAt=0;RestartGroupMode=0;
    KuroOwnedSession *(^fresh)(void)=^KuroOwnedSession *{KuroOwnedSession *value=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];value.fixtureRestartReader=RestartSupervisorReader;value.fixtureRestartGroupReader=RestartGroupReader;return value;};
    KuroOwnedSession *session=fresh();if(scenario==7)session.fixtureFailDirectorySync=YES;if(scenario==12)session.fixtureFailOwnerPublish=YES;
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:[directory stringByAppendingPathComponent:@"unused"] hooks:[KuroTunServiceHooks new]];
    __block NSUInteger validations=0,cleanupChecks=0;__block BOOL changed=NO;
    KuroRestartWriterValidator validator=^BOOL(NSDictionary *record,NSString **failure) {
      validations++;
      if(![ReadProtected(directory,approved,geteuid(),failure)isEqual:approval] || ![record[@"supervision"][@"installation"]isEqual:installation])return Fail(failure,@"fixed approval bytes or installed binding changed");
      if(!changed && validations==4 && scenario==3){Put(cache,Bytes(@"changed during writer validation"),0600);changed=YES;}
      if(!changed && validations==4 && scenario==4){CHECK(!rename(cache.fileSystemRepresentation,[directory stringByAppendingPathComponent:@"original-cache"].fileSystemRepresentation));Put(cache,Bytes(@"replacement"),0600);changed=YES;}
      if(!changed && scenario==14){CHECK(!rename(work.fileSystemRepresentation,[directory stringByAppendingPathComponent:@"preserved-work"].fileSystemRepresentation));Put(config,Bytes(@"fixed runtime with private socket/secret"),0600);Put(cache,Bytes(@"initialized bounded cache"),0600);changed=YES;}
      if(!changed && scenario==9 && record[@"work"][@"cacheCheckpoint"])return Fail(failure,@"writer validation revoked before cleanup");
      if(!changed && scenario==10 && record[@"work"][@"cacheCheckpoint"]){Put(cache,Bytes(@"changed after checkpoint"),0600);changed=YES;}
      return YES;
    };
    KuroRestartWorkCleanup cleanup=^BOOL(NSDictionary *record,KuroSessionHook absent,NSString **failure) {
      if(scenario==15){CHECK(absent(failure));CHECK(!unlink(config.fileSystemRepresentation)&&!unlink(cache.fileSystemRepresentation)&&!rmdir(work.fileSystemRepresentation));FixtureDirectory(work);return absent(failure);}
      if(scenario<16)CHECK([record[@"work"][@"cacheCheckpoint"]isEqual:@"validated-restart-v1"]);
      CHECK([ReadJSON(directory,journal,geteuid(),NULL)isEqual:record]);
      return [service recoverExitedWork:record stillAbsent:^BOOL(NSString **problem) {cleanupChecks++;if(scenario==8 && cleanupChecks==2)return Fail(problem,@"injected interruption after config unlink");return absent(problem);} error:failure];
    };
    BOOL ok=[session recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} writerValidator:(scenario==1||scenario>=16)?nil:validator workCleanup:cleanup error:&error];
    CHECK(ok==(scenario==0));CHECK(!session.child&&![session completedStopEvidence:NULL]);
    if(ok)CHECK(session.off&&!Exists(work)&&!Exists(journal)&&validations>=3);
    else {
      CHECK(error.length>0&&!session.off&&(scenario==15||scenario==16||scenario==18||Exists(cache))&&Exists(journal));
      NSDictionary *saved=ReadJSON(directory,journal,geteuid(),NULL);
      BOOL checkpoint=saved[@"work"][@"cacheCheckpoint"]!=nil;
      CHECK(checkpoint==(scenario==5||scenario==7||scenario==8||scenario==9||scenario==10||scenario==15));
      if(!checkpoint)CHECK([ReadProtected(directory,journal,geteuid(),NULL)isEqual:original]);
      if(scenario>=16){CHECK(validations==0&&cleanupChecks==0);KuroOwnedSession *retry=fresh();CHECK([retry recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} writerValidator:validator workCleanup:cleanup error:&error]);CHECK(retry.off&&!Exists(work)&&!Exists(journal)&&![retry completedStopEvidence:NULL]);}
      if(scenario==7||scenario==8) {
        CHECK(Exists(config)==(scenario==7));NSData *published=ReadProtected(directory,journal,geteuid(),NULL);
        KuroOwnedSession *nilRetry=fresh();CHECK(![nilRetry recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} workCleanup:cleanup error:&error]);CHECK(!nilRetry.off&&[ReadProtected(directory,journal,geteuid(),NULL)isEqual:published]);
        KuroOwnedSession *retry=fresh();
        if(scenario==7){retry.fixtureFailDirectorySync=YES;CHECK(![retry recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} writerValidator:validator workCleanup:cleanup error:&error]);CHECK(!retry.off&&Exists(config)&&[ReadProtected(directory,journal,geteuid(),NULL)isEqual:published]);retry.fixtureFailDirectorySync=NO;}
        CHECK([retry recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} writerValidator:validator workCleanup:cleanup error:&error]);CHECK(retry.off&&!Exists(work)&&!Exists(journal)&&![retry completedStopEvidence:NULL]);
      }
    }
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  // The admitted hash differs from the generated runtime hash; only the latter binds work.
  NSMutableDictionary *record=RestartRecord(),*launch=[record[@"launch"]mutableCopy];record[@"format"]=@2;
  NSString *runtime=Hash(Bytes(@"runtime"));launch[@"runtimeSHA256"]=runtime;record[@"launch"]=launch;
  NSDictionary *installation=@{@"release":@"release-1",@"manifestSHA256":Hash(Bytes(@"manifest")),@"freshReceiptSHA256":Hash(Bytes(@"receipt")),@"coreSHA256":record[@"executableSHA256"]};
  NSMutableDictionary *supervision=[@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":Hash(Bytes(@"helper")),@"startSeconds":@50,@"startMicros":@60,@"installation":installation}mutableCopy];record[@"supervision"]=supervision;
  NSMutableDictionary *work=[@{@"directory":@{@"device":@1,@"inode":@2,@"owner":@(geteuid()),@"mode":@0700},@"configSHA256":runtime,@"socket":NSNull.null,@"cacheOrigin":@{@"device":@1,@"inode":@2,@"owner":@(geteuid()),@"mode":@0600}}mutableCopy];record[@"work"]=work;
  CHECK(KuroRestartRecord(record,NULL));launch[@"runtimeSHA256"]=launch[@"configSHA256"];CHECK(!KuroRestartRecord(record,NULL));launch[@"runtimeSHA256"]=runtime;
  NSMutableDictionary *bad=[installation mutableCopy];bad[@"coreSHA256"]=Hash(Bytes(@"different core"));supervision[@"installation"]=bad;CHECK(!KuroRestartRecord(record,NULL));supervision[@"installation"]=installation;
  work[@"cacheCheckpoint"]=@"validated-restart-v1";CHECK(!KuroRestartRecord(record,NULL));[work removeObjectForKey:@"cacheCheckpoint"];
  bad=[installation mutableCopy];bad[@"path"]=@"arbitrary";supervision[@"installation"]=bad;CHECK(!KuroSupervisionEvidence(supervision));supervision[@"installation"]=installation;
  bad=[installation mutableCopy];bad[@"release"]=@"../bad";supervision[@"installation"]=bad;CHECK(!KuroSupervisionEvidence(supervision));
  puts("native restart cache checkpoint: 19 real temporary-file chains; explicit fixed approval validator, stable origin snapshot and durable marked owner, changed bytes/inode/mode/symlink/unknown and replaced/reappeared work-directory refusals, all installed records require validator including cache-absent/final-cache/owner-only; nil retry and fsync/publish/partial cleanup retries; no Core/stop proof");
}

static void SessionTests(void) {
  RestartCacheCheckpointTests();
  SessionDurabilityTests();
  CacheOriginTests();
  RestartOwnerTests();
  RestartSupervisorTests();
  char temporary[] = "/tmp/kuro-session-XXXXXX"; CHECK(mkdtemp(temporary));
  char canonical[PATH_MAX]; CHECK(realpath(temporary, canonical));
  NSString *base = [NSString stringWithUTF8String:canonical];
  NSString *binary = [base stringByAppendingPathComponent:@"child"];
  Put(binary, [NSData dataWithContentsOfFile:Executable()], 0755);
  NSString *error = nil;
  for (NSUInteger scenario = 0; scenario < 10; scenario++) {
    NSString *directory = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"run%lu", (unsigned long)scenario]];
    FixtureDirectory(directory);
    NSString *child = [directory stringByAppendingPathComponent:@"child"]; Put(child, [NSData dataWithContentsOfFile:binary], 0755);
    KuroOwnedSession *session = [[KuroOwnedSession alloc] initWithDirectory:directory owner:geteuid()];
    CHECK(![session completedStopEvidence:&error]);
    CHECK(![session setLaunchEvidence:@{@"template":@"arbitrary"} error:&error]);
    NSDictionary *evidence=@{@"configSHA256":Hash(Bytes(@"config")),@"coreSHA256":Hash([NSData dataWithContentsOfFile:child]),@"template":@"macos-dual-stack-v1"};
    CHECK([session setLaunchEvidence:evidence error:&error]);
    __block BOOL cleanupAllowed = scenario != 5; __block NSUInteger cleanups = 0;
    CHECK(([session spawnExecutable:child arguments:@[@"--session-child", @"ignore-term"] beforeResume:^BOOL(NSString **failure) {
      (void)failure;
      NSDictionary *record = ReadJSON(directory, [directory stringByAppendingPathComponent:@"owner.json"], geteuid(), NULL);
      CHECK([record[@"pid"] intValue] == session.child); CHECK([record[@"session"] isEqual:session.identifier]);
      CHECK([record[@"phase"] isEqual:@"prepared"]); CHECK([record[@"launch"] isEqual:evidence]); CHECK([record[@"processGroup"] intValue]==getpgrp()); return YES;
    } afterReap:^BOOL(NSString **failure) { (void)failure; cleanups++; return cleanupAllowed; } error:&error]));
    CHECK(![session setLaunchEvidence:evidence error:&error]);
    pid_t owned = session.child; CHECK(owned > 0 && !session.off);CHECK(![session completedStopEvidence:&error]);
    int pair[2]; CHECK(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    pid_t writer = 0;
    if (scenario == 0) { close(pair[1]); pair[1] = -1; }
    if (scenario == 2 || scenario == 3 || scenario == 6 || scenario == 7 || scenario == 8 || scenario == 9) {
      NSString *frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"%@\",\"session\":\"%@\",\"sequence\":1}\n", scenario == 6 ? @"stop" : @"heartbeat", session.identifier];
      if (scenario == 7) frame = [NSString stringWithFormat:@"{\"sequence\":1,\"session\":\"%@\",\"operation\":\"heartbeat\",\"version\":2}\n", session.identifier];
      if (scenario == 8) frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"heartbeat\",\"session\":\"%@\",\"sequence\":1,\"sequence\":1}\n", session.identifier];
      if (scenario == 9) frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"heartbeat\",\"session\":\"%@\",\"sequence\":1,\"path\":\"/tmp/x\"}\n", session.identifier];
      NSData *bytes = Bytes(frame);
      writer = fork(); CHECK(writer >= 0);
      if (!writer) {
        close(pair[0]);
        if (write(pair[1], bytes.bytes, bytes.length) != (ssize_t)bytes.length) _exit(2);
        if (scenario != 8 && scenario != 9) {
          char reply[1024]; ssize_t count = read(pair[1], reply, sizeof(reply)); if (count <= 0) _exit(3);
          if (scenario == 6) { reply[MIN((size_t)count, sizeof(reply) - 1)] = 0; if (!strstr(reply, "\"state\":\"off\"")) _exit(5); }
          if (scenario == 3 && write(pair[1], bytes.bytes, bytes.length) != (ssize_t)bytes.length) _exit(4);
        }
        close(pair[1]); _exit(0);
      }
      close(pair[1]); pair[1] = -1;
    }
    BOOL stopped = [session superviseSocket:pair[0] leaseMilliseconds:80 identityValid:^BOOL { return scenario != 4; } error:&error];
    close(pair[0]); if (pair[1] >= 0) close(pair[1]);
    if (writer) { int result; CHECK(waitpid(writer, &result, 0) == writer && WIFEXITED(result) && WEXITSTATUS(result) == 0); }
    if (session.child) fprintf(stderr, "scenario %lu child %d stop %d error %s\n", (unsigned long)scenario, session.child, stopped, error.UTF8String);
    CHECK(session.child == 0); CHECK(waitpid(owned, NULL, WNOHANG) == -1 && errno == ECHILD);
    CHECK(cleanups == 1);
    if (scenario == 5) { CHECK(!stopped && !session.off); CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"])); cleanupAllowed = YES; CHECK([session stop:&error]); CHECK(cleanups == 2); }
    else CHECK(stopped);
    CHECK(session.off && !Exists([directory stringByAppendingPathComponent:@"owner.json"]));
    CHECK([session stop:&error]); CHECK(cleanups == (scenario == 5 ? 2 : 1));
    NSDictionary *proof=[session completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(proof)&&[proof[@"owner"][@"pid"]intValue]==owned);
    KuroOwnedSession *fresh=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];CHECK(fresh.off&&![fresh completedStopEvidence:&error]);
  }
  NSString *failedDirectory = [base stringByAppendingPathComponent:@"prepare-failed"]; FixtureDirectory(failedDirectory);
  NSString *child = [failedDirectory stringByAppendingPathComponent:@"child"]; Put(child, [NSData dataWithContentsOfFile:binary], 0755);
  KuroOwnedSession *failed = [[KuroOwnedSession alloc] initWithDirectory:failedDirectory owner:geteuid()];
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:failedDirectory beforeResume:^BOOL(NSString **failure) { (void)failure; return YES; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(failed.off && !failed.child);
  __block NSUInteger resumeGates=0,deniedCleanup=0;
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:nil beforeResume:^BOOL(NSString **failure) { (void)failure;return YES; } afterReap:^BOOL(NSString **failure) { (void)failure;deniedCleanup++;return YES; } resumeGate:^BOOL(KuroSessionHook resume,NSString **failure) { CHECK(resume!=nil);resumeGates++;return Fail(failure,@"test cancellation before SIGCONT"); } error:&error]);
  CHECK(resumeGates==1 && deniedCleanup==1 && failed.off && !failed.child);
  CHECK([error containsString:@"resume refused"]);
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return NO; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(failed.off && !failed.child);
  Put([failedDirectory stringByAppendingPathComponent:@"owner.json"], Bytes(@"foreign-owner"), 0600);
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return YES; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(!failed.child && !failed.off); CHECK([[NSData dataWithContentsOfFile:[failedDirectory stringByAppendingPathComponent:@"owner.json"]] isEqual:Bytes(@"foreign-owner")]);
  CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  puts("native owner/session: EOF, lease, heartbeat, replay, peer exit, cleanup retry, stop, preparation refusal passed");
}

// Runs only in a harmless ordinary-user subprocess with its own group. The
// injected source models launchd admission; this is not actual launchd evidence.
static void SupervisionSessionTests(void) {
  CHECK(geteuid()!=0);CHECK(getpgrp()==getpid() || !setpgid(0,0));CHECK(getpgrp()==getpid());
  for(NSUInteger scenario=0;scenario<6;scenario++) {
    char temporary[]="/tmp/kuro-supervision-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*child=[directory stringByAppendingPathComponent:@"child"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSData *executable=[NSData dataWithContentsOfFile:Executable()],*config=Bytes(@"{}");Put(child,executable,0755);
    KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];KuroCoreOutput *output=[[KuroCoreOutput alloc]initWithSecrets:@[@"isolated-unused-secret"]];
    CHECK([session setOutputStdout:[output writer:0] stderr:[output writer:1] error:&error]);
    struct proc_bsdinfo selfInfo={0};CHECK(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&selfInfo,sizeof(selfInfo))==sizeof(selfInfo));
    NSDictionary *identity=@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":Hash(executable),@"startSeconds":@(selfInfo.pbi_start_tvsec),@"startMicros":@(selfInfo.pbi_start_tvusec)};
    __block NSUInteger reads=0,prepared=0,cleaned=0;
    BOOL admitted=[session setSupervisionSource:^NSDictionary *(NSString **problem) {
      reads++;if(scenario==1 && reads==1){Fail(problem,@"isolated source unavailable");return nil;}
      if((scenario==2 && reads==2)||(scenario==3 && reads==3)){NSMutableDictionary *changed=[identity mutableCopy];changed[@"startMicros"]=@((selfInfo.pbi_start_tvusec+1)%1000000);return changed;}
      if(scenario==4 && reads==1){NSMutableDictionary *changed=[identity mutableCopy];changed[@"extra"]=@YES;return changed;}
      return identity;
    } error:&error];
    CHECK(admitted==(scenario!=1&&scenario!=4));CHECK(reads==1&&!session.child&&!Exists(work)&&!Exists(journal)&&session.off);
    if(!admitted) {
      CHECK([error containsString:@"before work creation"]);
      [output closeWriters];CHECK([output finishTo:directory error:&error]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);continue;
    }
    Put([work stringByAppendingPathComponent:@"config.json"],config,0600);CHECK([session prepareWorkCache:&error]);
    if(scenario!=5)CHECK(([session setLaunchEvidence:@{@"configSHA256":Hash(config),@"coreSHA256":Hash(executable),@"template":@"macos-dual-stack-v1"} error:&error]));
    BOOL launched=[session spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:work beforeResume:^BOOL(NSString **problem) {
      (void)problem;prepared++;NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL);CHECK(KuroRestartRecord(record,NULL));CHECK([record[@"supervision"]isEqual:identity]);return YES;
    } afterReap:^BOOL(NSString **problem) {
      cleaned++;NSDictionary *cache=KuroWorkCacheSnapshot(directory,geteuid(),problem);if(!cache||![session recordReapedWorkCache:cache error:problem])return NO;
      return !unlink([work stringByAppendingPathComponent:@"cache.db"].fileSystemRepresentation)&&!unlink([work stringByAppendingPathComponent:@"config.json"].fileSystemRepresentation)&&!rmdir(work.fileSystemRepresentation);
    } error:&error];
    CHECK(launched==(scenario==0));CHECK(reads==(scenario==0||scenario==3?3:scenario==2?2:1));
    if(launched) {CHECK(prepared==1&&Exists(journal)&&session.child>0);CHECK(![session setSupervisionSource:^NSDictionary *(NSString **failure){(void)failure;return identity;} error:&error]);CHECK([session stop:&error]);CHECK(session.off&&cleaned==1);NSDictionary *proof=[session completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(proof)&&[proof[@"owner"][@"supervision"]isEqual:identity]);}
    else {CHECK(!session.child);CHECK(prepared==(scenario==3?1:0));if(scenario==2){CHECK(!session.off&&Exists(work)&&!Exists(journal)&&!cleaned);}if(scenario==3){CHECK(session.off&&cleaned==1);}CHECK(scenario==2 || !Exists(journal));}
    [output closeWriters];CHECK([output finishTo:directory error:&error]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native supervision session: setter first snapshot rejects nil/malformed before work; 6 admission/held-child cases preserve three samples and publish/resume mismatch refusal; optional held provenance only, no restart authority");
}
