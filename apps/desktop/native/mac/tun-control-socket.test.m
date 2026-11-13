// Actual ServeAt/ServicePeer + actual KuroTunService; only OS network snapshots
// are substituted. No fixture listener or successful Core hook is supplied.
static NSUInteger ControlSocketCoreHookCalls=0;
static KuroTunService *ControlSocketService(NSString *prefix, BOOL drain, KuroFakeDNSStore **dnsOut) {
  NSString *directory=At(prefix,State);
  KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];
  KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
  KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];
  KuroTunServiceHooks *hooks=[KuroTunServiceHooks new];
  hooks.authorize=^BOOL(int peer,NSString *digest,NSString **error){(void)peer;(void)digest;if(drain){puts("authorize-entered");dispatch_semaphore_wait(dispatch_semaphore_create(0),DISPATCH_TIME_FOREVER);return Fail(error,@"drain fixture refuses authorization");}ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.preflight=^BOOL(NSDictionary *config,NSString **error){(void)config;(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.beforeStart=^BOOL(NSString **error){(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.beforeResume=^BOOL(NSString **error){(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.prepareNetwork=^BOOL(NSString *session,NSDictionary *binding,NSString **error){(void)session;(void)binding;(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.identityValid=^BOOL(int peer){(void)peer;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **error){(void)proof;(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.ready=^BOOL(pid_t child,NSString *session,NSString **error){(void)child;(void)session;(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **error){(void)child;(void)session;(void)error;ControlSocketCoreHookCalls++;CHECK(NO);return NO;};
  hooks.recoverNetwork=^BOOL(NSString *session,NSString **error){return [network recoverSession:session error:error];};
  hooks.recoverResidualNetwork=^BOOL(NSString **error){return [network recoverSession:nil error:error];};
  if(dnsOut)*dnsOut=dns;
  NSDictionary *installed=ReadJSON(prefix,[directory stringByAppendingPathComponent:@"installed.json"],geteuid(),NULL);CHECK(installed[@"release"]);
  NSString *core=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:[installed[@"release"]stringByAppendingPathComponent:@"mihomo"]]];
  return [[KuroTunService alloc]initFixtureInstallation:@{@"prefix":prefix,@"core":core} hooks:hooks];
}
static int ControlSocketFixtureMain(int argc,const char **argv) {
  if(argc!=4||strcmp(argv[1],"--control-socket-serve-fixture"))return -1;
  CHECK(geteuid()!=0);alarm(20);BOOL drain=!strcmp(argv[3],"drain");
  int result=ServeAt(@(argv[2]),geteuid(),ControlSocketService(@(argv[2]),drain,NULL));
  CHECK(ControlSocketCoreHookCalls==0);printf("serve-returned:%d\n",result);
  printf("core-start-hooks:%lu\n",(unsigned long)ControlSocketCoreHookCalls);
  if(drain){char finish;CHECK(read(STDIN_FILENO,&finish,1)==1);}
  return result;
}
typedef struct {pid_t pid;int input;int output;} ControlSocketChild;
static ControlSocketChild ControlSocketStart(NSString *prefix,BOOL drain) {
  int input[2],output[2];CHECK(!pipe(input)&&!pipe(output));
  posix_spawn_file_actions_t actions;CHECK(!posix_spawn_file_actions_init(&actions));
  CHECK(!posix_spawn_file_actions_adddup2(&actions,input[0],STDIN_FILENO)&&!posix_spawn_file_actions_adddup2(&actions,output[1],STDOUT_FILENO));
  for(int fd=0;fd<2;fd++){CHECK(!posix_spawn_file_actions_addclose(&actions,input[fd])&&!posix_spawn_file_actions_addclose(&actions,output[fd]));}
  char *args[]={(char *)Executable().fileSystemRepresentation,"--control-socket-serve-fixture",(char *)prefix.fileSystemRepresentation,drain?"drain":"normal",NULL};
  char *env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};ControlSocketChild child={0};
  CHECK(!posix_spawn(&child.pid,args[0],&actions,NULL,args,env));posix_spawn_file_actions_destroy(&actions);
  close(input[0]);close(output[1]);child.input=input[1];child.output=output[0];return child;
}
static NSString *ControlSocketLine(ControlSocketChild child) {
  NSMutableData *line=[NSMutableData data];uint64_t deadline=KuroMonotonicMilliseconds()+6000;
  while(KuroMonotonicMilliseconds()<deadline&&line.length<256){struct pollfd ready={.fd=child.output,.events=POLLIN};if(poll(&ready,1,20)<=0)continue;char c;ssize_t count=read(child.output,&c,1);CHECK(count==1);if(c=='\n')return [[NSString alloc]initWithData:line encoding:NSUTF8StringEncoding];[line appendBytes:&c length:1];}CHECK(NO);return nil;
}
static int ControlSocketConnect(NSString *prefix) {
  NSString *path=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"control.sock"]);struct sockaddr_un address;CHECK(KuroUnixSocketAddress(path,&address,NULL));
  int peer=socket(AF_UNIX,SOCK_STREAM,0);CHECK(peer>=0);if(connect(peer,(struct sockaddr *)&address,sizeof(address))){close(peer);return -1;}return peer;
}
static void ControlSocketAwait(NSString *prefix,ControlSocketChild child) {
  uint64_t deadline=KuroMonotonicMilliseconds()+3000;int peer=-1;
  while(KuroMonotonicMilliseconds()<deadline){int status;CHECK(waitpid(child.pid,&status,WNOHANG)==0);peer=ControlSocketConnect(prefix);if(peer>=0)break;struct timespec pause={.tv_nsec=10000000};nanosleep(&pause,NULL);}CHECK(peer>=0);
  ServiceSend(peer,@{@"version":@1,@"operation":@"status"});NSDictionary *reply=ServiceRead(peer);CHECK([reply[@"ok"]boolValue]&&[reply[@"status"][@"state"]isEqual:@"off"]);close(peer);
}
static void ControlSocketWait(ControlSocketChild child,int expectedSignal,int expectedExit) {
  int status=0;CHECK(waitpid(child.pid,&status,0)==child.pid);
  if(expectedSignal)CHECK(WIFSIGNALED(status)&&WTERMSIG(status)==expectedSignal);else CHECK(WIFEXITED(status)&&WEXITSTATUS(status)==expectedExit);
  close(child.input);close(child.output);
}
static void ControlSocketRecoverAndUninstall(NSString *prefix) {
  NSString *error=nil,*directory=At(prefix,State);KuroFakeDNSStore *dns=nil;
  KuroTunService *service=ControlSocketService(prefix,NO,&dns);
  // Actual protected DNS journal, actual service recovery, actual production
  // network coordinator. The fake OS store is the only DNS write target.
  KuroOwnedDNS *owned=[[KuroOwnedDNS alloc]initWithDirectory:directory owner:geteuid() backend:dns];
  CHECK([owned installPreparedSession:@"00112233-4455-6677-8899-AABBCCDDEEFF" admission:^BOOL(NSString **failure){(void)failure;return YES;} error:&error]);
  CHECK(Exists([directory stringByAppendingPathComponent:KuroDNSJournal])&&dns.additions==1);
  BOOL recovered=[service recoverNetworkOnly:&error];if(!recovered)fprintf(stderr,"control lifecycle recovery refused: %s\n",error.UTF8String);
  CHECK(recovered&&dns.removals==1&&!Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
  CHECK([service.statusSnapshot[@"state"]isEqual:@"off"]&&[service.statusSnapshot[@"availability"]isEqual:@"ready"]);
  CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));
  for(NSString *path in @[Tools,State,SocketDirectory,FreshReceipt,Recovery,ClientBundle,Plist])CHECK(!Exists(At(prefix,path)));
}
static NSDictionary *ControlSocketInstallationIdentity(NSString *prefix) {
  NSDictionary *receipt=ReadFreshReceipt(prefix,geteuid(),NULL);CHECK(receipt);
  NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:receipt[@"manifest"][@"release"]]];
  NSMutableDictionary *files=[NSMutableDictionary dictionary];
  for(NSString *path in @[At(prefix,FreshReceipt),At(prefix,Recovery),[At(prefix,Tools)stringByAppendingPathComponent:@"installer"],[version stringByAppendingPathComponent:@"helper"],[version stringByAppendingPathComponent:@"mihomo"],[version stringByAppendingPathComponent:@"manifest.json"],At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),At(prefix,[State stringByAppendingPathComponent:@"client.json"])]) {
    NSString *hash=InstallFileHash(prefix,path,geteuid(),NULL);CHECK(hash);files[path]=hash;
  }
  return @{@"files":files,@"completeClient":FixtureInventory(At(prefix,ClientBundle))};
}
static int ControlSocketBind(NSString *prefix,BOOL listenNow,mode_t mode) {
  struct sockaddr_un address;CHECK(KuroUnixSocketAddress(At(prefix,[SocketDirectory stringByAppendingPathComponent:@"control.sock"]),&address,NULL));
  int endpoint=socket(AF_UNIX,SOCK_STREAM,0);CHECK(endpoint>=0&&!bind(endpoint,(struct sockaddr *)&address,sizeof(address)));
  CHECK(!chmod(address.sun_path,mode));if(listenNow)CHECK(!listen(endpoint,2));return endpoint;
}
static void ControlSocketLifecycleTests(void) {
  CHECK(geteuid()!=0);
  for(NSUInteger scenario=0;scenario<11;scenario++){@autoreleasepool{
    char temporary[]="/tmp/kcs-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *prefix=@(canonical),*error=nil;
    (void)InstallationBindingFixtureAt(prefix,prefix,YES);NSString *path=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"control.sock"]);
    if(scenario==7) {
      ControlSocketChild child=ControlSocketStart(prefix,NO);ControlSocketAwait(prefix,child);NSDictionary *identity=ControlSocketInstallationIdentity(prefix);
      NSString *old=[path stringByAppendingString:@".previous"];CHECK(!rename(path.fileSystemRepresentation,old.fileSystemRepresentation));
      int replacement=ControlSocketBind(prefix,NO,0666);close(replacement);struct stat before,after;CHECK(!lstat(path.fileSystemRepresentation,&before));
      CHECK(!kill(child.pid,SIGTERM));ControlSocketWait(child,0,1);
      CHECK(!lstat(path.fileSystemRepresentation,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&Exists(old));
      CHECK([ControlSocketInstallationIdentity(prefix)isEqual:identity]);
    }else if(scenario>=8) {
      int lock=ServiceLock(prefix,geteuid(),&error);CHECK(lock>=0);close(lock);int endpoint=-1;
      if(scenario==8) {endpoint=ControlSocketBind(prefix,NO,0600);close(endpoint);endpoint=-1;}
      if(scenario==9)endpoint=ControlSocketBind(prefix,YES,0666); // real listener without service lock
      NSString *extra=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"unknown-extra"]);if(scenario==10)Put(extra,Bytes(@"preserve unknown bytes"),0600);
      NSDictionary *identity=ControlSocketInstallationIdentity(prefix);struct stat before={0},after={0};if(scenario!=10)CHECK(!lstat(path.fileSystemRepresentation,&before));
      if(scenario==8) {
        // Saved-identity negatives only: actual socket ownership is unchanged.
        int held=ServiceLock(prefix,geteuid(),&error);CHECK(held>=0);
        for(NSUInteger field=0;field<2;field++) {
          struct stat expected=before,unchanged;
          if(field==0)expected.st_uid=before.st_uid^1u;else expected.st_gid=before.st_gid^1u;
          error=nil;CHECK(!ControlSocketEndpoint(prefix,geteuid(),held,&expected,YES,&error));
          CHECK([error containsString:@"unknown or changed control socket"]&&!lstat(path.fileSystemRepresentation,&unchanged));
          CHECK(unchanged.st_dev==before.st_dev&&unchanged.st_ino==before.st_ino&&unchanged.st_uid==before.st_uid&&unchanged.st_gid==before.st_gid);
          CHECK([ControlSocketInstallationIdentity(prefix)isEqual:identity]);
        }
        close(held);
      }
      CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK([ControlSocketInstallationIdentity(prefix)isEqual:identity]);
      if(scenario!=10)CHECK(!lstat(path.fileSystemRepresentation,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino);
      if(scenario==8)CHECK([error containsString:@"unknown or changed control socket"]);
      if(scenario==9)CHECK([error containsString:@"live or unknown control socket"]);
      if(scenario==10)CHECK([[NSData dataWithContentsOfFile:extra]isEqual:Bytes(@"preserve unknown bytes")]);
      if(endpoint>=0)close(endpoint);
    }else if(scenario<4||scenario==6){
      BOOL drain=scenario==6;ControlSocketChild child=ControlSocketStart(prefix,drain);ControlSocketAwait(prefix,child);
      struct stat before,after;CHECK(!lstat(path.fileSystemRepresentation,&before)&&S_ISSOCK(before.st_mode)&&(before.st_mode&07777)==0666);
      if(scenario==0){
        // V1 recover still uses production peer authorization. An unapproved
        // ordinary test executable cannot reach the service recovery hook.
        int peer=ControlSocketConnect(prefix);CHECK(peer>=0);ServiceSend(peer,@{@"version":@1,@"operation":@"recover"});NSDictionary *reply=ServiceRead(peer);CHECK(![reply[@"ok"]boolValue]);close(peer);
      }
      if(scenario==3){CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!lstat(path.fileSystemRepresentation,&after)&&before.st_ino==after.st_ino&&Exists(At(prefix,FreshReceipt)));}
      if(drain){
        int peer=ControlSocketConnect(prefix);CHECK(peer>=0);NSData *open=ServiceOpen();CHECK(send(peer,open.bytes,open.length,MSG_NOSIGNAL)==(ssize_t)open.length&&send(peer,"\n",1,MSG_NOSIGNAL)==1);
        CHECK([ControlSocketLine(child)isEqual:@"authorize-entered"]);CHECK(!kill(child.pid,SIGTERM));CHECK([ControlSocketLine(child)isEqual:@"serve-returned:1"]);
        CHECK(ServiceLock(prefix,geteuid(),&error)<0&&[error containsString:@"lock"]);CHECK(!Exists(path));
        CHECK(write(child.input,"x",1)==1);close(peer);ControlSocketWait(child,0,1);
      }else if(scenario==1||scenario==2){
        CHECK(!kill(child.pid,SIGKILL));ControlSocketWait(child,SIGKILL,0);CHECK(!lstat(path.fileSystemRepresentation,&after)&&before.st_ino==after.st_ino);
        if(scenario==1){ControlSocketChild restarted=ControlSocketStart(prefix,NO);ControlSocketAwait(prefix,restarted);CHECK(!lstat(path.fileSystemRepresentation,&after));CHECK(!kill(restarted.pid,SIGTERM));ControlSocketWait(restarted,0,0);CHECK(!Exists(path));}
      }else{CHECK(!kill(child.pid,SIGTERM));ControlSocketWait(child,0,0);CHECK(!Exists(path));}
      CHECK([ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),geteuid(),NULL)[@"neverStarted"]isEqual:@YES]);
      CHECK(!Exists(At(prefix,[State stringByAppendingPathComponent:@"owner.json"]))&&!Exists(At(prefix,[State stringByAppendingPathComponent:@"session-work"])));
      ControlSocketRecoverAndUninstall(prefix);
    }else{
      int lock=ServiceLock(prefix,geteuid(),&error);CHECK(lock>=0);close(lock);
      if(scenario==4)Put(path,Bytes(@"unknown regular endpoint"),0666);else CHECK(!symlink("unknown-target",path.fileSystemRepresentation));
      struct stat before,after;CHECK(!lstat(path.fileSystemRepresentation,&before));
      CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK([error containsString:@"control socket"]&&!lstat(path.fileSystemRepresentation,&after)&&before.st_ino==after.st_ino&&Exists(At(prefix,FreshReceipt))&&Exists(At(prefix,ClientBundle)));
    }
    CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
    printf("PASS actual Serve/control socket lifecycle scenario=%lu noCore\n",(unsigned long)scenario);
  }}
}
