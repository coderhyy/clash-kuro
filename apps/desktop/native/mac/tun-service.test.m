#import "tun-service.m"
// This branch is compiled only into the ordinary-user test binary. No Core/network.
static int ServiceFixtureMain(int argc,const char **argv) {
  if(argc!=5 || strcmp(argv[1],"-d") || strcmp(argv[3],"-f"))return -1;
  if(geteuid()==0)return 91;
  @autoreleasepool {
    NSString *work=[NSString stringWithUTF8String:argv[2]],*config=[NSString stringWithUTF8String:argv[4]];
    if(![config isEqual:[work stringByAppendingPathComponent:@"config.json"]])return 92;
    NSDictionary *value=KuroDecodeJSON([NSData dataWithContentsOfFile:config],128*1024,NULL);
    NSString *socketPath=[work stringByAppendingPathComponent:@"core.sock"];
    if(![value[@"external-controller-unix"] isEqual:socketPath] || !KuroText(value[@"secret"],128))return 93;
    char cwd[PATH_MAX]; if(!getcwd(cwd,sizeof(cwd)) || ![work isEqual:[NSString stringWithUTF8String:cwd]])return 94;
    struct stat initialCache={0};NSString *cache=[work stringByAppendingPathComponent:@"cache.db"];
    if(lstat(cache.fileSystemRepresentation,&initialCache)||!SafeMetadata(initialCache,geteuid(),NO)||(initialCache.st_mode&07777)!=0600||initialCache.st_size!=0)return 99;
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
    struct sockaddr_un address={.sun_family=AF_UNIX}; strlcpy(address.sun_path,socketPath.fileSystemRepresentation,sizeof(address.sun_path));
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0 || bind(listener,(struct sockaddr *)&address,sizeof(address)) || listen(listener,4))return 97;
    for(;;) @autoreleasepool {
      int peer=accept(listener,NULL,NULL); if(peer<0)continue;
      unsigned char bytes[8192]; ssize_t count=recv(peer,bytes,sizeof(bytes),0);
      NSString *request=count>0 ? [[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding] : nil;
      if(![request containsString:[NSString stringWithFormat:@"Authorization: Bearer %@\r\n",value[@"secret"]]]) { close(peer); continue; }
      NSString *reply=nil;
      if([request hasPrefix:@"GET /version HTTP/1.1\r\n"]) {
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
      CHECK(!Exists(journal)&&!Exists(work));@synchronized(guard){proofs++;}
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
    NSMutableDictionary *config=ValidTunConfig();NSString *coreDigest=Hash([NSData dataWithContentsOfFile:core]);NSString *credential=[NSString stringWithFormat:@"%C-fixture-credential-unique\"/",[coreDigest characterAtIndex:coreDigest.length-1]];
    config[@"proxies"]=@[@{@"name":@"proxy",@"type":@"socks5",@"server":@"192.0.2.10",@"port":@1080,@"username":@"fixture-user-unique",@"password":credential,@"tls":@NO}];
    int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int peer=peers[0];
    __block BOOL result=NO;__block NSString *failure=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *error=nil;result=[service serveOpenFrame:JSONData(@{@"version":@2,@"operation":@"open",@"config":config}) peer:peer error:&error];failure=error;close(peer);dispatch_semaphore_signal(done);});
    NSDictionary *opened=ServiceRead(peers[1]);BOOL accepted=scenario==0||(scenario>=4&&scenario<=6);
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
      else CHECK([out containsString:@"fixture stdout secret=[REDACTED]"]&&[err containsString:@"fixture stderr secret=[REDACTED]"]);
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
    else {CHECK([service.statusSnapshot[@"state"]isEqual:@"unknown"]&&[[NSData dataWithContentsOfFile:ownerPath]isEqual:ownerBytes]);if(scenario==2)CHECK(Exists([work stringByAppendingPathComponent:@"cache.db"])&&[error containsString:@"cache lacks"]);}
    CHECK(!Exists([directory stringByAppendingPathComponent:@"stopped.json"]));CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  puts("native service DNS partial recovery: 5 persisted positive chains retain live/unknown/origin-only owner gates, permit exact final-cache recovery, aggregate real deletion errors and never issue stopped proof; no Core/network");
}
static void ServiceTests(void) {
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
    if(scenario==8||scenario==9||scenario==20){ServiceWait(retainedOwner);[service requestShutdown];}
    [finished lock]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4]; while(!done && [finished waitUntilDate:deadline]) {} CHECK(done);[finished unlock];
    char trailing[256]; CHECK(recv(pair[1],trailing,sizeof(trailing),MSG_DONTWAIT)==0); close(pair[1]); starting=nil;
    if(scenario==8||scenario==9||scenario==20) {
      CHECK(!result && [[service statusSnapshot][@"state"] isEqual:@"unknown"]);
      CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"]));
      CHECK(Exists([directory stringByAppendingPathComponent:@"session-work"]));
    } else if(scenario==26) {CHECK(!result&&[[service statusSnapshot][@"state"]isEqual:@"off"]&&[[service statusSnapshot][@"error"]containsString:@"uninstall checkpoint failed"]);CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"])&&!Exists([directory stringByAppendingPathComponent:@"session-work"]));CHECK(![service checkpointStopped:NULL]);CHECK([[service statusSnapshot][@"state"]isEqual:@"off"]&&[[service statusSnapshot][@"error"]containsString:@"uninstall checkpoint failed"]);CHECK([service recoverNetworkOnly:NULL]);CHECK([[service statusSnapshot][@"state"]isEqual:@"off"]&&[[service statusSnapshot][@"availability"]isEqual:@"blocked"]&&[[service statusSnapshot][@"error"]containsString:@"uninstall checkpoint failed"]);
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
