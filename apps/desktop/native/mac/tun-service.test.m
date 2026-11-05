#import "tun-service.m"
// This branch is compiled only into the ordinary-user test binary. No Core/network.
static void ServiceFixtureStage(int trace, const char *stage, int failure, size_t pathBytes) {
  (void)dprintf(trace,"fixture-stage=%s monotonicMs=%llu pid=%d errno=%d pathBytes=%zu capacity=%zu\n",stage,(unsigned long long)KuroMonotonicMilliseconds(),getpid(),failure,pathBytes,sizeof(((struct sockaddr_un *)0)->sun_path));
}
static int ServiceFixtureListener(NSString *path, int trace) {
  struct sockaddr_un address={.sun_family=AF_UNIX};size_t length=strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));
  if(length>=sizeof(address.sun_path)){ServiceFixtureStage(trace,"path-too-long",ENAMETOOLONG,length);errno=ENAMETOOLONG;return -1;}
  int listener=socket(AF_UNIX,SOCK_STREAM,0),failure=errno;
  if(listener<0){ServiceFixtureStage(trace,"socket-failed",failure,length);errno=failure;return -1;}
  if(bind(listener,(struct sockaddr *)&address,sizeof(address))){failure=errno;close(listener);ServiceFixtureStage(trace,"bind-failed",failure,length);errno=failure;return -1;}
  if(listen(listener,4)){failure=errno;close(listener);ServiceFixtureStage(trace,"listen-failed",failure,length);errno=failure;return -1;}
  ServiceFixtureStage(trace,"listener-ready",0,length);return listener;
}
static void ServiceFixtureListenerTests(void) {
  char temporary[]="/tmp/kuro-fixture-listener-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));NSString *base=@(canonical),*path=[base stringByAppendingPathComponent:@"core.sock"],*trace=[base stringByAppendingPathComponent:@"trace.log"];
  int fd=open(trace.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);
  int listener=ServiceFixtureListener(path,fd);CHECK(listener>=0);
  errno=0;CHECK(ServiceFixtureListener(path,fd)==-1&&errno==EADDRINUSE);
  struct stat original={0};CHECK(!lstat(path.fileSystemRepresentation,&original)&&S_ISSOCK(original.st_mode));
  NSString *longPath=[base stringByAppendingPathComponent:[@"x"stringByPaddingToLength:108 withString:@"x" startingAtIndex:0]];errno=0;CHECK(ServiceFixtureListener(longPath,fd)==-1&&errno==ENAMETOOLONG);
  struct stat preserved={0};CHECK(!lstat(path.fileSystemRepresentation,&preserved)&&original.st_dev==preserved.st_dev&&original.st_ino==preserved.st_ino);CHECK(!close(fd));
  NSString *evidence=[[NSString alloc]initWithData:[NSData dataWithContentsOfFile:trace] encoding:NSUTF8StringEncoding];
  CHECK(([evidence containsString:@"fixture-stage=listener-ready"]&&[evidence containsString:@"fixture-stage=bind-failed"]&&[evidence containsString:[NSString stringWithFormat:@"errno=%d",EADDRINUSE]]&&[evidence containsString:@"fixture-stage=path-too-long"]&&[evidence containsString:@"pathBytes="]));
  CHECK(!close(listener)&&!unlink(path.fileSystemRepresentation));CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("fixture listener evidence: real temporary Unix listen success, EADDRINUSE and overlong path preserve existing socket; no Core/system network");
}
// Read only already-redacted evidence; never runtime config or raw capture pipes.
static void ServiceFixtureReportMismatch(NSString *directory, NSUInteger scenario, uint64_t elapsed) {
  fprintf(stderr,"service diagnostic open mismatch scenario=%lu elapsedMs=%llu directory=%s\n",(unsigned long)scenario,(unsigned long long)elapsed,directory.fileSystemRepresentation);
  NSString *root=[directory stringByAppendingPathComponent:@"TunDiagnostics"];
  for(NSString *name in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:root error:NULL]) {
    NSString *session=[root stringByAppendingPathComponent:name];
    for(NSString *file in @[@"diagnostics.json",@"stderr.log"]) {
      NSData *bytes=ReadProtected(directory,[session stringByAppendingPathComponent:file],geteuid(),NULL);if(!bytes)continue;
      fprintf(stderr,"redacted %s (%lu bytes, first <=4096):\n",file.UTF8String,(unsigned long)bytes.length);fwrite(bytes.bytes,1,MIN(bytes.length,(NSUInteger)4096),stderr);fputc('\n',stderr);
    }
  }
}
static void SupervisionTests(void);
static int ServiceFixtureMain(int argc,const char **argv) {
  if(argc==3 && !strcmp(argv[1],"--supervision-output-fixture")) {
    if(geteuid()==0)return 91;
    int mode=atoi(argv[2]);if(mode==1)return 37;
    if(mode==2){const unsigned char invalid[]={0xc3,0x28};return write(STDOUT_FILENO,invalid,sizeof(invalid))==sizeof(invalid)?0:92;}
    if(mode==3){unsigned char bytes[4096];memset(bytes,'x',sizeof(bytes));for(NSUInteger i=0;i<40;i++)if(write(STDOUT_FILENO,bytes,sizeof(bytes))!=sizeof(bytes))return 92;return 0;}
    if(mode==4)for(;;)pause();
    if(mode==5){const char nul[]={'a',0,'b'};return write(STDOUT_FILENO,nul,sizeof(nul))==sizeof(nul)?0:92;}
    return write(STDOUT_FILENO,"fixture job\n",12)==12?0:92;
  }
  if(argc==2 && !strcmp(argv[1],"--supervision-tests")) {CHECK(geteuid()!=0);alarm(15);CHECK(getpgrp()==getpid()||!setpgid(0,0));SupervisionTests();return 0;}
  if(argc!=5 || strcmp(argv[1],"-d") || strcmp(argv[3],"-f"))return -1;
  if(geteuid()==0)return 91;
  ServiceFixtureStage(STDERR_FILENO,"entry",0,0);
  @autoreleasepool {
    NSString *work=[NSString stringWithUTF8String:argv[2]],*config=[NSString stringWithUTF8String:argv[4]];
    if(![config isEqual:[work stringByAppendingPathComponent:@"config.json"]])return 92;
    NSDictionary *value=KuroDecodeJSON([NSData dataWithContentsOfFile:config],128*1024,NULL);
    NSString *socketPath=[work stringByAppendingPathComponent:@"core.sock"];
    if(![value[@"external-controller-unix"] isEqual:socketPath] || !KuroText(value[@"secret"],128))return 93;
    char cwd[PATH_MAX]; if(!getcwd(cwd,sizeof(cwd)) || ![work isEqual:[NSString stringWithUTF8String:cwd]])return 94;
    struct stat initialCache={0};NSString *cache=[work stringByAppendingPathComponent:@"cache.db"];
    if(lstat(cache.fileSystemRepresentation,&initialCache)||!SafeMetadata(initialCache,geteuid(),NO)||(initialCache.st_mode&07777)!=0600||initialCache.st_size!=0)return 99;
    ServiceFixtureStage(STDERR_FILENO,"runtime-validated",0,strlen(socketPath.fileSystemRepresentation));
    NSString *fixtureName=Executable().lastPathComponent;
    if([fixtureName hasPrefix:@"core-diagnostic"]) {
      NSString *credential=[value[@"proxies"]firstObject][@"password"]?:@"none";
      NSData *out=Bytes([NSString stringWithFormat:@"fixture stdout secret=%@ credential=%@\n",value[@"secret"],credential]),*err=Bytes([NSString stringWithFormat:@"fixture stderr secret=%@ credential=%@\n",value[@"secret"],credential]);
      if(write(STDOUT_FILENO,out.bytes,out.length)!=(ssize_t)out.length||write(STDERR_FILENO,err.bytes,err.length)!=(ssize_t)err.length)return 96;
      if([fixtureName isEqual:@"core-diagnostic-overflow"]) {
        unsigned char block[4096];memset(block,'x',sizeof(block));
        for(NSUInteger i=0;i<40;i++)for(int fd=1;fd<=2;fd++) {NSUInteger offset=0;while(offset<sizeof(block)){ssize_t count=write(fd,block+offset,sizeof(block)-offset);if(count<0&&errno==EINTR)continue;if(count<=0)return 96;offset+=(NSUInteger)count;}}
      }
      if([fixtureName isEqual:@"core-diagnostic-exit37"]||[fixtureName isEqual:@"core-diagnostic-overflow"])return 37;
      if([fixtureName isEqual:@"core-diagnostic-timeout"])for(;;)pause();
    }
    if([Executable().lastPathComponent isEqual:@"core-exit"])return 95;
    if([Executable().lastPathComponent isEqual:@"core-must-not-run"]) { if(!WriteNew([work stringByAppendingPathComponent:@"resumed"],Bytes(@"unexpected resume"),0600,NULL))return 96; }
    if([Executable().lastPathComponent isEqual:@"core-config-changed"]) { if(![Bytes(@"changed") writeToFile:config atomically:NO])return 96; }
    if([Executable().lastPathComponent isEqual:@"core-unknown-work"]) {
      if(!WriteNew([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600,NULL))return 96;
    }
    int listener=ServiceFixtureListener(socketPath,STDERR_FILENO);if(listener<0)return 97;
    for(;;) @autoreleasepool {
      int peer=accept(listener,NULL,NULL); if(peer<0)continue;
      unsigned char bytes[8192]; ssize_t count=recv(peer,bytes,sizeof(bytes),0);
      NSString *request=count>0 ? [[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding] : nil;
      if(![request containsString:[NSString stringWithFormat:@"Authorization: Bearer %@\r\n",value[@"secret"]]]) { close(peer); continue; }
      NSString *reply=nil;
      if([request hasPrefix:@"GET /version HTTP/1.1\r\n"]) {
        ServiceFixtureStage(STDERR_FILENO,"version-request",0,strlen(socketPath.fileSystemRepresentation));
        NSString *body=@"{\"version\":\"fixture-1\"}";
        reply=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",(unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding],body];
        if([Executable().lastPathComponent isEqual:@"core-chunked"])reply=@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n";
        if([Executable().lastPathComponent isEqual:@"core-duplicate-header"])reply=@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\n{}";
        if([Executable().lastPathComponent isEqual:@"core-bad-version"])reply=@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
      } else {
        NSRange bodyStart=[request rangeOfString:@"\r\n\r\n"];
        NSDictionary *body=bodyStart.location==NSNotFound ? nil : KuroDecodeJSON(Bytes([request substringFromIndex:NSMaxRange(bodyStart)]),1024,NULL);
        BOOL mode=[request hasPrefix:@"PATCH /configs HTTP/1.1\r\n"] && Keys(body,@[@"mode"]) && [body[@"mode"] isEqual:@"global"];
        BOOL select=[request hasPrefix:@"PUT /proxies/G%2F%23 HTTP/1.1\r\n"] && Keys(body,@[@"name"]) && [body[@"name"] isEqual:@"DIRECT"];
        if(select && ![Bytes(@"fixture bbolt cache")writeToFile:cache atomically:NO])return 98;
        if(mode||select)reply=@"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
      }
      if(!reply)reply=@"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
      NSData *encoded=Bytes(reply); (void)send(peer,encoded.bytes,encoded.length,MSG_NOSIGNAL); close(peer);
    }
  }
}
static NSDictionary *ServiceRead(int peer) {
  NSMutableData *data=[NSMutableData data]; uint64_t deadline=KuroMonotonicMilliseconds()+3000;
  while(KuroMonotonicMilliseconds()<deadline) {
    struct pollfd poller={.fd=peer,.events=POLLIN}; if(poll(&poller,1,100)<=0)continue;
    char bytes[4096]; ssize_t count=recv(peer,bytes,sizeof(bytes),0); if(count<=0)break;
    [data appendBytes:bytes length:(NSUInteger)count]; if(memchr(bytes,'\n',(NSUInteger)count))break;
  }
  return KuroDecodeJSON(data,65536,NULL);
}
static void ServiceSend(int peer,NSDictionary *value) {
  NSMutableData *data=[JSONData(value) mutableCopy]; [data appendBytes:"\n" length:1]; CHECK(send(peer,data.bytes,data.length,MSG_NOSIGNAL)==(ssize_t)data.length);
}
static KuroTunServiceHooks *ServiceHooks(void) {
  KuroTunServiceHooks *hooks=[KuroTunServiceHooks new];
  hooks.authorize=^BOOL(int peer,NSString *digest,NSString **error) { (void)peer;(void)error;return Match(digest,@"\\A[0-9a-f]{64}\\z"); };
  hooks.preflight=^BOOL(NSDictionary *config,NSString **error) { (void)error;return config!=nil; };
  hooks.beforeStart=^BOOL(NSString **error) { (void)error;return YES; };
  hooks.beforeResume=^BOOL(NSString **error) { (void)error;return YES; };
  hooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **error) { return KuroCompletedStopEvidence(proof)||Fail(error,@"fixture requires exact completed owner evidence"); };
  hooks.ready=^BOOL(pid_t child,NSString *session,NSString **error) { (void)session;struct proc_bsdinfo value={0};int read=proc_pidinfo(child,PROC_PIDTBSDINFO,0,&value,sizeof(value));return (read==sizeof(value) && value.pbi_ppid==(uint32_t)getpid()) || Fail(error,[NSString stringWithFormat:@"fixture readiness process read=%d parent=%u expected=%d child=%d",read,value.pbi_ppid,getpid(),child]); };
  hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **error) { (void)child;(void)session;(void)error;return YES; };
  hooks.recoverNetwork=^BOOL(NSString *session,NSString **error) { (void)session;(void)error;return YES; };
  hooks.identityValid=^BOOL(int peer) { (void)peer;return YES; };
  return hooks;
}
static NSData *ServiceOpen(void) {
  NSMutableDictionary *config=ValidTunConfig(); config[@"groups"]=@[@{@"name":@"G/#",@"type":@"select",@"proxies":@[@"DIRECT",@"REJECT"]}];
  return JSONData(@{@"version":@2,@"operation":@"open",@"config":config});
}
static void RestartWorkTests(void) {
  for(NSUInteger scenario=0;scenario<7;scenario++) {
    char temporary[]="/tmp/kuro-rwork-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=[NSString stringWithUTF8String:canonical],*work=[directory stringByAppendingPathComponent:@"session-work"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSString *config=[work stringByAppendingPathComponent:@"config.json"],*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
    Put(config,Bytes(@"runtime config"),0600);
    struct sockaddr_un address={.sun_family=AF_UNIX};CHECK(strlcpy(address.sun_path,socketPath.fileSystemRepresentation,sizeof(address.sun_path))<sizeof(address.sun_path));
    int descriptor=socket(AF_UNIX,SOCK_STREAM,0);CHECK(descriptor>=0);CHECK(!bind(descriptor,(struct sockaddr *)&address,sizeof(address)));
    struct stat value={0};CHECK(!lstat(socketPath.fileSystemRepresentation,&value));
    NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;
    record[@"work"]=@{@"configSHA256":Hash(Bytes(@"runtime config")),@"socket":@{@"device":@((unsigned long long)value.st_dev),@"inode":@(value.st_ino)}};
    if(scenario==1)Put(config,Bytes(@"changed config"),0600);
    if(scenario==2)record[@"work"]=@{@"configSHA256":Hash(Bytes(@"runtime config")),@"socket":@{@"device":@((unsigned long long)value.st_dev),@"inode":@(value.st_ino+1)}};
    if(scenario==3)Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600);
    if(scenario==4) {
      CHECK(!unlink(config.fileSystemRepresentation));NSString *target=[directory stringByAppendingPathComponent:@"empty"];Put(target,NSData.data,0600);CHECK(!symlink(target.fileSystemRepresentation,config.fileSystemRepresentation));
      record[@"work"]=@{@"configSHA256":Hash(NSData.data),@"socket":record[@"work"][@"socket"]};
    }
    Put(journal,JSONData(record),0600);NSData *original=[NSData dataWithContentsOfFile:journal];
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:[directory stringByAppendingPathComponent:@"unused"] hooks:ServiceHooks()];
    KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;observed.fixtureRestartGroupReader=RestartGroupReader;
    RestartObservation=0;RestartMode=0;RestartReappearAt=scenario==6?5:0;
    __block NSUInteger network=0;
    BOOL ok=[observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) { (void)failure;network++;return YES; }
      workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) {
        __block NSUInteger checks=0;
        KuroSessionHook checked=^BOOL(NSString **problem) {
          checks++;if(scenario==5&&checks==1)CHECK(!chmod(config.fileSystemRepresentation,0777));
          return stillAbsent(problem);
        };
        return [service recoverExitedWork:owner stillAbsent:checked error:failure];
      } error:&error];
    CHECK(ok==(scenario==0));CHECK(network==1);CHECK(observed.child==0);
    if(ok) { CHECK(observed.off);CHECK(!Exists(journal)&&!Exists(work)); }
    else {
      CHECK(error.length>0&&!observed.off);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:original]);CHECK(Exists(socketPath));
      if(scenario!=6)CHECK(Exists(config));
      if(scenario==6) {
        CHECK(!Exists(config)); // Config removed, next identity sample refused socket deletion.
        RestartObservation=0;RestartReappearAt=0;
        CHECK([observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) { (void)failure;return YES; } workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) { return [service recoverExitedWork:owner stillAbsent:stillAbsent error:failure]; } error:&error]);
        CHECK(observed.off&&!Exists(journal)&&!Exists(work));
      }
    }
    close(descriptor);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native restart work: exact runtime/socket cleanup, mismatch/unknown/symlink/unsafe reread rejection and partial cleanup retry passed (temporary sockets only)");
}
static void RestartCacheTests(void) {
  for(NSUInteger scenario=0;scenario<17;scenario++) {
    char temporary[]="/tmp/kuro-rcache-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSString *config=[work stringByAppendingPathComponent:@"config.json"],*cache=[work stringByAppendingPathComponent:@"cache.db"];
    Put(config,Bytes(@"runtime config"),0600);Put(cache,Bytes(@"fixture bbolt cache"),0600);
    NSDictionary *cacheIdentity=KuroWorkCacheSnapshot(directory,geteuid(),&error);CHECK(cacheIdentity&&KuroWorkCacheReceipt(cacheIdentity));
    NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;
    NSMutableDictionary *receipt=[@{@"configSHA256":Hash(Bytes(@"runtime config")),@"socket":NSNull.null,@"cache":cacheIdentity}mutableCopy];record[@"work"]=receipt;
    if(scenario==9){[receipt removeObjectForKey:@"cache"];receipt[@"cacheOrigin"]=@{@"device":cacheIdentity[@"device"],@"inode":cacheIdentity[@"inode"],@"owner":@(geteuid()),@"mode":@0600};}
    if(scenario==1)[receipt removeObjectForKey:@"cache"]; // Legacy format2 cannot adopt a newly discovered cache.
    if(scenario==2)Put(cache,Bytes(@"changed"),0600);
    if(scenario==3) { CHECK(!unlink(cache.fileSystemRepresentation));CHECK(!symlink(config.fileSystemRepresentation,cache.fileSystemRepresentation)); }
    if(scenario==4)CHECK(!chmod(cache.fileSystemRepresentation,0666));
    if(scenario==5)Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600);
    if(scenario==8) { NSMutableDictionary *bad=[cacheIdentity mutableCopy];bad[@"path"]=@"/tmp/arbitrary";receipt[@"cache"]=bad; }
    Put(journal,JSONData(record),0600);NSData *original=[NSData dataWithContentsOfFile:journal];
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:[directory stringByAppendingPathComponent:@"unused"] hooks:ServiceHooks()];
    KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;observed.fixtureRestartGroupReader=RestartGroupReader;
    CHECK(![observed recordReapedWorkCache:cacheIdentity error:&error]); // No held/reaped owner in a fresh instance.
    RestartObservation=0;RestartMode=0;RestartReappearAt=0;RestartGroupMode=scenario>=10&&scenario<=15?scenario-9:0;__block NSUInteger network=0,checks=0;
    BOOL ok=[observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) { (void)failure;network++;return YES; } workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) {
      return [service recoverExitedWork:owner stillAbsent:^BOOL(NSString **problem) {
        checks++;if(checks==2 && scenario==16)RestartGroupMode=1;
        if(checks==2 && scenario==6)Put(cache,Bytes(@"changed before unlink"),0600);
        if(checks==2 && scenario==7)return Fail(problem,@"fixture identity observation uncertain after partial cleanup");
        return stillAbsent(problem);
      } error:failure];
    } error:&error];
    CHECK(ok==(scenario==0));CHECK(observed.child==0);
    if(ok)CHECK(observed.off&&!Exists(work)&&!Exists(journal));
    else {
      CHECK(error.length>0&&Exists(cache)&&[[NSData dataWithContentsOfFile:journal]isEqual:original]);
      if(scenario<=5 || scenario==8 || (scenario>=10&&scenario<=15))CHECK(Exists(config)); // Complete validation precedes any removal.
      if(scenario==7 || scenario==16) {
        CHECK(!Exists(config));RestartGroupMode=0; // Retry accepts an already-removed exact work item.
        CHECK([observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) { (void)failure;return YES; } workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) { return [service recoverExitedWork:owner stillAbsent:stillAbsent error:failure]; } error:&error]);
        CHECK(observed.off&&!Exists(work)&&!Exists(journal));
      }
    }
    CHECK(network==((scenario==8 || (scenario>=10&&scenario<=15))?0:1));CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native production cache: closed durable receipt, legacy refusal, changed/symlink/writable/unknown preservation, exact removal, old-group nonempty/unknown rejection and partial cleanup retry passed; no Core/network");
}
static void ServiceWait(dispatch_semaphore_t event) {
  CHECK(!dispatch_semaphore_wait(event,dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC)));
}
// The second connection is an independently dispatched, closed V1 recovery adapter.
// Authorization is represented by ServiceHooks, not a production authorization bypass.
static BOOL ServiceRecoverySocket(KuroTunService *service) {
  int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int server=peers[0];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
    NSDictionary *request=ServiceRead(server);NSString *error=nil;
    BOOL ok=Keys(request,@[@"version",@"operation"]) && [request[@"version"]isEqual:@1] && [request[@"operation"]isEqual:@"recover"] && [service recoverNetworkOnly:&error];
    CHECK(KuroServiceReply(server,ok?@{@"version":@1,@"ok":@YES,@"status":[service statusSnapshot]}:@{@"version":@1,@"ok":@NO,@"error":error?:@"invalid recovery fixture request"}));close(server);
  });
  ServiceSend(peers[1],@{@"version":@1,@"operation":@"recover"});NSDictionary *reply=ServiceRead(peers[1]);close(peers[1]);
  CHECK(reply && [reply[@"version"]isEqual:@1]);
  if([reply[@"ok"]boolValue])CHECK([reply[@"status"][@"state"]isEqual:@"off"]);
  return [reply[@"ok"]boolValue];
}
static void RetainedRecoveryTests(void) {
  for(NSUInteger scenario=0;scenario<8;scenario++) {
    char temporary[]="/tmp/kuro-retain-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*core=[directory stringByAppendingPathComponent:@"core"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*work=[directory stringByAppendingPathComponent:@"session-work"];
    Put(core,[NSData dataWithContentsOfFile:Executable()],0755);
    NSObject *guard=[NSObject new];__block BOOL allowed=NO;__block NSUInteger recoveries=0,proofs=0;__block pthread_t owner;
    KuroTunServiceHooks *hooks=ServiceHooks();
    hooks.preflight=^BOOL(NSDictionary *config,NSString **error) { (void)config;(void)error;owner=pthread_self();return YES; };
    dispatch_semaphore_t retained=dispatch_semaphore_create(0),entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
    __block BOOL blockRecovery=NO;
    hooks.recoverNetwork=^BOOL(NSString *session,NSString **error) {
      CHECK(pthread_equal(owner,pthread_self()));CHECK(session.length>0);
      BOOL permit,pause;@synchronized(guard){recoveries++;permit=allowed;pause=blockRecovery;}
      if(pause){dispatch_semaphore_signal(entered);ServiceWait(release);}
      return permit || Fail(error,@"injected same-thread DNS readback failure");
    };
    hooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **error) {
      CHECK(pthread_equal(owner,pthread_self()));CHECK(KuroCompletedStopEvidence(proof));
      CHECK(Exists(journal)&&!Exists(work));CHECK([Hash(ReadProtected(directory,journal,geteuid(),NULL))isEqual:proof[@"ownerSHA256"]]);@synchronized(guard){proofs++;}
      return KuroCompletedStopEvidence(proof)||Fail(error,@"fixture stop evidence missing");
    };
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:core hooks:hooks];
    service.fixtureRetained=^{CHECK(pthread_equal(owner,pthread_self()));dispatch_semaphore_signal(retained);};
    int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int peer=peers[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *error=nil;(void)[service serveOpenFrame:ServiceOpen() peer:peer error:&error];close(peer);dispatch_semaphore_signal(done);});
    NSDictionary *open=ServiceRead(peers[1]);CHECK([open[@"ok"]boolValue]);NSString *session=open[@"session"];
    CHECK(!ServiceRecoverySocket(service)); // Live owner cannot be recovered/adopted.
    if(scenario==6)shutdown(peers[1],SHUT_RDWR);
    else {ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":session,@"sequence":@1});CHECK(![ServiceRead(peers[1])[@"ok"]boolValue]);}
    ServiceWait(retained);CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);CHECK(Exists(journal)&&Exists(work));
    NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL);pid_t child=[record[@"pid"]intValue];
    CHECK(child>0 && waitpid(child,NULL,WNOHANG)==-1 && errno==ECHILD); // Already reaped, not a stored-PID stop capability.
    NSUInteger before;@synchronized(guard){before=recoveries;}CHECK(before>=2);
    CHECK(![service recoverHeldSession:NSUUID.UUID.UUIDString deadline:KuroMonotonicMilliseconds()+500 error:NULL]);
    CHECK(![service writeMode:@"global" error:NULL]);CHECK(![service selectProxy:@"DIRECT" group:@"G/#" error:NULL]);
    int concurrent[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,concurrent));CHECK(![service serveOpenFrame:ServiceOpen() peer:concurrent[0] error:NULL]);CHECK(![ServiceRead(concurrent[1])[@"ok"]boolValue]);close(concurrent[0]);close(concurrent[1]);
    [service requestStop]; // Ordinary stop does not destroy the retained cleanup capability.
    CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);
    if(scenario==1){CHECK(!ServiceRecoverySocket(service));@synchronized(guard){CHECK(recoveries==before+1);}CHECK(Exists(journal)&&Exists(work));}
    if(scenario==2){
      NSData *original=ReadProtected(directory,journal,geteuid(),NULL);NSMutableDictionary *changed=[record mutableCopy];changed[@"session"]=NSUUID.UUID.UUIDString;Put(journal,JSONData(changed),0600);
      @synchronized(guard){allowed=YES;}CHECK(!ServiceRecoverySocket(service));@synchronized(guard){CHECK(recoveries==before);}CHECK(Exists(work)&&Exists(journal));Put(journal,original,0600);
    }
    if(scenario==3){
      service.fixtureBeforeRecovery=^{dispatch_semaphore_signal(entered);ServiceWait(release);};
      dispatch_semaphore_t expired=dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{CHECK(![service recoverHeldSession:session deadline:KuroMonotonicMilliseconds()+80 error:NULL]);dispatch_semaphore_signal(expired);});
      ServiceWait(entered);ServiceWait(expired);
      // The next queued call is admitted only after the cancelled one is consumed.
      dispatch_semaphore_t consumed=dispatch_semaphore_create(0);
      service.fixtureRecoveryCompleted=^{dispatch_semaphore_signal(consumed);};service.fixtureBeforeRecovery=nil;dispatch_semaphore_signal(release);ServiceWait(consumed);service.fixtureRecoveryCompleted=nil;
      @synchronized(guard){CHECK(recoveries==before);}CHECK(Exists(journal)&&Exists(work));
    }
    if(scenario==4){
      @synchronized(guard){allowed=YES;blockRecovery=YES;}
      dispatch_semaphore_t recovered=dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{CHECK(ServiceRecoverySocket(service));dispatch_semaphore_signal(recovered);});
      ServiceWait(entered);CHECK(!ServiceRecoverySocket(service));CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);
      dispatch_semaphore_signal(release);ServiceWait(recovered);
    } else if(scenario==5 || scenario==7){
      if(scenario==7){ // Expired admission performs no cleanup, even if the network would now allow it.
        @synchronized(guard){allowed=YES;}CHECK(![service recoverHeldSession:session deadline:KuroMonotonicMilliseconds() error:NULL]);
      }
      [service requestShutdown];ServiceWait(done);CHECK(Exists(journal)&&Exists(work));CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);
      @synchronized(guard){CHECK(recoveries==before&&proofs==0);}CHECK(!ServiceRecoverySocket(service));
    } else {@synchronized(guard){allowed=YES;}CHECK(ServiceRecoverySocket(service));}
    if(scenario!=5&&scenario!=7){ServiceWait(done);CHECK(!Exists(journal)&&!Exists(work));CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]);@synchronized(guard){CHECK(proofs==1);}}
    close(peers[1]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native retained recovery: 8 harmless held-child cases; original pthread retained, second-socket explicit recovery, owner mismatch, expiry/cancellation, concurrent/open/write rejection, EOF and shutdown preservation; no Core/network");
}

static void ServiceCachePreparationTests(void) {
  for(NSUInteger scenario=0;scenario<4;scenario++) {
    char temporary[]="/tmp/kuro-sorigin-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*cache=[work stringByAppendingPathComponent:@"cache.db"],*core=[directory stringByAppendingPathComponent:@"core-must-not-run"];
    Put(core,[NSData dataWithContentsOfFile:Executable()],0755);
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:core hooks:ServiceHooks()];
    __block NSUInteger prepared=0;
    service.fixtureBeforeCachePrepare=^(KuroOwnedSession *session){
      prepared++;CHECK(Exists(work)&&Exists([work stringByAppendingPathComponent:@"config.json"]));
      if(scenario==0)Put(cache,Bytes(@"preserve unknown existing cache"),0600);
      if(scenario==1)session.fixtureFailWorkCacheSync=YES;
      if(scenario==2)session.fixtureFailOwnerPublish=YES;
    };
    if(scenario==3)service.fixtureBeforeResume=^{CHECK(!rename(cache.fileSystemRepresentation,[work stringByAppendingPathComponent:@"original-cache"].fileSystemRepresentation));Put(cache,NSData.data,0600);};
    __weak KuroTunService *weak=service;service.fixtureRetained=^{[weak requestShutdown];};
    int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));NSString *error=nil;
    CHECK(![service serveOpenFrame:ServiceOpen() peer:peers[0] error:&error]);CHECK(prepared==1&&error.length>0);
    CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]&&Exists(work)&&Exists(cache));
    CHECK(!Exists([work stringByAppendingPathComponent:@"resumed"])); // Every failure remained before actual Core resume.
    CHECK(![service recoverNetworkOnly:NULL]);CHECK(Exists(work)&&Exists(cache));
    if(scenario==0)CHECK([[NSData dataWithContentsOfFile:cache]isEqual:Bytes(@"preserve unknown existing cache")]);
    close(peers[0]);close(peers[1]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native service cache preparation: 4 actual startup-chain failures preserve work/unknown before resume (collision, cache fsync, owner publication, resume identity replacement); no Core/network");
}
static void ServiceDiagnosticTests(void) {
  ServiceFixtureListenerTests();
  for(NSUInteger scenario=0;scenario<8;scenario++) {
    char temporary[]="/tmp/kuro-diag-service-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*journal=[directory stringByAppendingPathComponent:@"owner.json"];
    NSString *name=scenario==1?@"core-diagnostic-exit37":scenario==2?@"core-diagnostic-overflow":scenario==3?@"core-diagnostic-timeout":@"core-diagnostic";
    NSString *core=[directory stringByAppendingPathComponent:name];Put(core,[NSData dataWithContentsOfFile:Executable()],0755);
    KuroTunServiceHooks *hooks=ServiceHooks();__block NSUInteger recovered=0;
    hooks.recoverNetwork=^BOOL(NSString *session,NSString **error){(void)session;(void)error;recovered++;return YES;};
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:core hooks:hooks];
    dispatch_semaphore_t done=dispatch_semaphore_create(0),retained=dispatch_semaphore_create(0);
    service.fixtureRetained=^{dispatch_semaphore_signal(retained);};
    if(scenario==4)service.fixtureBeforeDiagnosticFinish=^(NSString *path){CHECK(!chmod(path.fileSystemRepresentation,0755));};
    if(scenario==7)service.fixtureBeforeWorkCreation=^{FixtureDirectory(work);Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"unknown work collision"),0600);};
    if(scenario==5)service.fixtureBeforeDiagnosticFinish=^(NSString *path){NSString *file=[path stringByAppendingPathComponent:@"diagnostics.json"];if(!Exists(file))Put(file,Bytes(@"unknown diagnostic checkpoint"),0600);};
    // A SHA ending in 'e' would redact the invalid-frame reason's final 'e'.
    // Other cases retain the SHA-suffix credential to exercise exact hash summaries.
    NSMutableDictionary *config=ValidTunConfig();NSString *coreDigest=Hash([NSData dataWithContentsOfFile:core]);unichar credentialPrefix=scenario==6?'!':[coreDigest characterAtIndex:coreDigest.length-1];NSString *credential=[NSString stringWithFormat:@"%C-fixture-credential-unique\"/",credentialPrefix];
    config[@"proxies"]=@[@{@"name":@"proxy",@"type":@"socks5",@"server":@"192.0.2.10",@"port":@1080,@"username":@"fixture-user-unique",@"password":credential,@"tls":@NO}];
    int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int peer=peers[0];
    __block BOOL result=NO;__block NSString *failure=nil;
    uint64_t started=KuroMonotonicMilliseconds();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *error=nil;result=[service serveOpenFrame:JSONData(@{@"version":@2,@"operation":@"open",@"config":config}) peer:peer error:&error];failure=error;close(peer);dispatch_semaphore_signal(done);});
    NSDictionary *opened=ServiceRead(peers[1]);BOOL accepted=scenario==0||(scenario>=4&&scenario<=6);
    if([opened[@"ok"]boolValue]!=accepted)ServiceFixtureReportMismatch(directory,scenario,KuroMonotonicMilliseconds()-started);
    CHECK([opened[@"ok"]boolValue]==accepted);
    NSString *secret=nil;
    if(accepted) {
      NSDictionary *runtime=ReadJSON(directory,[work stringByAppendingPathComponent:@"config.json"],geteuid(),NULL);secret=runtime[@"secret"];CHECK(secret.length>0);
      if(scenario==6) { // Invalid frame is a supervision failure, not an empty successful diagnostic.
        ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":opened[@"session"],@"sequence":@99});
      } else {
        ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":opened[@"session"],@"sequence":@1});
        NSDictionary *stopped=ServiceRead(peers[1]);CHECK([stopped[@"ok"]boolValue]==(scenario==0));
      }
    }
    NSArray *names=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:[directory stringByAppendingPathComponent:@"TunDiagnostics"] error:NULL];CHECK(names.count==1);
    NSString *evidence=[[directory stringByAppendingPathComponent:@"TunDiagnostics"]stringByAppendingPathComponent:names[0]];
    if(scenario==4||scenario==5) {
      ServiceWait(retained);CHECK(recovered>=2&&Exists(work)&&Exists(journal));CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);
      if(scenario==4){CHECK(!chmod(evidence.fileSystemRepresentation,0700));service.fixtureBeforeDiagnosticFinish=nil;CHECK(ServiceRecoverySocket(service));}
      else {[service requestShutdown];CHECK([[NSData dataWithContentsOfFile:[evidence stringByAppendingPathComponent:@"diagnostics.json"]]isEqual:Bytes(@"unknown diagnostic checkpoint")]);}
    }
    ServiceWait(done);CHECK(scenario==7?recovered==0:recovered>0);
    if(scenario!=5) {
      if(scenario==7)CHECK(Exists([work stringByAppendingPathComponent:@"unknown"])&&!Exists(journal)&&[service.statusSnapshot[@"state"]isEqual:@"unknown"]);
      else CHECK(!Exists(work)&&!Exists(journal));
      NSDictionary *metadata=ReadJSON(directory,[evidence stringByAppendingPathComponent:@"diagnostics.json"],geteuid(),NULL),*launch=ReadJSON(directory,[evidence stringByAppendingPathComponent:@"launch.json"],geteuid(),NULL),*redacted=ReadJSON(directory,[evidence stringByAppendingPathComponent:@"config.redacted.json"],geteuid(),NULL);
      CHECK(metadata&&launch&&redacted);CHECK([metadata[@"captureComplete"]boolValue]);CHECK([metadata[@"termination"][@"observed"]boolValue]!=(scenario==7));
      CHECK([metadata[@"networkRecovery"][@"attempted"]boolValue]!=(scenario==7));CHECK([metadata[@"networkRecovery"][@"restored"]boolValue]!=(scenario==7));
      CHECK([redacted[@"secret"]isEqual:@"[REDACTED]"]&&[redacted[@"proxies"][0][@"password"]isEqual:@"[REDACTED]"]);
      CHECK([launch[@"redactedConfigSHA256"]isEqual:Hash(ReadProtected(directory,[evidence stringByAppendingPathComponent:@"config.redacted.json"],geteuid(),NULL))]);
      CHECK([launch[@"coreSHA256"]isEqual:coreDigest]); // Password starts with this SHA's final character; summaries must remain exact.
      CHECK(![launch[@"environment"][@"HOME"]boolValue]&&[launch[@"environment"][@"LANG"]boolValue]);
      for(NSString *file in @[@"config.redacted.json",@"launch.json",@"stdout.log",@"stderr.log",@"diagnostics.json"]) {
        NSString *text=[[NSString alloc]initWithData:ReadProtected(directory,[evidence stringByAppendingPathComponent:file],geteuid(),NULL) encoding:NSUTF8StringEncoding];CHECK(text);
        CHECK(![text containsString:credential]);if(secret)CHECK(![text containsString:secret]);
        struct stat info={0};CHECK(!lstat([evidence stringByAppendingPathComponent:file].fileSystemRepresentation,&info)&&(info.st_mode&07777)==0600&&info.st_nlink==1);
      }
      NSString *out=[[NSString alloc]initWithData:ReadProtected(directory,[evidence stringByAppendingPathComponent:@"stdout.log"],geteuid(),NULL) encoding:NSUTF8StringEncoding];
      NSString *err=[[NSString alloc]initWithData:ReadProtected(directory,[evidence stringByAppendingPathComponent:@"stderr.log"],geteuid(),NULL) encoding:NSUTF8StringEncoding];
      if(scenario==7)CHECK(out.length==0&&err.length==0&&[metadata[@"stage"]isEqual:@"private runtime creation"]&&[metadata[@"error"]length]>0);
      else {
        CHECK([out containsString:@"fixture stdout secret=[REDACTED]"]&&[err containsString:@"fixture stderr secret=[REDACTED]"]);
        CHECK([err containsString:@"fixture-stage=entry"]&&[err containsString:@"fixture-stage=runtime-validated"]);
        if(accepted)CHECK([err containsString:@"fixture-stage=listener-ready"]&&[err containsString:@"fixture-stage=version-request"]);
        if(scenario==3)CHECK(![err containsString:@"fixture-stage=listener-ready"]);
      }
      if(scenario==1||scenario==2)CHECK([metadata[@"termination"][@"exitCode"]isEqual:@37]);
      if(scenario==2)CHECK([metadata[@"capture"][@"stdout"][@"bytesRead"]unsignedLongLongValue]>65536&&[metadata[@"capture"][@"stderr"][@"truncated"]boolValue]);
      if(scenario==3)CHECK([metadata[@"stage"]isEqual:@"private Core version readiness"]&&[metadata[@"termination"][@"signal"]isEqual:@15]);
      if(scenario==6)CHECK([metadata[@"error"]isEqual:@"invalid session frame or sequence"]&&[metadata[@"stopContext"][@"unexpected"]boolValue]);
    }
    if(scenario==0)CHECK(result);else if(scenario<4)CHECK(!result&&failure.length>0);
    close(peers[1]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native production diagnostics: 8 actual harmless service cases cover redacted startup/normal, exit37, overflow drain, timeout, failed-save explicit recovery, unknown checkpoint preservation and pre-cleanup invalid-frame reason; no Core/network");
}
static void PartialDNSServiceTests(void) {
  for(NSUInteger scenario=0;scenario<5;scenario++) {
    char temporary[]="/tmp/kuro-partial-dns-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));NSString *directory=@(canonical),*ownerPath=[directory stringByAppendingPathComponent:@"owner.json"],*work=[directory stringByAppendingPathComponent:@"session-work"],*error=nil;
    NSString *session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;NSDictionary *baseline=[dns.records copy];
    KuroOwnedDNS *old=[[KuroOwnedDNS alloc]initWithDirectory:directory owner:geteuid() backend:dns];CHECK([old installForSession:session error:&error]);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;
    NSMutableDictionary *record=RestartRecord();
    struct proc_bsdinfo identity={0};CHECK(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&identity,sizeof(identity))==sizeof(identity));record[@"pid"]=@(getpid());record[@"startSeconds"]=@(identity.pbi_start_tvsec);record[@"startMicros"]=@(identity.pbi_start_tvusec);
    pid_t dead=0;
    if(scenario==2||scenario==3) {int pipes[2];CHECK(!pipe(pipes));dead=fork();CHECK(dead>=0);if(!dead){close(pipes[1]);char byte;while(read(pipes[0],&byte,1)<0&&errno==EINTR){} _exit(0);}close(pipes[0]);CHECK(proc_pidinfo(dead,PROC_PIDTBSDINFO,0,&identity,sizeof(identity))==sizeof(identity));close(pipes[1]);CHECK(waitpid(dead,NULL,0)==dead);
      record[@"pid"]=@(dead);record[@"startSeconds"]=@(identity.pbi_start_tvsec);record[@"startMicros"]=@(identity.pbi_start_tvusec);
      Put([work stringByAppendingPathComponent:@"config.json"],Bytes(@"fixed runtime"),0600);Put([work stringByAppendingPathComponent:@"cache.db"],Bytes(@"owned cache"),0600);NSDictionary *cache=KuroWorkCacheSnapshot(directory,geteuid(),&error);CHECK(cache);
      NSMutableDictionary *receipt=[@{@"configSHA256":Hash(Bytes(@"fixed runtime")),@"socket":NSNull.null,@"cacheOrigin":@{@"device":cache[@"device"],@"inode":cache[@"inode"],@"owner":@(geteuid()),@"mode":@0600}}mutableCopy];if(scenario==3)receipt[@"cache"]=cache;record[@"format"]=@2;record[@"work"]=receipt;
    }
    Put(ownerPath,scenario==1?Bytes(@"unknown owner"):JSONData(record),0600);NSData *ownerBytes=[NSData dataWithContentsOfFile:ownerPath];
    if(scenario==4)dns.failRemove=YES;
    __block NSUInteger calls=0;KuroTunServiceHooks *hooks=ServiceHooks();hooks.recoverResidualNetwork=^BOOL(NSString **failure){calls++;KuroProductionNetwork *fresh=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];return [fresh recoverSession:nil error:failure];};
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:[directory stringByAppendingPathComponent:@"unused"] hooks:hooks];BOOL ok=[service recoverNetworkOnly:&error];
    CHECK(ok==(scenario==3));CHECK(calls>0&&dns.removals==1&&!routes.deletions);
    if(scenario==4){CHECK([error hasPrefix:@"DNS: remove failed"]&&[service.statusSnapshot[@"error"]isEqual:error]&&Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));}
    else CHECK([dns.records isEqual:baseline]&&!Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
    if(scenario==3)CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists(work)&&!Exists(ownerPath)&&calls==2);
    else {CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]&&[[NSData dataWithContentsOfFile:ownerPath]isEqual:ownerBytes]);if(scenario==2)CHECK([[NSData dataWithContentsOfFile:[work stringByAppendingPathComponent:@"cache.db"]]isEqual:Bytes(@"owned cache")]&&[error isEqual:@"origin-only cache requires an explicit installed writer validator; preserve work"]);}
    CHECK(!Exists([directory stringByAppendingPathComponent:@"stopped.json"]));CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native service DNS partial recovery: 5 persisted positive chains retain live/unknown/origin-only owner gates, permit exact final-cache recovery, aggregate real deletion errors and never issue stopped proof; no Core/network");
}
// Structure follows the saved root858 launchctl print; values are deliberately
// isolated fixtures, not a claim that this ordinary process was launched by launchd.
static NSString *SupervisionJobFixture(NSString *program,pid_t pid) {
  return [NSString stringWithFormat:@"system/dev.kuro.tun = {\n\tactive count = 1\n\tpath = %@\n\ttype = LaunchDaemon\n\tstate = running\n\tprogram = %@\n\targuments = {\n\t\t%@\n\t\t--serve\n\t}\n\tenvironment = {\n\t\tPATH => /usr/bin:/bin\n\t}\n\tpid = %d\n\tresource coalition = {\n\t\tpid = 987\n\t\ttype = resource\n\t}\n\tproperties = inferred program\n}\n",Plist,program,program,pid];
}
static void SupervisionProducerTests(void) {
  NSString *program=[Tools stringByAppendingPathComponent:@"versions/release-with-spaces-client/helper"],*hash=Hash(Bytes(@"helper")),*job=SupervisionJobFixture(program,1234),*error=nil;
  CHECK(KuroSupervisorJob(job,program,1234,&error));
  NSArray *bad=@[
    [job stringByReplacingOccurrencesOfString:@"system/dev.kuro.tun = {" withString:@"system/another.job = {"],
    [job stringByReplacingOccurrencesOfString:@"\tpid = 1234" withString:@"\tpid = 1235"],
    [job stringByReplacingOccurrencesOfString:@"\tpid = 1234" withString:@"\tpid = 1234\n\tpid = 1234"],
    [job stringByReplacingOccurrencesOfString:@"\tpid = 1234\n" withString:@""],
    [job stringByReplacingOccurrencesOfString:@"--serve" withString:@"--serve-auth"],
    [job stringByReplacingOccurrencesOfString:@"\t\t--serve" withString:@"\t\t--serve\n\t\textra"],
    [job stringByReplacingOccurrencesOfString:@"state = running" withString:@"state = not running"],
    [job stringByReplacingOccurrencesOfString:@"\ttype = LaunchDaemon" withString:@"\ttype = LaunchAgent"],
    [job stringByReplacingOccurrencesOfString:@"properties = inferred program" withString:@"properties = inferred program abandon process group"],
    [job stringByReplacingOccurrencesOfString:@"\tproperties = inferred program\n" withString:@""],
    [job stringByReplacingOccurrencesOfString:@"properties = inferred program" withString:@"properties = unknown"],
    [job stringByReplacingOccurrencesOfString:@"properties = inferred program" withString:@"properties = inferred program\n\tproperties = inferred program"],
    [job substringToIndex:job.length-2], [job stringByAppendingString:@"trailing"],
    [job stringByReplacingOccurrencesOfString:Plist withString:@"/tmp/other.plist"],
    [job stringByReplacingOccurrencesOfString:@"\tprogram = " withString:@"\tprogram = /wrong/"],
    [job stringByReplacingOccurrencesOfString:@"\targuments = {" withString:@"\targuments = {\n\t}\n\targuments = {"]
  ];for(NSString *text in bad)CHECK(!KuroSupervisorJob(text,program,1234,&error));
  CHECK(!KuroSupervisorJob(job,[program stringByAppendingString:@"different"],1234,&error));CHECK(!KuroSupervisorJob(job,program,1235,&error));
  struct proc_bsdinfo process={.pbi_pid=1234,.pbi_ppid=1,.pbi_pgid=1234,.pbi_uid=0,.pbi_ruid=0,.pbi_start_tvsec=123,.pbi_start_tvusec=456};
  NSDictionary *evidence=KuroSupervisorEvidence(process,program,program,hash,hash,job,&error);CHECK(KuroSupervisionEvidence(evidence));
  for(NSString *key in @[@"policy",@"helperSHA256",@"startSeconds",@"startMicros"]) {NSMutableDictionary *changed=[evidence mutableCopy];changed[key]=@YES;CHECK(!KuroSupervisionEvidence(changed));}
  NSMutableDictionary *extra=[evidence mutableCopy];extra[@"rpc"]=@YES;CHECK(!KuroSupervisionEvidence(extra));
  struct proc_bsdinfo changed=process;changed.pbi_ppid=55;CHECK(!KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error));
  changed=process;changed.pbi_pgid=99;CHECK(!KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error));
  changed=process;changed.pbi_uid=geteuid();CHECK(!KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error));
  changed=process;changed.pbi_ruid=geteuid();CHECK(!KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error));
  changed=process;changed.pbi_start_tvsec=0;CHECK(!KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error));
  CHECK(!KuroSupervisorEvidence(process,@"/different/path",program,hash,hash,job,&error));CHECK(!KuroSupervisorEvidence(process,program,program,hash,Hash(Bytes(@"other")),job,&error));
  changed=process;changed.pbi_start_tvusec++;CHECK(![KuroSupervisorEvidence(changed,program,program,hash,hash,job,&error)isEqual:evidence]);
  NSMutableDictionary *record=[RestartRecord()mutableCopy];CHECK(KuroRestartRecord(record,NULL));record[@"supervision"]=evidence;CHECK(!KuroRestartRecord(record,NULL));
  record[@"format"]=@2;record[@"launch"]=@{@"configSHA256":hash,@"coreSHA256":record[@"executableSHA256"],@"template":@"macos-dual-stack-v1"};record[@"work"]=@{@"configSHA256":hash,@"socket":NSNull.null};CHECK(KuroRestartRecord(record,NULL));
  record[@"processGroup"]=@321;CHECK(!KuroRestartRecord(record,NULL));record[@"processGroup"]=record[@"parent"];record[@"pid"]=record[@"parent"];CHECK(!KuroRestartRecord(record,NULL));
  [record removeObjectForKey:@"supervision"];record[@"pid"]=@54321;CHECK(KuroRestartRecord(record,NULL));
  // This must reject before even attempting launchctl under an ordinary UID.
  CHECK(![[[KuroTunService alloc]initWithHooks:ServiceHooks()]supervisionEvidence:&error]);
  for(int mode=0;mode<6;mode++) {KuroSupervisorOutputFixture=mode;uint64_t began=KuroMonotonicMilliseconds();NSString *text=KuroReadSupervisorJob(&error);CHECK(mode==0?[text isEqual:@"fixture job\n"]:!text);CHECK(KuroMonotonicMilliseconds()-began<1400);errno=0;CHECK(waitpid(-1,NULL,WNOHANG)==-1&&errno==ECHILD);}KuroSupervisorOutputFixture=-1;
  puts("native supervision producer: fixed top-level saved-job grammar/pid/program/full argv/properties, kernel/root/helper hash/start identity, strict optional owner shape and legacy compatibility; no launchctl execution");
}
static NSDictionary *InstallationBindingFixture(NSString *base);
static void SupervisionServiceTests(void) {
  CHECK(geteuid()!=0&&getpgrp()==getpid());
  char temporary[]="/tmp/kuro-supservice-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *directory=@(canonical),*core=[directory stringByAppendingPathComponent:@"core"],*journal=[directory stringByAppendingPathComponent:@"owner.json"];
  NSData *bytes=[NSData dataWithContentsOfFile:Executable()];Put(core,bytes,0755);KuroTunServiceHooks *hooks=ServiceHooks();
  NSDictionary *deployment=InstallationBindingFixture([directory stringByAppendingPathComponent:@"binding"]);NSString *prefix=deployment[@"prefix"],*helper=deployment[@"helper"];NSDictionary *installedSnapshot=KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,NULL);CHECK(installedSnapshot);
  __block NSUInteger reads=0,prepared=0,proofs=0;__block NSDictionary *persisted=nil;
  hooks.beforeResume=^BOOL(NSString **error){prepared++;persisted=ReadJSON(directory,journal,geteuid(),NULL);CHECK(KuroSupervisionEvidence(persisted[@"supervision"]));CHECK([persisted[@"supervision"][@"installation"]isEqual:installedSnapshot[@"installation"]]);CHECK([persisted[@"launch"][@"runtimeSHA256"]isEqual:persisted[@"work"][@"configSHA256"]]);return KuroMarkSessionStarted(prefix,geteuid(),helper,error);};
  hooks.confirmStopped=^BOOL(NSDictionary *evidence,NSString **error){(void)error;proofs++;CHECK(KuroCompletedStopEvidence(evidence)&&[evidence[@"owner"][@"supervision"]isEqual:persisted[@"supervision"]]);return YES;};
  KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:core hooks:hooks];
  NSString *program=[Tools stringByAppendingPathComponent:@"versions/isolated/helper"];
  service.fixtureSupervisionSource=^NSDictionary *(NSString **error){reads++;struct proc_bsdinfo process={0};CHECK(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process));process.pbi_ppid=1;process.pbi_uid=process.pbi_ruid=0;NSDictionary *snapshot=KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,error);if(!snapshot)return nil;NSMutableDictionary *evidence=[KuroSupervisorEvidence(process,program,program,Hash(bytes),Hash(bytes),SupervisionJobFixture(program,getpid()),error)mutableCopy];evidence[@"installation"]=snapshot[@"installation"];return evidence;};
  int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int server=peers[0];dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL success=NO;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *error=nil;success=[service serveOpenFrame:ServiceOpen() peer:server error:&error];if(!success)fprintf(stderr,"supervision service: %s\n",error.UTF8String);close(server);dispatch_semaphore_signal(done);});
  NSDictionary *open=ServiceRead(peers[1]);CHECK([open[@"ok"]isEqual:@YES]);CHECK(reads==3&&prepared==1);ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":open[@"session"],@"sequence":@1});NSDictionary *stopped=ServiceRead(peers[1]);CHECK([stopped[@"ok"]isEqual:@YES]);ServiceWait(done);close(peers[1]);
  CHECK(success&&proofs==1&&!Exists(journal)&&!Exists([directory stringByAppendingPathComponent:@"session-work"])&&[service.statusSnapshot[@"state"]isEqual:@"off"]);CHECK([KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,NULL)isEqual:installedSnapshot]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  for(NSUInteger failure=0;failure<2;failure++) {
    char failed[]="/tmp/kuro-supreject-XXXXXX";CHECK(mkdtemp(failed)&&realpath(failed,canonical));NSString *root=@(canonical),*binary=[root stringByAppendingPathComponent:@"core"];
    Put(binary,bytes,0755);KuroTunServiceHooks *deniedHooks=ServiceHooks();__block NSUInteger sampled=0,workCreated=0,cachePrepared=0,checkpointed=0,revoked=0;
    deniedHooks.beforeStart=^BOOL(NSString **error){(void)error;revoked++;return YES;};deniedHooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **error){(void)proof;(void)error;checkpointed++;return YES;};
    KuroTunService *denied=[[KuroTunService alloc]initFixtureDirectory:root core:binary hooks:deniedHooks];
    denied.fixtureSupervisionSource=^NSDictionary *(NSString **error){sampled++;if(!failure){Fail(error,@"isolated initial source unavailable");return nil;}return @{@"unexpected":@YES};};
    denied.fixtureBeforeWorkCreation=^{workCreated++;};denied.fixtureBeforeCachePrepare=^(KuroOwnedSession *session){(void)session;cachePrepared++;};
    int sockets[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));NSString *error=nil;CHECK(![denied serveOpenFrame:ServiceOpen() peer:sockets[0] error:&error]);
    CHECK([error containsString:@"before work creation"]&&sampled==1&&!workCreated&&!cachePrepared&&!checkpointed&&!revoked);
    CHECK([denied.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists([root stringByAppendingPathComponent:@"session-work"])&&!Exists([root stringByAppendingPathComponent:@"owner.json"])&&!Exists([root stringByAppendingPathComponent:@"TunDiagnostics"]));
    errno=0;CHECK(waitpid(-1,NULL,WNOHANG)==-1&&errno==ECHILD);close(sockets[0]);close(sockets[1]);CHECK([[NSFileManager defaultManager]removeItemAtPath:root error:NULL]);
  }
  puts("native supervision service: positive three-sample owner/private-controller/held-stop chain plus two initial source refusals before work/cache/revocation/child; isolated job fixture only, no root/launchctl/Core/network");
}
// Actual protected temporary installation model; only the process/job observations
// are isolated fixtures. No Installer, launchctl, real Core or network operation.
static NSDictionary *InstallationBindingFixtureAt(NSString *base, NSString *prefix, BOOL activation) {
  NSString *source=[base stringByAppendingPathComponent:@"source"],*bundle=[source stringByAppendingPathComponent:@"fixture.app"],*error=nil;
  NSData *executable=[NSData dataWithContentsOfFile:Executable()];Put([bundle stringByAppendingPathComponent:ClientExecutable],executable,0755);
  NSDictionary *info=@{@"CFBundleIdentifier":@"dev.kuro.desktop",@"CFBundleExecutable":@"Clash Kuro",@"CFBundlePackageType":@"APPL",@"CFBundleVersion":@"1"};
  Put([bundle stringByAppendingPathComponent:@"Contents/Info.plist"],[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);
  Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"inert installation binding fixture"),0644);
  char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime",(char *)bundle.fileSystemRepresentation,NULL},*env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t signer=0;int status=0;
  CHECK(!posix_spawn(&signer,sign[0],NULL,NULL,sign,env)&&waitpid(signer,&status,0)==signer&&WIFEXITED(status)&&!WEXITSTATUS(status));
  NSDictionary *pin=KuroClientSnapshot(source,bundle,geteuid(),&error),*inventory=FixtureInventory(bundle);CHECK(pin);
  NSMutableDictionary *manifest=[FreshFixtureScripts(source,pin,inventory)mutableCopy],*core=[manifest[@"core"]mutableCopy];manifest[@"activationAllowed"]=@(activation);core[@"sha256"]=Hash(executable);manifest[@"core"]=core;
  NSString *scripts=[source stringByAppendingPathComponent:@"scripts"];Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);FixtureDirectory(prefix);
  CHECK(BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CopyFreshPayload(source,prefix,manifest);Put(At(prefix,[State stringByAppendingPathComponent:@"Inbox/mihomo"]),executable,0755);
  NSString *client=At(prefix,ClientBundle);FixtureDirectory(client.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager]copyItemAtPath:bundle toPath:client error:NULL]);CHECK(Install(prefix,geteuid(),NO,&error));
  NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:manifest[@"release"]]];
  return @{@"prefix":prefix,@"helper":[version stringByAppendingPathComponent:@"helper"],@"core":[version stringByAppendingPathComponent:@"mihomo"],@"manifest":[version stringByAppendingPathComponent:@"manifest.json"]};
}
static NSDictionary *InstallationBindingFixtureMode(NSString *base, BOOL activation) { return InstallationBindingFixtureAt(base,[base stringByAppendingPathComponent:@"installed"],activation); }
static NSDictionary *InstallationBindingFixture(NSString *base) { return InstallationBindingFixtureMode(base,YES); }
// The same capability admission used by ServicePeer's Authorize; audit/SecCode
// peer authentication is not substituted or claimed by this ordinary-UID fixture.
static NSDictionary *FreshAdmissionRequest(KuroTunService *service, NSDictionary *installation, NSString *operation) {
  NSString *error=nil;
  if([operation isEqual:@"status"])return @{@"version":@1,@"ok":@YES,@"status":service.statusSnapshot};
  if(![operation isEqual:@"recover"] || !KuroSessionActivationAt(installation[@"prefix"],geteuid(),installation[@"helper"],&error))return ErrorResponse(error?:@"fixture only accepts status/recover");
  return [service recoverNetworkOnly:&error]?@{@"version":@1,@"ok":@YES,@"status":service.statusSnapshot}:ErrorResponse(error);
}
static void FreshAdmissionTests(void) {
  for(NSUInteger scenario=0;scenario<4;scenario++) {
    char tmp[]="/tmp/kuro-fresh-admit-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(tmp)&&realpath(tmp,canonical));NSString *base=@(canonical);
    NSDictionary *installation=InstallationBindingFixtureMode(base,scenario!=1);NSString *state=At(installation[@"prefix"],State),*journal=[state stringByAppendingPathComponent:@"network.json"];
    if(scenario==2)Put(journal,Bytes(@"unknown route evidence must remain"),0600);
    KuroTunServiceHooks *hooks=ServiceHooks();__block NSUInteger recoveries=0;
    hooks.recoverResidualNetwork=^BOOL(NSString **error){recoveries++;return scenario!=2||Fail(error,@"unknown route evidence retained");};
    KuroTunService *service=[[KuroTunService alloc]initFixtureInstallation:installation hooks:hooks];
    if(scenario==3)[service setValue:@"uninstall checkpoint failed" forKey:@"stopCheckpointFailure"]; // Existing real held-checkpoint case 26 covers the producer.
    NSDictionary *initial=FreshAdmissionRequest(service,installation,@"status")[@"status"];
    CHECK([initial[@"availability"]isEqual:@"blocked"]&&[initial[@"state"]isEqual:scenario==2?@"unknown":@"off"]);
    CHECK(scenario==2||[initial[@"error"]isEqual:@"authenticated recovery is required before a new TUN session"]);
    NSDictionary *reply=FreshAdmissionRequest(service,installation,@"recover"),*observed=FreshAdmissionRequest(service,installation,@"status")[@"status"];
    CHECK([reply[@"ok"]boolValue]==(scenario==0||scenario==3));
    if(scenario==0)CHECK(([observed isEqual:@{@"availability":@"ready",@"state":@"off"}]));
    if(scenario==1)CHECK(recoveries==0&&[reply[@"error"]containsString:@"does not explicitly permit"]&&[observed isEqual:initial]);
    if(scenario==2)CHECK(recoveries==1&&[observed[@"state"]isEqual:@"unknown"]&&[observed[@"availability"]isEqual:@"blocked"]&&[ReadProtected(installation[@"prefix"],journal,geteuid(),NULL)isEqual:Bytes(@"unknown route evidence must remain")]);
    if(scenario==3)CHECK([observed[@"availability"]isEqual:@"blocked"]&&[observed[@"state"]isEqual:@"off"]&&[observed[@"error"]isEqual:@"uninstall checkpoint failed"]);
    CHECK(!Exists([state stringByAppendingPathComponent:@"owner.json"])&&!Exists([state stringByAppendingPathComponent:@"session-work"]));
    CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  }
  puts("fresh admission: actual temporary install/Status + dispatch capability gate + real recovery; finite ready/off, auth-only denied, unknown route retained, checkpoint blocked/off preserved; no Core/root/network writes");
}
static void InstallationBindingTests(void) {
  char temporary[]="/tmp/kuro-install-bind-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil;
  NSDictionary *fixture=InstallationBindingFixture(base);NSString *prefix=fixture[@"prefix"],*helper=fixture[@"helper"],*state=At(prefix,State),*installedPath=[state stringByAppendingPathComponent:@"installed.json"];
  NSDictionary *expected=KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error);CHECK(Keys(expected,@[@"installation",@"helperSHA256"]));CHECK(Keys(expected[@"installation"],@[@"release",@"manifestSHA256",@"freshReceiptSHA256",@"coreSHA256"]));
  NSData *originalInstalled=ReadProtected(prefix,installedPath,geteuid(),NULL);NSMutableDictionary *installed=[KuroDecodeJSON(originalInstalled,MessageLimit,NULL)mutableCopy];installed[@"neverStarted"]=@NO;Put(installedPath,JSONData(installed),0600);
  CHECK([KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error)isEqual:expected]); // Sticky mutable startup state is not installation identity.
  NSArray *targets=@[installedPath,fixture[@"manifest"],At(prefix,FreshReceipt),fixture[@"core"],helper,At(prefix,Plist),[state stringByAppendingPathComponent:@"client.json"],[state stringByAppendingPathComponent:@"Inbox/client-inventory.json"]];
  for(NSString *path in targets) {
    NSData *before=ReadProtected(prefix,path,geteuid(),NULL);struct stat node={0};CHECK(before&&!lstat(path.fileSystemRepresentation,&node));
    Put(path,Bytes(@"changed protected fixture"),node.st_mode&07777);CHECK(!KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error));
    Put(path,before,node.st_mode&07777);CHECK([KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error)isEqual:expected]);
  }
  CHECK(!KuroProtectedInstallationSnapshot(prefix,geteuid(),[helper stringByAppendingString:@"-other"],&error));
  NSString *transaction=[state stringByAppendingPathComponent:@"transaction.json"];Put(transaction,Bytes(@"incomplete transaction"),0600);CHECK(!KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error));CHECK(!unlink(transaction.fileSystemRepresentation));
  NSString *core=fixture[@"core"],*held=[core stringByAppendingString:@".held"];CHECK(!rename(core.fileSystemRepresentation,held.fileSystemRepresentation)&&!symlink(held.fileSystemRepresentation,core.fileSystemRepresentation));CHECK(!KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error));CHECK(!unlink(core.fileSystemRepresentation)&&!rename(held.fileSystemRepresentation,core.fileSystemRepresentation));
  CHECK([KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error)isEqual:expected]);CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native installation binding: actual temporary install, eight changed artifacts, wrong helper, transaction, symlink and mutable neverStarted identity checks passed; no root/service/Core");
}
static void InstalledWriterRecoveryTests(void) {
  char temporary[]="/tmp/kuro-writer-bind-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil;
  NSDictionary *fixture=InstallationBindingFixture(base);NSString *prefix=fixture[@"prefix"],*helper=fixture[@"helper"],*state=At(prefix,State),*journal=[state stringByAppendingPathComponent:@"owner.json"],*work=[state stringByAppendingPathComponent:@"session-work"],*cache=[work stringByAppendingPathComponent:@"cache.db"],*config=[work stringByAppendingPathComponent:@"config.json"];
  CHECK(KuroMarkSessionStarted(prefix,geteuid(),helper,&error));
  NSDictionary *snapshot=KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error);CHECK(snapshot);
  for(NSUInteger scenario=0;scenario<15;scenario++) {
    NSDictionary *open=KuroDecodeJSON(ServiceOpen(),66000,NULL);NSData *admitted=[NSJSONSerialization dataWithJSONObject:open[@"config"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL],*runtime=KuroTunRuntimeJSON(admitted,&error);CHECK(runtime);
    Put(config,runtime,0600);Put(cache,NSData.data,0600);NSDictionary *initial=KuroWorkCacheSnapshot(state,geteuid(),NULL);CHECK(initial);CHECK([Bytes(@"in-place bbolt fixture bytes")writeToFile:cache atomically:NO]);
    NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;record[@"executableSHA256"]=snapshot[@"installation"][@"coreSHA256"];
    record[@"launch"]=@{@"configSHA256":Hash(admitted),@"runtimeSHA256":Hash(runtime),@"coreSHA256":record[@"executableSHA256"],@"template":@"macos-dual-stack-v1"};
    NSMutableDictionary *supervision=[@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":snapshot[@"helperSHA256"],@"startSeconds":@50,@"startMicros":@60,@"installation":snapshot[@"installation"]}mutableCopy];record[@"supervision"]=supervision;
    NSMutableDictionary *receipt=[@{@"configSHA256":Hash(runtime),@"socket":NSNull.null,@"cacheOrigin":@{@"device":initial[@"device"],@"inode":initial[@"inode"],@"owner":@(geteuid()),@"mode":@0600},@"directory":KuroWorkDirectorySnapshot(state,geteuid(),NULL)}mutableCopy];record[@"work"]=receipt;
    if(scenario==1){NSMutableDictionary *binding=[supervision[@"installation"]mutableCopy];binding[@"release"]=@"other-release";supervision[@"installation"]=binding;}
    if(scenario==2)supervision[@"helperSHA256"]=Hash(Bytes(@"other helper"));
    if(scenario==3){NSMutableDictionary *binding=[supervision[@"installation"]mutableCopy];binding[@"freshReceiptSHA256"]=Hash(Bytes(@"old receipt"));supervision[@"installation"]=binding;}
    if(scenario==4){NSMutableDictionary *binding=[supervision[@"installation"]mutableCopy];binding[@"manifestSHA256"]=Hash(Bytes(@"old manifest"));supervision[@"installation"]=binding;}
    if(scenario==5){NSMutableDictionary *launch=[record[@"launch"]mutableCopy];launch[@"runtimeSHA256"]=Hash(Bytes(@"other runtime"));record[@"launch"]=launch;}
    if(scenario==6)[supervision removeObjectForKey:@"installation"];
    if(scenario==10)Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600);
    if(scenario==11){CHECK(!rename(cache.fileSystemRepresentation,[work stringByAppendingPathComponent:@"held-cache"].fileSystemRepresentation));Put(cache,Bytes(@"replacement"),0600);}
    NSString *heldWork=[state stringByAppendingPathComponent:@"fixture-held-work"];
    if(scenario==14){CHECK(!rename(work.fileSystemRepresentation,heldWork.fileSystemRepresentation));FixtureDirectory(work);for(NSString *name in @[@"config.json",@"cache.db"])CHECK(!rename([heldWork stringByAppendingPathComponent:name].fileSystemRepresentation,[work stringByAppendingPathComponent:name].fileSystemRepresentation));}
    Put(journal,JSONData(record),0600);NSData *original=ReadProtected(prefix,journal,geteuid(),NULL);
    RestartObservation=0;RestartMode=scenario==7?1:0;RestartReappearAt=0;RestartGroupMode=scenario==9?1:scenario==13?2:0;RestartSupervisorObservation=0;RestartSupervisorMode=scenario==8?1:scenario==12?2:0;RestartSupervisorReappearAt=0;
    KuroTunServiceHooks *hooks=ServiceHooks();__block NSUInteger networks=0;hooks.recoverResidualNetwork=^BOOL(NSString **failure){(void)failure;networks++;return YES;};
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:state core:fixture[@"core"] hooks:hooks];service.fixtureInstallationPrefix=prefix;service.fixtureRestartReader=RestartSupervisorReader;service.fixtureRestartGroupReader=RestartGroupReader;
    BOOL ok=[service recoverNetworkOnly:&error];CHECK(ok==(scenario==0));CHECK(networks>=1);
    if(ok){CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists(work)&&!Exists(journal));CHECK(!Exists([state stringByAppendingPathComponent:@"stopped.json"]));}
    else {CHECK(error.length&&Exists(work)&&Exists(cache)&&Exists(journal));CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);if(scenario!=10)CHECK([ReadProtected(prefix,journal,geteuid(),NULL)isEqual:original]);}
    if(Exists(journal))CHECK(!unlink(journal.fileSystemRepresentation));if(Exists(work))CHECK([[NSFileManager defaultManager]removeItemAtPath:work error:NULL]);if(Exists(heldWork))CHECK([[NSFileManager defaultManager]removeItemAtPath:heldWork error:NULL]);
  }
  RestartMode=RestartGroupMode=RestartSupervisorMode=0;CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native installed writer recovery: real protected temporary install -> production validator -> origin checkpoint -> exact work cleanup; 15 cases including legacy/mismatch/live/reused/unknown/cache/directory replacement refusal, no synthetic stopped proof");
}

static void SupervisionTests(void) {SupervisionProducerTests();InstallationBindingTests();SupervisionSessionTests();SupervisionServiceTests();InstalledWriterRecoveryTests();}

static void StoppedRevocationTests(void) {
 CHECK(geteuid()!=0); NSString *error=nil;char tmp[]="/tmp/kr-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(tmp)&&realpath(tmp,canonical));NSString *base=@(canonical),*source=[base stringByAppendingPathComponent:@"source"],*bundle=[source stringByAppendingPathComponent:@"fixture.app"];
 Put([bundle stringByAppendingPathComponent:ClientExecutable],[NSData dataWithContentsOfFile:Executable()],0755);
 NSDictionary *info=@{@"CFBundleIdentifier":@"dev.kuro.desktop",@"CFBundleExecutable":@"Clash Kuro",@"CFBundlePackageType":@"APPL",@"CFBundleVersion":@"1"};
 Put([bundle stringByAppendingPathComponent:@"Contents/Info.plist"],[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"inert stopped proof fixture"),0644);
 char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime",(char *)bundle.fileSystemRepresentation,NULL},*env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t signer=0;int status=0;CHECK(!posix_spawn(&signer,sign[0],NULL,NULL,sign,env)&&waitpid(signer,&status,0)==signer&&WIFEXITED(status)&&!WEXITSTATUS(status));
 NSDictionary *pin=KuroClientSnapshot(source,bundle,geteuid(),&error),*inventory=FixtureInventory(bundle);CHECK(pin);
 NSMutableDictionary *manifest=[FreshFixtureScripts(source,pin,inventory)mutableCopy];manifest[@"activationAllowed"]=@YES;NSMutableDictionary *coreRecord=[manifest[@"core"]mutableCopy];coreRecord[@"sha256"]=Hash([NSData dataWithContentsOfFile:Executable()]);manifest[@"core"]=coreRecord;
 NSString *scripts=[source stringByAppendingPathComponent:@"scripts"];Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);
 for(NSUInteger scenario=0;scenario<4;scenario++) {
  NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"c%lu",(unsigned long)scenario]];FixtureDirectory(prefix);CHECK(BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CopyFreshPayload(source,prefix,manifest);Put(At(prefix,[State stringByAppendingPathComponent:@"Inbox/mihomo"]),[NSData dataWithContentsOfFile:Executable()],0755);
  NSString *client=At(prefix,ClientBundle);FixtureDirectory(client.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager]copyItemAtPath:bundle toPath:client error:NULL]);CHECK(Install(prefix,geteuid(),NO,&error));
  NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:manifest[@"release"]]],*helper=[version stringByAppendingPathComponent:@"helper"],*core=[version stringByAppendingPathComponent:@"mihomo"],*state=At(prefix,State),*stopped=[state stringByAppendingPathComponent:@"stopped.json"],*installed=[state stringByAppendingPathComponent:@"installed.json"],*work=[state stringByAppendingPathComponent:@"session-work"];
  KuroOwnedSession *old=[[KuroOwnedSession alloc]initWithDirectory:state owner:geteuid()];CHECK(([old setLaunchEvidence:@{@"configSHA256":Hash(Bytes(@"inert previous session")),@"coreSHA256":coreRecord[@"sha256"],@"template":@"macos-dual-stack-v1"} error:&error]));
  NSString *child=[state stringByAppendingPathComponent:@"fixture-child"];Put(child,[NSData dataWithContentsOfFile:core],0755);CHECK([old spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure){return KuroMarkSessionStarted(prefix,geteuid(),helper,failure);}afterReap:^BOOL(NSString **failure){(void)failure;return YES;}error:&error]);CHECK([old stop:&error]);NSDictionary *completed=[old completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(completed));CHECK(!unlink(child.fileSystemRepresentation));
  NSDictionary *oldNetwork=@{@"format":@1,@"session":old.identifier,@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null};CHECK(KuroMarkSessionStopped(prefix,geteuid(),helper,completed,oldNetwork,&error));NSData *oldProof=ReadProtected(prefix,stopped,geteuid(),NULL);CHECK(oldProof&&[ReadJSON(prefix,installed,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
  __block NSUInteger starts=0,resumes=0,proofs=0;KuroTunServiceHooks *hooks=ServiceHooks();
  hooks.beforeStart=^BOOL(NSString **failure){starts++;CHECK(HasOwnershipFootprint(prefix)&&Exists([state stringByAppendingPathComponent:@"owner.json"]));if(scenario==2)return Fail(failure,@"injected stopped revocation refusal");return KuroRevokeStoppedProof(prefix,geteuid(),failure);};
  hooks.beforeResume=^BOOL(NSString **failure){resumes++;CHECK(!Exists(stopped));return KuroMarkSessionStarted(prefix,geteuid(),helper,failure);};
  hooks.confirmStopped=^BOOL(NSDictionary *process,NSString **failure){proofs++;NSDictionary *network=@{@"format":@1,@"session":process[@"session"],@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null};return KuroMarkSessionStopped(prefix,geteuid(),helper,process,network,failure);};
  if(scenario==0)hooks.physicalInterface=^NSString *{return @"utun0";};
  NSString *runningCore=[state stringByAppendingPathComponent:@"core"];Put(runningCore,[NSData dataWithContentsOfFile:core],0755);KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:state core:runningCore hooks:hooks];__weak KuroTunService *weak=service;service.fixtureRetained=^{[weak requestShutdown];};
  if(scenario==1)service.fixtureSupervisionSource=^NSDictionary *(NSString **failure){Fail(failure,@"injected initial supervision unavailable");return nil;};
  int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int peer=peers[0];BOOL ok=NO;
  if(scenario==3){dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL result=NO;dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *failure=nil;result=[service serveOpenFrame:ServiceOpen() peer:peer error:&failure];close(peer);dispatch_semaphore_signal(done);});NSDictionary *opened=ServiceRead(peers[1]);CHECK([opened[@"ok"]boolValue]);ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":opened[@"session"],@"sequence":@1});CHECK([ServiceRead(peers[1])[@"ok"]boolValue]);ServiceWait(done);CHECK(result);ok=result;}
  else {ok=[service serveOpenFrame:ServiceOpen() peer:peers[0] error:&error];CHECK(!ok&&error.length);close(peers[0]);}
  close(peers[1]);CHECK(!unlink(runningCore.fileSystemRepresentation));CHECK([ReadJSON(prefix,installed,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
  // Fixture-only diagnostics are nested under State; align retained evidence with the production sibling before testing real uninstall.
  NSString *diagnostics=[state stringByAppendingPathComponent:@"TunDiagnostics"];if(Exists(diagnostics))CHECK([[NSFileManager defaultManager]moveItemAtPath:diagnostics toPath:[state.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"TunDiagnostics"] error:NULL]);
  BOOL kept=[ReadProtected(prefix,stopped,geteuid(),NULL)isEqual:oldProof];
  if(scenario==0){CHECK(kept);CHECK(starts==0&&resumes==0&&proofs==0);CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists(work));BOOL removed=Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error);CHECK(removed);printf("early failure: old proof retained=%d physicalOff=1 uninstall=%d neverStarted false unchanged\n",kept,removed);}
  if(scenario==1){CHECK(kept&&starts==0&&resumes==0&&proofs==0);CHECK(!Exists(work)&&[service.statusSnapshot[@"state"]isEqual:@"off"]);CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));puts("initial supervision refused before work: old proof retained byte-for-byte, no resume/revocation/stop checkpoint, exact uninstall succeeds");}
  if(scenario==2){CHECK(kept&&starts==1&&resumes==0&&proofs==1);CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists(work));CHECK([service.statusSnapshot[@"error"]containsString:@"uninstall checkpoint failed"]);CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));puts("beforeStart refused: actual suspended child reaped, no beforeResume/CONT, old proof retained, old valid stop authority remains usable");}
  if(scenario==3){CHECK(ok&&!kept&&starts==1&&resumes==1&&proofs==1&&!Exists(work));CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));puts("resumed successor: old proof revoked before beforeResume/CONT; new exact completed proof required for successful stop/uninstall");}
 }
 CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}

// Real held harmless children + real protected installed trees. Only process-group
// enumeration and network state are isolated fixtures; no Core/launchd/network runs.
static int HeldStopEmptyGroup(uint32_t kind,uint32_t group,void *bytes,int size) {
  CHECK(kind==PROC_PGRP_ONLY && group==(uint32_t)getpgrp());memset(bytes,0,(size_t)size);errno=0;return 0;
}
static void HeldStopCheckpointTests(void) {
  CHECK(geteuid()!=0);char temporary[]="/tmp/ks-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil;
  NSString *source=[base stringByAppendingPathComponent:@"source"],*next=[base stringByAppendingPathComponent:@"next"];
  NSData *binary=[NSData dataWithContentsOfFile:Executable()];
  NSDictionary *manifest=UpgradeFixtureSource(source,@"held-proof-old",@"held-proof original fixture",binary);
  NSDictionary *nextManifest=UpgradeFixtureSource(next,@"held-proof-next",@"held-proof successor fixture",binary);(void)nextManifest;
  for(NSUInteger scenario=0;scenario<13;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu",(unsigned long)scenario]];
    UpgradeFixtureInstall(source,prefix,manifest,NO);
    NSString *state=At(prefix,State),*path=[state stringByAppendingPathComponent:@"owner.json"],*stopped=[state stringByAppendingPathComponent:@"stopped.json"],*installed=[state stringByAppendingPathComponent:@"installed.json"],*child=[state stringByAppendingPathComponent:@"fixture-child"];
    NSString *helper=[At(prefix,Tools)stringByAppendingPathComponent:@"versions/held-proof-old/helper"];
    if(scenario==8||scenario==9||scenario==12) {
      NSString *core=[state stringByAppendingPathComponent:@"core"];Put(core,binary,0755);__block NSUInteger armed=0,attempts=0,proofs=0;__block pthread_t originalThread;
      KuroTunServiceHooks *hooks=ServiceHooks();hooks.beforeStart=^BOOL(NSString **failure){armed++;originalThread=pthread_self();return KuroRevokeStoppedProof(prefix,geteuid(),failure);};
      hooks.beforeResume=^BOOL(NSString **failure){attempts++;if(scenario!=9 && !KuroMarkSessionStarted(prefix,geteuid(),helper,failure))return NO;return scenario==12 || Fail(failure,@"injected armed beforeResume refusal");};
      hooks.confirmStopped=^BOOL(NSDictionary *process,NSString **failure){proofs++;CHECK(pthread_equal(originalThread,pthread_self()));CHECK(Exists(path));NSDictionary *network=@{@"format":@1,@"session":process[@"session"],@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null};return KuroMarkSessionStopped(prefix,geteuid(),helper,process,network,failure);};
      hooks.recoverNetwork=^BOOL(NSString *session,NSString **failure){(void)session;(void)failure;CHECK(pthread_equal(originalThread,pthread_self()));return YES;};
      KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:state core:core hooks:hooks];__weak KuroTunService *weak=service;
      dispatch_semaphore_t retained=dispatch_semaphore_create(0),done=dispatch_semaphore_create(0);
      service.fixtureRetained=^{if(scenario==12)dispatch_semaphore_signal(retained);else [weak requestShutdown];};
      int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));
      if(scenario==12) {
        KuroStoppedFault=2;int peer=peers[0];__block BOOL result=YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *failure=nil;result=[service serveOpenFrame:ServiceOpen()peer:peer error:&failure];close(peer);dispatch_semaphore_signal(done);});
        NSDictionary *open=ServiceRead(peers[1]);CHECK([open[@"ok"]boolValue]);ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":open[@"session"],@"sequence":@1});CHECK(![ServiceRead(peers[1])[@"ok"]boolValue]);ServiceWait(retained);
        CHECK(Exists(path)&&Exists(stopped)&&!Exists([state stringByAppendingPathComponent:@"session-work"]));CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]);CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
        KuroStoppedFault=0;CHECK(ServiceRecoverySocket(service));ServiceWait(done);CHECK(!result&&proofs>=2);close(peers[1]);
      } else {
        CHECK(![service serveOpenFrame:ServiceOpen()peer:peers[0]error:&error]);close(peers[0]);close(peers[1]);
        CHECK([error containsString:@"injected armed beforeResume refusal"]&&proofs==1);
      }
      CHECK(armed==1&&attempts==1);
      CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists(path)&&!Exists([state stringByAppendingPathComponent:@"session-work"]));
      CHECK([ReadJSON(prefix,installed,geteuid(),NULL)[@"neverStarted"]boolValue]==(scenario==9));CHECK(Exists(stopped)==(scenario!=9));CHECK(!unlink(core.fileSystemRepresentation));
      CHECK([[NSFileManager defaultManager]moveItemAtPath:[state stringByAppendingPathComponent:@"TunDiagnostics"]toPath:[state.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"TunDiagnostics"]error:NULL]);
      CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));printf("held checkpoint %lu: actual service checkpoint/retained retry; neverStarted=%s preserved, exact uninstall passed\n",(unsigned long)scenario,scenario==9?"true":"false");continue;
    }
    Put(child,binary,0755);KuroOwnedSession *held=[[KuroOwnedSession alloc]initWithDirectory:state owner:geteuid()];
    CHECK(([held setLaunchEvidence:@{@"configSHA256":Hash(Bytes(@"inert held proof fixture")),@"coreSHA256":manifest[@"core"][@"sha256"],@"template":@"macos-dual-stack-v1"}error:&error]));
    __block NSUInteger calls=0;__block NSDictionary *genuine=nil;__block BOOL cleanupAllowed=scenario!=10;
    __weak KuroOwnedSession *weakHeld=held;
    CHECK(([held setBeforeOwnerRemoval:^BOOL(NSDictionary *process,NSString **failure) {
      calls++;CHECK(KuroCompletedStopEvidence(process));CHECK(Exists(path));CHECK(![weakHeld completedStopEvidence:NULL]);
      genuine=process;NSDictionary *network=@{@"format":@1,@"session":process[@"session"],@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null};
      BOOL saved=KuroMarkSessionStopped(prefix,geteuid(),helper,process,network,failure);
      if(saved && scenario==5)weakHeld.fixtureFailDirectorySync=YES;
      return saved;
    }error:&error]));
    if(scenario==4)held.fixtureFailOwnerUnlink=YES;
    BOOL launched=[held spawnExecutable:child arguments:@[@"--session-child"]beforeResume:^BOOL(NSString **failure) {
      CHECK(KuroRevokeStoppedProof(prefix,geteuid(),failure));
      if(scenario!=9 && !KuroMarkSessionStarted(prefix,geteuid(),helper,failure))return NO;
      return (scenario!=8 && scenario!=9) || Fail(failure,@"injected beforeResume refusal");
    }afterReap:^BOOL(NSString **failure) {
      if(!cleanupAllowed)return Fail(failure,@"fixture network cleanup incomplete");
      if(Exists(child))CHECK(!unlink(child.fileSystemRepresentation));return YES;
    }error:&error];
    CHECK(launched==(scenario!=8&&scenario!=9));
    KuroStoppedFault=scenario>=1&&scenario<=3?scenario:0;
    BOOL saved=[held stop:&error];
    CHECK(saved==(scenario==0||scenario==6||scenario==7||scenario==11));
    CHECK(!held.child); // waitpid is from the original held object, not a stored PID.
    if(scenario==10) {CHECK(calls==0&&Exists(path)&&!Exists(stopped));cleanupAllowed=YES;CHECK([held stop:&error]);}
    if(scenario==1) {CHECK(Exists(path)&&!Exists(stopped)&&!held.off);CHECK(![held stop:&error]&&Exists(path));KuroStoppedFault=0;CHECK([held stop:&error]);}
    if(scenario==2||scenario==3||scenario==4||scenario==5) {
      CHECK(Exists(stopped)&&!held.off&&!Exists([state stringByAppendingPathComponent:@"session-work"]));
      CHECK(Exists(path)==(scenario!=5));CHECK(![held completedStopEvidence:NULL]);
      // A still-running helper holds this lock even after owner unlink.
      int serviceLock=ServiceLock(prefix,geteuid(),&error);CHECK(serviceLock>=0);
      CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
      CHECK(!BeginClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));
      close(serviceLock); // Model restart only after the old service released its lock.
      KuroTunServiceHooks *hooks=ServiceHooks();hooks.recoverResidualNetwork=^BOOL(NSString **failure){(void)failure;return YES;};
      KuroTunService *(^fresh)(void)=^KuroTunService *{
        KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:state core:child hooks:hooks];service.fixtureInstallationPrefix=prefix;service.fixtureRestartGroupReader=HeldStopEmptyGroup;return service;
      };
      if(scenario==2||scenario==3||scenario==5) {
        if(scenario==5)KuroStoppedFault=3;
        CHECK(![fresh() recoverNetworkOnly:&error]);CHECK(Exists(path)==(scenario!=5));CHECK(![fresh() recoverNetworkOnly:&error]);
      }
      KuroStoppedFault=0;NSUInteger files=KuroStoppedFileSyncs,dirs=KuroStoppedDirectorySyncs;
      KuroTunService *recovered=fresh();CHECK([recovered recoverNetworkOnly:&error]);CHECK([recovered.statusSnapshot[@"state"]isEqual:@"off"]);CHECK(!Exists(path));
      CHECK(KuroStoppedFileSyncs>files&&KuroStoppedDirectorySyncs>dirs);
    }
    KuroStoppedFault=0;CHECK(genuine&&Exists(stopped));NSData *proofBytes=ReadProtected(prefix,stopped,geteuid(),NULL);
    if(scenario==6||scenario==7) {
      // A durable proof is not a wildcard for a changed record or replacement.
      Put(path,scenario==6?JSONData(genuine[@"owner"]):Bytes(@"unknown owner"),0600);
      if(scenario==6)Put(stopped,Bytes(@"{}"),0600);
      CHECK(!KuroReplayStoppedCheckpoint(prefix,geteuid(),helper,genuine[@"owner"],&error));
      CHECK(Exists(path)&&Exists(stopped));CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
      Put(stopped,proofBytes,0600);Put(path,JSONData(genuine[@"owner"]),0600);
      CHECK(KuroReplayStoppedCheckpoint(prefix,geteuid(),helper,genuine[@"owner"],&error));CHECK(!unlink(path.fileSystemRepresentation));CHECK(SyncInstallDirectory(state,&error));
    }
    if(scenario==11) {
      CHECK(!unlink(stopped.fileSystemRepresentation)); // Missing proof never becomes childReaped on replay.
      CHECK(KuroReplayStoppedCheckpoint(prefix,geteuid(),helper,nil,&error)&&!Exists(stopped));
      CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));Put(stopped,proofBytes,0600);
    }
    if(scenario==0) {
      // Actual transactional upgrade consumes the proof only after owner absence.
      CHECK(BeginClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));UpgradeFixturePayload(next,prefix);
      CHECK(CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));
      CHECK([ReadJSON(prefix,installed,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
    }
    CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!Exists(state)&&!Exists(At(prefix,Tools)));
    printf("held checkpoint %lu: real reap, durable exact proof, fresh retry/absence gates and actual uninstall passed\n",(unsigned long)scenario);
  }
  KuroStoppedFault=0;CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("PASS 13 held-stop checkpoint cases: proof write/file-sync/directory-sync, owner unlink/sync, changed proof/owner, both sticky histories, network failure and missing-proof refusal; no Core/launchd/network");
}

// Actual installed files/receipt and actual production writer/readback consumers;
// only kernel process/group observations and network backends are fixtures.
static NSDictionary *RecoveredStopOwner(NSString *state,NSDictionary *snapshot) {
  NSString *error=nil,*work=[state stringByAppendingPathComponent:@"session-work"];
  NSDictionary *open=KuroDecodeJSON(ServiceOpen(),66000,NULL);
  NSData *admitted=[NSJSONSerialization dataWithJSONObject:open[@"config"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL],*runtime=KuroTunRuntimeJSON(admitted,&error);CHECK(runtime);
  Put([work stringByAppendingPathComponent:@"config.json"],runtime,0600);Put([work stringByAppendingPathComponent:@"cache.db"],NSData.data,0600);
  NSDictionary *initial=KuroWorkCacheSnapshot(state,geteuid(),NULL);CHECK(initial);CHECK([Bytes(@"in-place bbolt fixture bytes")writeToFile:[work stringByAppendingPathComponent:@"cache.db"]atomically:NO]);
  NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;record[@"executableSHA256"]=snapshot[@"installation"][@"coreSHA256"];
  record[@"launch"]=@{@"configSHA256":Hash(admitted),@"runtimeSHA256":Hash(runtime),@"coreSHA256":record[@"executableSHA256"],@"template":@"macos-dual-stack-v1"};
  record[@"supervision"]=@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":snapshot[@"helperSHA256"],@"startSeconds":@50,@"startMicros":@60,@"installation":snapshot[@"installation"]};
  record[@"work"]=@{@"configSHA256":Hash(runtime),@"socket":NSNull.null,@"cacheOrigin":@{@"device":initial[@"device"],@"inode":initial[@"inode"],@"owner":@(geteuid()),@"mode":@0600},@"directory":KuroWorkDirectorySnapshot(state,geteuid(),NULL)};
  CHECK(KuroRestartRecord(record,&error));Put([state stringByAppendingPathComponent:@"owner.json"],JSONData(record),0600);return record;
}
static void RecoveredStopCheckpointTests(void) {
  CHECK(geteuid()!=0);char temporary[]="/tmp/krp-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil;
  NSString *source=[base stringByAppendingPathComponent:@"source"],*next=[base stringByAppendingPathComponent:@"next"];
  NSData *binary=[NSData dataWithContentsOfFile:Executable()];NSDictionary *manifest=UpgradeFixtureSource(source,@"recovered-old",@"recovered fixture",binary);
  UpgradeFixtureSource(next,@"recovered-next",@"recovered successor",binary);
  for(NSUInteger scenario=0;scenario<23;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu",(unsigned long)scenario]];UpgradeFixtureInstall(source,prefix,manifest,NO);
    NSString *state=At(prefix,State),*ownerPath=[state stringByAppendingPathComponent:@"owner.json"],*stopped=[state stringByAppendingPathComponent:@"stopped.json"],*work=[state stringByAppendingPathComponent:@"session-work"],*helper=[At(prefix,Tools)stringByAppendingPathComponent:@"versions/recovered-old/helper"],*core=[At(prefix,Tools)stringByAppendingPathComponent:@"versions/recovered-old/mihomo"];
    if(scenario!=15)CHECK(KuroMarkSessionStarted(prefix,geteuid(),helper,&error));
    NSDictionary *snapshot=KuroProtectedInstallationSnapshot(prefix,geteuid(),helper,&error);CHECK(snapshot);RecoveredStopOwner(state,snapshot);
    RestartObservation=RestartReappearAt=RestartSupervisorObservation=RestartSupervisorReappearAt=0;RestartMode=scenario==12?1:0;RestartSupervisorMode=scenario==13?1:0;RestartGroupMode=0;
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=state;routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=state;
    KuroTunServiceHooks *hooks=ServiceHooks();
    hooks.recoverResidualNetwork=^BOOL(NSString **failure){KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:state owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];return [network recoverSession:nil error:failure];};
    hooks.recoveredNetworkEvidence=^NSDictionary *(NSDictionary *record,NSString **failure){KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:state owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];return [network recoverRecordedSession:record[@"session"]error:failure];};
    KuroTunService *(^fresh)(void)=^KuroTunService *{KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:state core:core hooks:hooks];service.fixtureInstallationPrefix=prefix;service.fixtureRestartReader=RestartSupervisorReader;service.fixtureRestartGroupReader=RestartGroupReader;return service;};
    if(scenario==6)Put(stopped,Bytes(@"{}"),0600);
    if(scenario==8)dns.failSnapshot=YES;
    if(scenario==9)dns.records[KuroDNSKey(@"00112233-4455-6677-8899-AABBCCDDEEFF")]=KuroDNSValue();
    if(scenario==10)[routes.entries addObject:ProductionRoute(4,@"0.0.0.0",1,@"link",@"utun7",7,RTF_UP|RTF_PROTO2)];
    if(scenario==11)[routes.entries addObject:ProductionRoute(4,@"0.0.0.0",1,@"link",@"utun7",7,RTF_UP)];
    if(scenario==14){CHECK([[NSFileManager defaultManager]removeItemAtPath:work error:NULL]);CHECK(!unlink(ownerPath.fileSystemRepresentation));}
    if(scenario==18)Put([work stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0600);
    if(scenario==19){KuroOwnedDNS *oldDNS=[[KuroOwnedDNS alloc]initWithDirectory:state owner:geteuid() backend:dns];CHECK([oldDNS installForSession:@"00112233-4455-6677-8899-AABBCCDDEEFF"error:&error]);CHECK(dns.additions==1&&Exists([state stringByAppendingPathComponent:KuroDNSJournal]));}
    if(scenario==20||scenario==22) {
      NSData *raw=ReadProtected(prefix,ownerPath,geteuid(),NULL);NSMutableDictionary *record=[KuroDecodeJSON(raw,MessageLimit,NULL)mutableCopy],*receipt=[record[@"work"]mutableCopy];receipt[@"cache"]=KuroWorkCacheSnapshot(state,geteuid(),NULL);record[@"work"]=receipt;
      NSMutableData *noncanonical=[JSONData(record)mutableCopy];[noncanonical appendBytes:"\n "length:2];if(scenario==22){NSMutableData *padding=[NSMutableData dataWithLength:40000];memset(padding.mutableBytes,'\n',padding.length);[noncanonical appendData:padding];}CHECK(noncanonical.length<MessageLimit);Put(ownerPath,noncanonical,0600);
    }
    if(scenario==21){__weak KuroFakeDNSStore *weakDNS=dns;dns.onSnapshot=^{KuroFakeDNSStore *backend=weakDNS;if(backend.snapshots==6)backend.records[KuroDNSKey(@"00112233-4455-6677-8899-AABBCCDDEEFF")]=KuroDNSValue();};}
    if(scenario>=2&&scenario<=4)KuroStoppedFault=scenario-1;
    if(scenario==7)KuroStoppedFault=2;
    BOOL ok=NO;
    if(scenario==5||scenario==16) {
      KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:state owner:geteuid()];observed.fixtureRestartReader=RestartSupervisorReader;observed.fixtureRestartGroupReader=RestartGroupReader;observed.fixtureFailOwnerUnlink=scenario==5;
      KuroTunService *consumer=fresh();
      ok=[observed recoverExitedOwnerWithNetwork:hooks.recoverResidualNetwork writerValidator:^BOOL(NSDictionary *record,NSString **failure){return [consumer restartWriterValid:record error:failure];}workCleanup:^BOOL(NSDictionary *record,KuroSessionHook stillAbsent,NSString **failure){return [consumer recoverExitedWork:record stillAbsent:stillAbsent error:failure];}beforeOwnerRemoval:^BOOL(NSDictionary *record,NSData *bytes,KuroSessionHook stillAbsent,NSString **failure){BOOL saved=[consumer checkpointRecoveredOwner:record bytes:bytes stillAbsent:stillAbsent error:failure];if(saved&&scenario==16)observed.fixtureFailDirectorySync=YES;return saved;}error:&error];
      CHECK(!ok&&Exists(stopped)&&!Exists(work));CHECK(Exists(ownerPath)==(scenario==5));
      int heldLock=ServiceLock(prefix,geteuid(),&error);CHECK(heldLock>=0);CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));close(heldLock);
      if(scenario==5)CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
      // A fresh service re-syncs the existing proof; no owner means no new proof.
      NSData *before=ReadProtected(prefix,stopped,geteuid(),NULL);ok=[fresh() recoverNetworkOnly:&error];CHECK([before isEqual:ReadProtected(prefix,stopped,geteuid(),NULL)]);
    } else ok=[fresh() recoverNetworkOnly:&error];
    if((scenario>=2&&scenario<=4)||scenario==7) {
      CHECK(!ok&&Exists(ownerPath)&&!Exists(work));CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!BeginClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));
      CHECK(![fresh() recoverNetworkOnly:&error]&&Exists(ownerPath));
      if(scenario==7) {NSData *raw=ReadProtected(prefix,ownerPath,geteuid(),NULL);NSMutableData *changed=[raw mutableCopy];[changed appendBytes:" "length:1];Put(ownerPath,changed,0600);KuroStoppedFault=0;CHECK(![fresh() recoverNetworkOnly:&error]&&Exists(ownerPath));Put(ownerPath,raw,0600);}
      KuroStoppedFault=0;ok=[fresh() recoverNetworkOnly:&error];CHECK(ok);
    }
    if(scenario==21){CHECK(!ok&&Exists(stopped)&&Exists(ownerPath)&&!Exists(work));CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));dns.onSnapshot=nil;[dns.records removeObjectForKey:KuroDNSKey(@"00112233-4455-6677-8899-AABBCCDDEEFF")];ok=[fresh() recoverNetworkOnly:&error];CHECK(ok);}
    BOOL expected=(scenario<=5||scenario==7||scenario==14||scenario==15||scenario==16||scenario==17||scenario==19||scenario==20||scenario==21);CHECK(ok==expected);
    if(ok) {
      CHECK(!Exists(ownerPath)&&!Exists(work));
      if(scenario==14||scenario==15) {CHECK(!Exists(stopped));CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error)==(scenario==15));}
      else {
        NSDictionary *proof=ReadJSON(prefix,stopped,geteuid(),&error);CHECK([proof[@"format"]isEqual:@3]&&[proof[@"kind"]isEqual:@"fixed-core-recovered"]&&!proof[@"process"]&&!proof[@"childReaped"]);CHECK(!KuroCompletedStopEvidence(proof));
        NSData *original=[proof[@"ownerJSON"]dataUsingEncoding:NSUTF8StringEncoding];CHECK([Hash(original)isEqual:proof[@"ownerSHA256"]]);if(scenario==20)CHECK([proof[@"ownerJSON"]hasSuffix:@"\n "]);CHECK(KuroRestartRecord(KuroDecodeJSON(original,MessageLimit,NULL),NULL));

        if(scenario==0) {
          NSData *saved=ReadProtected(prefix,stopped,geteuid(),NULL);NSDictionary *receipt=ReadFreshReceipt(prefix,geteuid(),&error),*installed=ReadJSON(prefix,[state stringByAppendingPathComponent:@"installed.json"],geteuid(),NULL);
          CHECK(KuroStoppedBoundToReceipt(proof,receipt,installed));
          for(NSString *field in @[@"workAbsent",@"format",@"ownerSHA256",@"session"]) {
            NSMutableDictionary *changed=[proof mutableCopy];changed[field]=[field isEqual:@"workAbsent"]?@1:[field isEqual:@"format"]?@1:[field isEqual:@"session"]?@"11112233-4455-6677-8899-AABBCCDDEEFF":Hash(Bytes(@"other bytes"));
            CHECK(!KuroStoppedBoundToReceipt(changed,receipt,installed));Put(stopped,JSONData(changed),0600);CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!BeginClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));
          }
          for(NSString *ownerJSON in @[@"[]",@"{\"supervision\":[]}"]) {
            NSMutableDictionary *changed=[proof mutableCopy];changed[@"ownerJSON"]=ownerJSON;changed[@"ownerSHA256"]=Hash([ownerJSON dataUsingEncoding:NSUTF8StringEncoding]);
            CHECK(!KuroStoppedBoundToReceipt(changed,receipt,installed));Put(stopped,JSONData(changed),0600);CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
          }
          NSMutableDictionary *malformedOwner=[KuroDecodeJSON(original,MessageLimit,NULL)mutableCopy];malformedOwner[@"supervision"]=@[];NSMutableDictionary *malformedProof=[proof mutableCopy];NSData *malformedBytes=JSONData(malformedOwner);malformedProof[@"ownerJSON"]=[[NSString alloc]initWithData:malformedBytes encoding:NSUTF8StringEncoding];malformedProof[@"ownerSHA256"]=Hash(malformedBytes);CHECK(!KuroStoppedBoundToReceipt(malformedProof,receipt,installed));
          Put(stopped,saved,0600);
        }
        CHECK([ReadJSON(prefix,[state stringByAppendingPathComponent:@"installed.json"],geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
        if(scenario==1) {CHECK(BeginClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));UpgradeFixturePayload(next,prefix);CHECK(CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,[next stringByAppendingPathComponent:@"scripts"],&error));CHECK([ReadJSON(prefix,[state stringByAppendingPathComponent:@"installed.json"],geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);}
        if(scenario==17) {
          // Preserve exact retry authority after approval appends uninstallJSON.
          NSData *installed=ReadProtected(prefix,[state stringByAppendingPathComponent:@"installed.json"],geteuid(),NULL);NSDictionary *raw=KuroDecodeJSON(ReadProtected(prefix,At(prefix,FreshReceipt),geteuid(),NULL),InventoryLimit*2,NULL);NSMutableDictionary *approved=[raw mutableCopy];approved[@"uninstallJSON"]=[[NSString alloc]initWithData:JSONData(@{@"format":@1,@"installed":KuroDecodeJSON(installed,MessageLimit,NULL),@"stopped":proof})encoding:NSUTF8StringEncoding];Put(At(prefix,FreshReceipt),JSONData(approved),0600);CHECK(ReadFreshReceipt(prefix,geteuid(),&error));CHECK(!unlink([At(prefix,ClientBundle)stringByAppendingPathComponent:@"Contents/Resources/app.asar"].fileSystemRepresentation));
        }
        CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!Exists(state)&&!Exists(At(prefix,Tools)));
      }
    } else {CHECK(Exists(ownerPath));CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));}
    if(scenario==19)CHECK(dns.removals==1&&!Exists([state stringByAppendingPathComponent:KuroDNSJournal]));
    KuroStoppedFault=0;printf("recovered checkpoint %lu: exact production binding/readback + fresh retry/consumer gate passed\n",(unsigned long)scenario);
  }
  RestartMode=RestartGroupMode=RestartSupervisorMode=KuroStoppedFault=0;CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("PASS 23 recovered-stop cases: actual temporary install/upgrade/uninstall, proof durability/raw-byte mismatch, backend readback/live/unknown refusals; no held proof fabricated, no Core/system/network");
}

static void ServiceTests(void) {
  FreshAdmissionTests();
  RecoveredStopCheckpointTests();
  HeldStopCheckpointTests();
  StoppedRevocationTests();
  pid_t supervision=0;char *supervisionArgs[]={(char *)Executable().fileSystemRepresentation,"--supervision-tests",NULL};
  extern char **environ;CHECK(!posix_spawn(&supervision,supervisionArgs[0],NULL,NULL,supervisionArgs,environ));int supervisionStatus=0;CHECK(waitpid(supervision,&supervisionStatus,0)==supervision&&WIFEXITED(supervisionStatus)&&!WEXITSTATUS(supervisionStatus));
  PartialDNSServiceTests();
  ServiceDiagnosticTests();
  ServiceCachePreparationTests();
  RetainedRecoveryTests();
  RestartWorkTests();
  RestartCacheTests();
  CHECK(geteuid()!=0);
  // A sandbox may allow socketpair yet forbid even a temporary AF_UNIX bind.
  // Fail explicitly; do not skip the production-transport fixture or weaken it.
  char probeDirectory[]="/tmp/kuro-service-bind-XXXXXX"; CHECK(mkdtemp(probeDirectory));
  NSString *probePath=[[NSString stringWithUTF8String:probeDirectory] stringByAppendingPathComponent:@"probe.sock"];
  struct sockaddr_un probeAddress={.sun_family=AF_UNIX}; strlcpy(probeAddress.sun_path,probePath.fileSystemRepresentation,sizeof(probeAddress.sun_path));
  int probe=socket(AF_UNIX,SOCK_STREAM,0); CHECK(probe>=0);
  int bound=bind(probe,(struct sockaddr *)&probeAddress,sizeof(probeAddress)), bindError=errno;
  close(probe); if(!bound)CHECK(!unlink(probePath.fileSystemRepresentation)); CHECK(!rmdir(probeDirectory));
  if(bound)fprintf(stderr,"service fixture requires temporary AF_UNIX bind: %s (errno %d); ordinary-user sandbox permission is required, no Core or network is executed\n",strerror(bindError),bindError);
  CHECK(!bound);
  for(NSUInteger scenario=0;scenario<27;scenario++) {
    char temporary[]="/tmp/kuro-service-XXXXXX"; CHECK(mkdtemp(temporary)); char canonical[PATH_MAX]; CHECK(realpath(temporary,canonical));
    NSString *directory=[NSString stringWithUTF8String:canonical];
    NSString *name=scenario==6?@"core-exit":scenario==7?@"core-chunked":scenario==8?@"core-unknown-work":scenario==17?@"core-duplicate-header":scenario==18?@"core-bad-version":scenario==20?@"core-config-changed":scenario==22?@"core-must-not-run":@"core";
    NSString *core=[directory stringByAppendingPathComponent:name]; Put(core,[NSData dataWithContentsOfFile:Executable()],0755);
    KuroTunServiceHooks *hooks=ServiceHooks();
    __block BOOL cleanupAllowed=scenario!=9;
    __block NSUInteger applied=0,recovered=0; __block BOOL identity=scenario!=13; NSObject *identityLock=[NSObject new]; __block KuroTunService *starting=nil;
    hooks.identityValid=^BOOL(int peer) { (void)peer;@synchronized(identityLock) { return identity; } };
    if(scenario==16)hooks.preflight=^BOOL(NSDictionary *config,NSString **error) { (void)config;(void)error;[starting requestStop];return YES; };
    if(scenario==1)hooks.authorize=^BOOL(int peer,NSString *digest,NSString **error) { (void)peer;(void)digest;return Fail(error,@"test caller denied"); };
    if(scenario==2)hooks.preflight=^BOOL(NSDictionary *config,NSString **error) { (void)config;return Fail(error,@"test preflight denied"); };
    if(scenario==25)hooks.confirmStopped=nil;
    if(scenario==26) {
      hooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **error) { CHECK(KuroCompletedStopEvidence(proof));return Fail(error,@"injected stop checkpoint failure"); };
      hooks.recoverResidualNetwork=^BOOL(NSString **error) { (void)error;return YES; };
    }
    if(scenario==23)hooks.beforeResume=nil;
    if(scenario==24)hooks.beforeResume=^BOOL(NSString **error) { return Fail(error,@"durability gate denied"); };
    if(scenario==3)hooks.ready=nil;
    if(scenario==4)hooks.ready=^BOOL(pid_t child,NSString *session,NSString **error) { (void)child;(void)session;return Fail(error,@"test readiness denied"); };
    hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **error) { (void)child;(void)session;applied++;return scenario==5?Fail(error,@"test apply failed"):YES; };
    hooks.recoverNetwork=^BOOL(NSString *session,NSString **error) { (void)session;recovered++;return cleanupAllowed?YES:Fail(error,@"test restore failed"); };
    __block NSUInteger healthChecks=0,residualRecoveries=0;
    if(scenario==0) {
      hooks.physicalInterface=^NSString *{ return @"en0"; };
      hooks.verifyNetwork=^BOOL(NSString *session,NSString **error) { (void)error; CHECK(session.length>0); healthChecks++; return YES; };
      hooks.recoverResidualNetwork=^BOOL(NSString **error) { (void)error; residualRecoveries++; return YES; };
    }
    KuroTunService *service=[[KuroTunService alloc] initFixtureDirectory:directory core:core hooks:hooks];
    dispatch_semaphore_t retainedOwner=dispatch_semaphore_create(0);
    service.fixtureRetained=^{dispatch_semaphore_signal(retainedOwner);};
    NSCondition *stopBarrier=[NSCondition new]; __block BOOL afterSupervise=NO, releaseStop=NO;
    if(scenario==0)service.fixtureAfterSupervise=^{
      [stopBarrier lock]; afterSupervise=YES; [stopBarrier broadcast];
      NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
      while(!releaseStop && [stopBarrier waitUntilDate:deadline]) {} CHECK(releaseStop); [stopBarrier unlock];
    };
    NSCondition *startupBarrier=[NSCondition new]; __block BOOL startupPaused=NO, releaseStartup=NO;
    void (^pauseStartup)(void)=^{
      [startupBarrier lock]; startupPaused=YES; [startupBarrier broadcast];
      NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
      while(!releaseStartup && [startupBarrier waitUntilDate:deadline]) {} CHECK(releaseStartup); [startupBarrier unlock];
    };
    if(scenario==21||scenario==22) {
      KuroOwnedSession *baseline=[[KuroOwnedSession alloc] initWithDirectory:directory owner:geteuid()]; CHECK(baseline.off);
      [service snapshot:@"off" error:nil];
      if(scenario==21)hooks.preflight=^BOOL(NSDictionary *config,NSString **error) { (void)config;(void)error;pauseStartup();return YES; };
      else service.fixtureBeforeResume=pauseStartup;
    }
    starting=service;
    if(scenario==12)Put([directory stringByAppendingPathComponent:@"owner.json"],Bytes(@"foreign-owner"),0600);
    int pair[2]; CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));
    int serverPeer=pair[0];
    NSCondition *finished=[NSCondition new]; __block BOOL done=NO,result=NO; __block NSString *failure=nil;
    NSData *frame=scenario==10?Bytes(@"{\"version\":2,\"operation\":\"open\",\"config\":{},\"path\":\"/tmp/x\"}"):ServiceOpen();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
      NSString *error=nil; BOOL ok=[service serveOpenFrame:frame peer:serverPeer error:&error]; close(serverPeer);
      [finished lock]; result=ok;failure=error;done=YES;[finished broadcast];[finished unlock];
    });
    if(scenario==21||scenario==22) {
      [startupBarrier lock]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
      while(!startupPaused && [startupBarrier waitUntilDate:deadline]) {} CHECK(startupPaused);
      CHECK([[service statusSnapshot][@"state"] isEqual:@"unknown"]);
      [service requestStop]; CHECK([[service statusSnapshot][@"state"] isEqual:@"unknown"]);
      char unexpected; CHECK(recv(pair[1],&unexpected,1,MSG_DONTWAIT)==-1 && (errno==EAGAIN||errno==EWOULDBLOCK));
      if(scenario==22) {
        CHECK(ReadJSON(directory,[directory stringByAppendingPathComponent:@"owner.json"],geteuid(),NULL));
        CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work/resumed"]));
      }
      releaseStartup=YES; [startupBarrier broadcast]; [startupBarrier unlock];
    }
    NSDictionary *opened=ServiceRead(pair[1]);
    BOOL accepted=scenario==0 || scenario==8 || scenario==9 || scenario==11 || scenario==14 || scenario==15 || scenario==19 || scenario==20 || scenario==26;
    if(accepted) {
      if(![opened[@"ok"] boolValue])fprintf(stderr,"service scenario %lu open %s\n",(unsigned long)scenario,opened.description.UTF8String);
      CHECK([opened[@"ok"] boolValue] && [opened[@"status"][@"state"] isEqual:@"on"]);
      CHECK([[service statusSnapshot][@"state"] isEqual:@"on"]);
      if(scenario==0) {
        NSString *runtimePath=[directory stringByAppendingPathComponent:@"session-work/config.json"];
        CHECK([ReadJSON(directory,runtimePath,geteuid(),NULL)[@"interface-name"] isEqual:@"en0"]);
        NSDictionary *owner=ReadJSON(directory,[directory stringByAppendingPathComponent:@"owner.json"],geteuid(),NULL);
        CHECK([owner[@"format"]isEqual:@2]&&[owner[@"work"][@"configSHA256"]isEqual:Hash(ReadProtected(directory,runtimePath,geteuid(),NULL))]);
        struct stat socketValue={0};CHECK(!lstat([directory stringByAppendingPathComponent:@"session-work/core.sock"].fileSystemRepresentation,&socketValue));
        CHECK([owner[@"work"][@"socket"][@"inode"]unsignedLongLongValue]==socketValue.st_ino);
      }
      NSString *error=nil;
      if(scenario==0)CHECK(![service recoverNetworkOnly:&error] && residualRecoveries==0);
      CHECK([service writeMode:@"global" error:&error]); CHECK(![service writeMode:@"script" error:&error]);
      CHECK([service selectProxy:@"DIRECT" group:@"G/#" error:&error]);
      CHECK(![service selectProxy:@"missing" group:@"G/#" error:&error]);
      CHECK(![service selectProxy:@"DIRECT" group:@"unadmitted" error:&error]);
      int second[2]; CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,second)); CHECK(![service serveOpenFrame:ServiceOpen() peer:second[0] error:&error]);
      CHECK(![ServiceRead(second[1])[@"ok"] boolValue]); close(second[0]);close(second[1]);
      if(scenario==11) [service requestStop];
      else if(scenario==14) { @synchronized(identityLock) { identity=NO; } }
      else if(scenario==15)shutdown(pair[1],SHUT_RDWR);
      else {
        ServiceSend(pair[1],@{@"version":@2,@"operation":@"heartbeat",@"session":opened[@"session"],@"sequence":@1});
        CHECK([ServiceRead(pair[1])[@"sequence"] isEqual:@1]);
        ServiceSend(pair[1],@{@"version":@2,@"operation":@"stop",@"session":opened[@"session"],@"sequence":@2});
        NSDictionary *stopped=ServiceRead(pair[1]);
        CHECK([stopped[@"ok"] boolValue]==(scenario!=8&&scenario!=9&&scenario!=20&&scenario!=26));
        if(scenario==0) {
          // Hold the owner before its finally block: ack must already publish off.
          [stopBarrier lock]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
          while(!afterSupervise && [stopBarrier waitUntilDate:deadline]) {} CHECK(afterSupervise);
          CHECK([[service statusSnapshot][@"state"] isEqual:@"off"]);
          CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"]));
          CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work"]));
          releaseStop=YES; [stopBarrier broadcast]; [stopBarrier unlock];
        }
      }
    } else CHECK(opened && ![opened[@"ok"] boolValue]);
    if(scenario==8||scenario==9||scenario==20||scenario==26){ServiceWait(retainedOwner);[service requestShutdown];}
    [finished lock]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4]; while(!done && [finished waitUntilDate:deadline]) {} CHECK(done);[finished unlock];
    char trailing[256]; CHECK(recv(pair[1],trailing,sizeof(trailing),MSG_DONTWAIT)==0); close(pair[1]); starting=nil;
    if(scenario==8||scenario==9||scenario==20) {
      CHECK(!result && [[service statusSnapshot][@"state"] isEqual:@"unknown"]);
      CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"]));
      CHECK(Exists([directory stringByAppendingPathComponent:@"session-work"]));
    } else if(scenario==26) {CHECK(!result&&[[service statusSnapshot][@"state"]isEqual:@"unknown"]);CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"])&&!Exists([directory stringByAppendingPathComponent:@"session-work"]));CHECK(![service checkpointStopped:NULL]);CHECK(![service recoverNetworkOnly:NULL]);
    } else if(accepted) { CHECK(result && [[service statusSnapshot][@"state"] isEqual:@"off"]); CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"])); CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work"])); }
    else CHECK(!result && failure);
    if(scenario==1||scenario==2||scenario==3||scenario==10||scenario==12||scenario==13||scenario==16||scenario==25) { CHECK(applied==0 && recovered==0); CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"])==(scenario==12)); }
    if(scenario==21||scenario==22) {
      CHECK([[service statusSnapshot][@"state"] isEqual:@"off"] && applied==0);
      CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"]));
      CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work"]));
      CHECK(recovered==(scenario==22?1:0));
      if(scenario==22)CHECK([failure containsString:@"resume refused"]&&[failure containsString:@"stop or identity loss before Core resume"]);
    }
    CHECK(![service writeMode:@"rule" error:NULL]);
    if(scenario==0) {
      CHECK(healthChecks>0);
      CHECK([service recoverNetworkOnly:NULL] && residualRecoveries==2);
      NSString *journal=[directory stringByAppendingPathComponent:@"owner.json"];
      Put(journal,Bytes(@"unknown owner"),0600);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==2);
      CHECK(Exists(journal)); CHECK(!unlink(journal.fileSystemRepresentation));
      NSString *routes=[directory stringByAppendingPathComponent:@"network.json"],*dns=[directory stringByAppendingPathComponent:@"network-dns.json"];
      Put(routes,Bytes(@"retained route receipt"),0600); Put(dns,Bytes(@"retained DNS receipt"),0600);
      // A lying/incomplete recovery hook cannot publish off while receipts remain.
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==4);
      CHECK([[service statusSnapshot][@"state"]isEqual:@"unknown"] && Exists(routes) && Exists(dns));
      Put(journal,Bytes(@"unknown old Core owner"),0600);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==4 && Exists(journal)); CHECK(!unlink(journal.fileSystemRepresentation));
      FixtureDirectory([directory stringByAppendingPathComponent:@"session-work"]);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==5 && Exists(routes) && Exists(dns)); CHECK(!rmdir([directory stringByAppendingPathComponent:@"session-work"].fileSystemRepresentation));
      hooks.recoverResidualNetwork=^BOOL(NSString **error) {
        (void)error; residualRecoveries++;
        return (!Exists(routes)||!unlink(routes.fileSystemRepresentation)) && (!Exists(dns)||!unlink(dns.fileSystemRepresentation));
      };
      CHECK([service recoverNetworkOnly:NULL] && residualRecoveries==7);
      CHECK([[service statusSnapshot][@"state"]isEqual:@"off"] && !Exists(routes) && !Exists(dns));
    }
    CHECK([[NSFileManager defaultManager] removeItemAtPath:directory error:NULL]);
  }
  puts("native service: 27 fixture cases cover closed open, preflight gates, private HTTP, typed control, concurrent status, single owner, stop, bounded network-only receipt recovery, Core-owner refusal and work preservation");
}
