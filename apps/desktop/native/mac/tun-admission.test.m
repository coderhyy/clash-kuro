// Ordinary-UID integration only. The relay is this test executable copied into
// the actually signed/pinned fixture bundle; it is never a production client.
static int AdmissionListener(NSString *path) {
  int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un address={.sun_family=AF_UNIX};
  CHECK(fd>=0&&strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path))<sizeof(address.sun_path));
  CHECK(!bind(fd,(struct sockaddr *)&address,sizeof(address))&&!listen(fd,16));return fd;
}
static int AdmissionConnect(NSString *path) {
  int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un address={.sun_family=AF_UNIX};
  CHECK(fd>=0&&strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path))<sizeof(address.sun_path));CHECK(!connect(fd,(struct sockaddr *)&address,sizeof(address)));return fd;
}
static BOOL AdmissionSend(int fd,const void *bytes,size_t count) {
  size_t offset=0;while(offset<count){ssize_t written=send(fd,(const char *)bytes+offset,count-offset,MSG_NOSIGNAL);if(written<0&&errno==EINTR)continue;if(written<=0)return NO;offset+=(size_t)written;}return YES;
}
static void AdmissionRelay(int frontend,int backend) {
  BOOL readFront=YES,readBack=YES;
  while(readFront||readBack) {
    struct pollfd waits[2]={{.fd=readFront?frontend:-1,.events=POLLIN},{.fd=readBack?backend:-1,.events=POLLIN}};
    int count=poll(waits,2,1000);if(count<0&&errno==EINTR)continue;if(count<0)break;
    for(int index=0;index<2;index++)if(waits[index].revents&(POLLIN|POLLHUP|POLLERR)) {
      unsigned char bytes[4096];int from=index?backend:frontend,to=index?frontend:backend;ssize_t length=recv(from,bytes,sizeof(bytes),0);
      if(length<0&&errno==EINTR)continue;
      if(length<=0){if(index)readBack=NO;else readFront=NO;(void)shutdown(to,SHUT_WR);}
      else if(!AdmissionSend(to,bytes,(size_t)length))return;
    }
  }
}
static int AdmissionRelayMain(NSString *backend,NSString *frontend) {
  int listener=AdmissionListener(frontend);CHECK(write(STDOUT_FILENO,"R",1)==1);dispatch_group_t workers=dispatch_group_create();
  for(;;){struct pollfd waits[2]={{.fd=listener,.events=POLLIN},{.fd=STDIN_FILENO,.events=POLLIN}};CHECK(poll(waits,2,30000)>0);
    if(waits[1].revents&(POLLIN|POLLHUP)){char byte;CHECK(read(STDIN_FILENO,&byte,1)==0);break;}
    if(waits[0].revents&POLLIN){int peer=accept(listener,NULL,NULL);CHECK(peer>=0);dispatch_group_async(workers,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{int native=AdmissionConnect(backend);AdmissionRelay(peer,native);close(native);close(peer);});}
  }
  close(listener);CHECK(dispatch_group_wait(workers,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);CHECK(!unlink(frontend.fileSystemRepresentation));return 0;
}
static NSData *AdmissionFrame(int peer) {
  NSMutableData *frame=[NSMutableData data];uint64_t deadline=KuroMonotonicMilliseconds()+2000;
  while(frame.length<=OpenMessageLimit&&KuroMonotonicMilliseconds()<deadline){struct pollfd wait={.fd=peer,.events=POLLIN};if(poll(&wait,1,100)<=0)continue;unsigned char bytes[4096];ssize_t count=recv(peer,bytes,sizeof(bytes),0);if(count<=0)break;[frame appendBytes:bytes length:(NSUInteger)count];if(memchr(bytes,'\n',(size_t)count))break;}
  return frame;
}
// Decode sanitized recorded Darwin packets before entering the production recovery/start chain.
// Only interface-name resolution is substituted; no live sysctl or interface lookup.
static NSArray *AdmissionDecodedBaseline(NSString **error) {
  NSMutableData *dump=[NSMutableData data];
  for(NSData *packet in DarwinRouteFixturePackets())[dump appendData:packet];
  NSArray *decoded=KuroRouteDecodeDump(dump,error);if(!decoded)return nil;CHECK(decoded.count==4);
  NSMutableArray *baseline=[NSMutableArray arrayWithObjects:ProductionBaseline()[0],ProductionBaseline()[1],nil];
  NSDictionary *names=@{@1:@"lo0",@2:@"en0"};
  for(NSDictionary *entry in decoded) {
    NSString *name=names[entry[@"interfaceIndex"]];CHECK(name&&(![entry[@"interfaceName"]length]||[entry[@"interfaceName"]isEqual:name]));
    NSMutableDictionary *resolved=[entry mutableCopy];resolved[@"interfaceName"]=name;[baseline addObject:resolved];
  }
  CHECK([baseline[3][@"destination"]isEqual:@"192.168.1.0"]&&[baseline[3][@"prefix"]isEqual:@24]);
  CHECK([baseline[5][@"destination"]isEqual:@"fe80::1234%2"]&&[baseline[5][@"interfaceIndex"]isEqual:@1]);
  return baseline;
}
@interface KuroAdmissionRouteStore : KuroFakeRouteStore
@property(atomic) NSUInteger decodedBaselineRoutes;
@end
@implementation KuroAdmissionRouteStore
- (NSArray *)routes:(NSString **)error {
  NSArray *overlay=[super routes:error];if(!overlay)return nil;
  self.decodedBaselineRoutes=0;NSArray *baseline=AdmissionDecodedBaseline(error);if(!baseline)return nil;
  self.decodedBaselineRoutes=baseline.count-2;return [baseline arrayByAddingObjectsFromArray:overlay];
}
@end
static int AdmissionChainMain(NSString *mode) {
  CHECK(geteuid()!=0);CHECK(([@[@"fresh",@"residue",@"recovery-failed",@"auth-only",@"identity",@"invalid-config",@"finalizing"]containsObject:mode]));alarm(30);
  char temporary[]="/tmp/ka-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil;
  NSDictionary *installation=InstallationBindingFixtureAt(base,base,![mode isEqual:@"auth-only"]);NSString *state=At(base,State),*back=[base stringByAppendingPathComponent:@"b"],*front=[base stringByAppendingPathComponent:@"f"];
  KuroFakeRouteStore *routes=[mode isEqual:@"fresh"]?[KuroAdmissionRouteStore new]:[KuroFakeRouteStore new];routes.directory=state;if(![mode isEqual:@"fresh"])routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=state;
  if([mode isEqual:@"fresh"])dns.records=[DarwinDNSMetadataFixture() mutableCopy];
  NSDictionary *baselineDNS=[dns.records copy];
  if([mode isEqual:@"residue"]||[mode isEqual:@"recovery-failed"]){KuroOwnedDNS *old=[[KuroOwnedDNS alloc]initWithDirectory:state owner:geteuid() backend:dns];CHECK([old installForSession:@"00112233-4455-6677-8899-AABBCCDDEEFF" error:&error]);dns.failRemove=[mode isEqual:@"recovery-failed"];}
  __block KuroProductionNetwork *network=nil;__block KuroCoreInterface association={0};__block NSArray *interfaces=ProductionInterfaces(NO);__block KuroRouteOwnerState owner=KuroRouteOwnerLive;
  __block NSUInteger recoveries=0,authorizations=0,starts=0,applications=0,opens=0,recoverRefusals=0;__block BOOL finalizing=NO;
  NSObject *stats=[NSObject new];dispatch_semaphore_t finish=dispatch_semaphore_create(0);
  BOOL (^authorize)(int,NSString **)=^BOOL(int peer,NSString **failure){BOOL ok=AuthorizeClientAt(peer,base,geteuid(),failure)&&KuroSessionActivationAt(base,geteuid(),installation[@"helper"],failure);if(ok)@synchronized(stats){authorizations++;}return ok;};
  KuroTunServiceHooks *hooks=ServiceHooks();
  hooks.authorize=^BOOL(int peer,NSString *digest,NSString **failure){return Match(digest,@"\\A[0-9a-f]{64}\\z")&&authorize(peer,failure);};
  hooks.identityValid=^BOOL(int peer){return AuthorizeClientAt(peer,base,geteuid(),NULL);};
  hooks.beforeStart=^BOOL(NSString **failure){return KuroRevokeStoppedProof(base,geteuid(),failure);};
  hooks.beforeResume=^BOOL(NSString **failure){BOOL ok=KuroMarkSessionStarted(base,geteuid(),installation[@"helper"],failure);if(ok)@synchronized(stats){starts++;}return ok;};
  hooks.preflight=^BOOL(NSDictionary *config,NSString **failure){
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **ignored){(void)ignored;return interfaces;};
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *observed,NSString **problem){struct proc_bsdinfo value={0};if(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&value,sizeof(value))!=sizeof(value)||value.pbi_ppid!=(uint32_t)getpid())return Fail(problem,@"fixture Core must be our exact live direct child");association=(KuroCoreInterface){.process={.pid=child,.startSeconds=value.pbi_start_tvsec,.startMicros=value.pbi_start_tvusec},.descriptor=3,.controlID=42,.controlUnit=8,.socketHandle=100,.pcbHandle=200,.interfaceIndex=7};strlcpy(association.interfaceName,"utun7",sizeof(association.interfaceName));*observed=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **ignored){(void)ignored;CHECK([KuroRouteAssociation(expected)isEqual:KuroRouteAssociation(association)]);return owner;};
    environment.probeDNS=^BOOL(KuroCoreInterface observed,NSString **problem){
      NSArray *current=[routes routes:problem];if(!current)return NO;
      for(NSArray *target in @[@[@4,@"198.18.0.2",@32],@[@6,@"fdfe:dcba:9876::2",@128]]) {
        NSDictionary *expected=@{@"family":target[0],@"destination":target[1],@"prefix":target[2],@"gateway":@"link",@"interfaceIndex":@(observed.interfaceIndex),@"interfaceName":@(observed.interfaceName)};NSUInteger count=0;
        for(NSDictionary *entry in current)if(KuroRouteEqual(entry,expected))count++;
        if(count!=1)return Fail(problem,@"fixture point-to-point internal DNS path is absent or ambiguous");
      }
      return YES;
    }; // Isolated DNS responses require actual coordinator-installed exact host routes.
    network=[[KuroProductionNetwork alloc]initWithDirectory:state owner:geteuid() routes:routes dns:dns environment:environment];return [network preflightConfig:config error:failure];
  };
  hooks.physicalInterface=^NSString *{return network.runtimeInterfaceName;};hooks.readinessHosts=^NSDictionary *{return KuroProductionRuntimeFields()[@"hosts"];};
  hooks.ready=^BOOL(pid_t child,NSString *session,NSString **failure){interfaces=ProductionInterfaces(YES);[routes.entries addObject:ProductionRoute(4,@"198.18.0.1",32,@"link",@"utun7",7,RTF_UP|RTF_HOST)];[routes.entries addObject:ProductionRoute(6,@"fdfe:dcba:9876::",126,@"link",@"utun7",7,RTF_UP)];return [network readyChild:child session:session error:failure];};
  hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **failure){BOOL ok=[network applyChild:child session:session error:failure];if(ok)@synchronized(stats){applications++;}return ok;};
  hooks.verifyNetwork=^BOOL(NSString *session,NSString **failure){return [network confirmSession:session error:failure];};
  hooks.recoverNetwork=^BOOL(NSString *session,NSString **failure){owner=KuroRouteOwnerExitedInterfaceGone;interfaces=ProductionInterfaces(NO);NSIndexSet *own=[routes.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop){(void)index;(void)stop;return [entry[@"interfaceName"]isEqual:@"utun7"];}];[routes.entries removeObjectsAtIndexes:own];return [network recoverSession:session error:failure];};
  hooks.recoverResidualNetwork=^BOOL(NSString **failure){@synchronized(stats){recoveries++;}KuroProductionNetwork *fresh=[[KuroProductionNetwork alloc]initWithDirectory:state owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];return [fresh recoverSession:nil error:failure];};
  NSMutableDictionary *fixtureInstallation=[installation mutableCopy];NSString *childFixture=[state stringByAppendingPathComponent:@"core"];NSData *fixedBytes=ReadProtected(base,installation[@"core"],geteuid(),&error);CHECK(fixedBytes);Put(childFixture,fixedBytes,0755);fixtureInstallation[@"core"]=childFixture;
  KuroTunService *service=[[KuroTunService alloc]initFixtureInstallation:fixtureInstallation hooks:hooks];
  if([mode isEqual:@"finalizing"])service.fixtureAfterSupervise=^{@synchronized(stats){finalizing=YES;}CHECK(dispatch_semaphore_wait(finish,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);};
  int listener=AdmissionListener(back),relayInput[2],relayOutput[2];CHECK(!pipe(relayInput)&&!pipe(relayOutput));
  posix_spawn_file_actions_t actions;CHECK(!posix_spawn_file_actions_init(&actions));CHECK(!posix_spawn_file_actions_adddup2(&actions,relayInput[0],STDIN_FILENO)&&!posix_spawn_file_actions_adddup2(&actions,relayOutput[1],STDOUT_FILENO));
  CHECK(!posix_spawn_file_actions_addclose(&actions,relayInput[1])&&!posix_spawn_file_actions_addclose(&actions,relayOutput[0]));
  NSString *client=[At(base,ClientBundle)stringByAppendingPathComponent:ClientExecutable];char *args[]={(char *)client.fileSystemRepresentation,"--admission-relay",(char *)back.fileSystemRepresentation,(char *)front.fileSystemRepresentation,NULL},*env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t relay=0;
  CHECK(!posix_spawn(&relay,args[0],&actions,NULL,args,env));posix_spawn_file_actions_destroy(&actions);close(relayInput[0]);close(relayOutput[1]);char ready;CHECK(read(relayOutput[0],&ready,1)==1&&ready=='R');close(relayOutput[0]);
  __block BOOL running=YES;dispatch_group_t peers=dispatch_group_create();dispatch_queue_t acceptQueue=dispatch_queue_create("kuro.fixture.accept",DISPATCH_QUEUE_SERIAL);
  dispatch_group_async(peers,acceptQueue,^{for(;;){@synchronized(stats){if(!running)break;}struct pollfd incoming={.fd=listener,.events=POLLIN};if(poll(&incoming,1,50)<=0)continue;int peer=accept(listener,NULL,NULL);if(peer<0)continue;
    dispatch_group_async(peers,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSData *frame=AdmissionFrame(peer);NSString *failure=nil;id decoded=KuroDecodeJSON(frame,OpenMessageLimit,&failure);
      if([decoded isKindOfClass:NSDictionary.class]&&KuroNumber(decoded[@"version"],2,2)){@synchronized(stats){opens++;}(void)[service serveOpenFrame:frame peer:peer error:&failure];}
      else {NSString *operation=ParseRequest(frame,&failure);NSDictionary *reply=nil;
        if([operation isEqual:@"status"])reply=@{@"version":@1,@"ok":@YES,@"status":service.statusSnapshot};
        else if([operation isEqual:@"recover"]&&authorize(peer,&failure)){BOOL ok=[service recoverNetworkOnly:&failure];if(!ok)@synchronized(stats){recoverRefusals++;}reply=ok?@{@"version":@1,@"ok":@YES,@"status":service.statusSnapshot}:ErrorResponse(failure);}
        else reply=ErrorResponse(failure?:@"fixture accepts only status/recover/open");
        (void)KuroServiceReply(peer,reply);
      }close(peer);
    });
  }});
  NSData *info=JSONData(@{@"front":front,@"backend":back,@"initial":[service statusSnapshot]});CHECK(fwrite(info.bytes,1,info.length,stdout)==info.length&&fputc('\n',stdout)!=EOF&&!fflush(stdout));
  char *line=NULL;size_t capacity=0;
  while(getline(&line,&capacity,stdin)>0){NSString *command=[@(line)stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([command isEqual:@"release"]){dispatch_semaphore_signal(finish);puts("{}");fflush(stdout);}
    else if([command isEqual:@"stats"]){@synchronized(stats){NSDictionary *value=@{@"decodedBaselineRoutes":@([routes isKindOfClass:KuroAdmissionRouteStore.class]?[(KuroAdmissionRouteStore *)routes decodedBaselineRoutes]:0),@"recoveries":@(recoveries),@"authorizations":@(authorizations),@"starts":@(starts),@"applications":@(applications),@"opens":@(opens),@"recoverRefusals":@(recoverRefusals),@"finalizing":@(finalizing),@"status":service.statusSnapshot,@"routeAdds":@(routes.additions),@"routeRemovals":@(routes.deletions),@"dnsAdds":@(dns.additions),@"dnsRemovals":@(dns.removals),@"ownerAbsent":@((BOOL)!Exists([state stringByAppendingPathComponent:@"owner.json"])),@"workAbsent":@((BOOL)!Exists([state stringByAppendingPathComponent:@"session-work"])),@"dnsJournalAbsent":@((BOOL)!Exists([state stringByAppendingPathComponent:KuroDNSJournal]))};NSData *bytes=JSONData(value);fwrite(bytes.bytes,1,bytes.length,stdout);puts("");fflush(stdout);}}
    else CHECK([command isEqual:@"quit"]);if([command isEqual:@"quit"])break;
  }free(line);dispatch_semaphore_signal(finish);[service requestShutdown];@synchronized(stats){running=NO;}CHECK(dispatch_group_wait(peers,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);close(listener);CHECK(!unlink(back.fileSystemRepresentation));close(relayInput[1]);int status=0;CHECK(waitpid(relay,&status,0)==relay&&WIFEXITED(status)&&!WEXITSTATUS(status));
  CHECK(!Exists([state stringByAppendingPathComponent:@"owner.json"])&&!Exists([state stringByAppendingPathComponent:@"session-work"]));
  if(![mode isEqual:@"recovery-failed"])CHECK([dns.records isEqual:baselineDNS]);
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);return 0;
}
static int AdmissionFixtureMain(int argc,const char **argv) {
  if(argc==4&&!strcmp(argv[1],"--admission-relay"))return AdmissionRelayMain(@(argv[2]),@(argv[3]));
  if(argc==3&&!strcmp(argv[1],"--admission-chain"))return AdmissionChainMain(@(argv[2]));return -1;
}
