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
static void ServiceTests(void) {
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
  for(NSUInteger scenario=0;scenario<23;scenario++) {
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
    BOOL accepted=scenario==0 || scenario==8 || scenario==9 || scenario==11 || scenario==14 || scenario==15 || scenario==19 || scenario==20;
    if(accepted) {
      if(![opened[@"ok"] boolValue])fprintf(stderr,"service scenario %lu open %s\n",(unsigned long)scenario,opened.description.UTF8String);
      CHECK([opened[@"ok"] boolValue] && [opened[@"status"][@"state"] isEqual:@"on"]);
      CHECK([[service statusSnapshot][@"state"] isEqual:@"on"]);
      if(scenario==0)CHECK([ReadJSON(directory,[directory stringByAppendingPathComponent:@"session-work/config.json"],geteuid(),NULL)[@"interface-name"] isEqual:@"en0"]);
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
        CHECK([stopped[@"ok"] boolValue]==(scenario!=8&&scenario!=9&&scenario!=20));
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
    [finished lock]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4]; while(!done && [finished waitUntilDate:deadline]) {} CHECK(done);[finished unlock];
    char trailing[256]; CHECK(recv(pair[1],trailing,sizeof(trailing),MSG_DONTWAIT)==0); close(pair[1]); starting=nil;
    if(scenario==8||scenario==9||scenario==20) {
      CHECK(!result && [[service statusSnapshot][@"state"] isEqual:@"unknown"]);
      CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"]));
      CHECK(Exists([directory stringByAppendingPathComponent:@"session-work"]));
    } else if(accepted) { CHECK(result && [[service statusSnapshot][@"state"] isEqual:@"off"]); CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"])); CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work"])); }
    else CHECK(!result && failure);
    if(scenario==1||scenario==2||scenario==3||scenario==10||scenario==12||scenario==13||scenario==16) { CHECK(applied==0 && recovered==0); CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"])==(scenario==12)); }
    if(scenario==21||scenario==22) {
      CHECK([[service statusSnapshot][@"state"] isEqual:@"off"] && applied==0);
      CHECK(!Exists([directory stringByAppendingPathComponent:@"owner.json"]));
      CHECK(!Exists([directory stringByAppendingPathComponent:@"session-work"]));
      CHECK(recovered==(scenario==22?1:0));
      if(scenario==22)CHECK([failure containsString:@"resume refused"]);
    }
    CHECK(![service writeMode:@"rule" error:NULL]);
    if(scenario==0) {
      CHECK(healthChecks>0);
      CHECK([service recoverNetworkOnly:NULL] && residualRecoveries==1);
      NSString *journal=[directory stringByAppendingPathComponent:@"owner.json"];
      Put(journal,Bytes(@"unknown owner"),0600);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==1);
      CHECK(Exists(journal)); CHECK(!unlink(journal.fileSystemRepresentation));
      NSString *routes=[directory stringByAppendingPathComponent:@"network.json"],*dns=[directory stringByAppendingPathComponent:@"network-dns.json"];
      Put(routes,Bytes(@"retained route receipt"),0600); Put(dns,Bytes(@"retained DNS receipt"),0600);
      // A lying/incomplete recovery hook cannot publish off while receipts remain.
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==2);
      CHECK([[service statusSnapshot][@"state"]isEqual:@"unknown"] && Exists(routes) && Exists(dns));
      Put(journal,Bytes(@"unknown old Core owner"),0600);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==2 && Exists(journal)); CHECK(!unlink(journal.fileSystemRepresentation));
      FixtureDirectory([directory stringByAppendingPathComponent:@"session-work"]);
      CHECK(![service recoverNetworkOnly:NULL] && residualRecoveries==2 && Exists(routes) && Exists(dns)); CHECK(!rmdir([directory stringByAppendingPathComponent:@"session-work"].fileSystemRepresentation));
      hooks.recoverResidualNetwork=^BOOL(NSString **error) {
        (void)error; residualRecoveries++; CHECK(Exists(routes) && Exists(dns));
        return !unlink(routes.fileSystemRepresentation) && !unlink(dns.fileSystemRepresentation);
      };
      CHECK([service recoverNetworkOnly:NULL] && residualRecoveries==3);
      CHECK([[service statusSnapshot][@"state"]isEqual:@"off"] && !Exists(routes) && !Exists(dns));
    }
    CHECK([[NSFileManager defaultManager] removeItemAtPath:directory error:NULL]);
  }
  puts("native service: 23 fixture cases cover closed open, preflight gates, private HTTP, typed control, concurrent status, single owner, stop, bounded network-only receipt recovery, Core-owner refusal and work preservation");
}
