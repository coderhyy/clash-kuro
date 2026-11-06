// Observation grants no session or network capability. The same client policy
// runs before every production privileged request.
static NSDictionary *AuthenticateRequestAt(NSData *data, int peer, NSString *prefix, uid_t owner) {
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSString *pattern = @"\\A\\s*\\{\\s*(?:\"version\"\\s*:\\s*1\\s*,\\s*\"operation\"\\s*:\\s*\"authenticate\"|\"operation\"\\s*:\\s*\"authenticate\"\\s*,\\s*\"version\"\\s*:\\s*1)\\s*\\}\\s*\\z";
  if (!data.length || data.length > 128 || !Match(text, pattern)) return ErrorResponse(@"auth observation accepts only version-1 authenticate");
  NSString *error = nil;
  if (!AuthorizeClientAt(peer, prefix, owner, &error)) return ErrorResponse(error);
  return @{ @"version":@1, @"ok":@YES, @"authenticated":@YES };
}
static void AuthPeer(int peer) {
  NSMutableData *request = [NSMutableData data];
  uint64_t deadline = KuroMonotonicMilliseconds() + 2000;
  BOOL complete = NO;
  while (request.length <= 128 && !stopping) {
    uint64_t now = KuroMonotonicMilliseconds(); if (now >= deadline) break;
    struct pollfd ready = {.fd=peer,.events=POLLIN};
    if (poll(&ready, 1, (int)(deadline-now)) <= 0) break;
    char bytes[129]; ssize_t count=recv(peer,bytes,sizeof(bytes),MSG_DONTWAIT);
    if (count < 0 && (errno==EINTR || errno==EAGAIN)) continue;
    if (count <= 0) break;
    [request appendBytes:bytes length:(NSUInteger)count];
    char *newline=memchr(bytes,'\n',(size_t)count);
    if (newline) { complete=newline==bytes+count-1; break; }
  }
  NSDictionary *response=complete ? AuthenticateRequestAt(request,peer,@"",0) : ErrorResponse(@"one bounded newline auth request required");
  NSMutableData *line=[JSONData(response) mutableCopy]; [line appendBytes:"\n" length:1];
  (void)send(peer,line.bytes,line.length,MSG_DONTWAIT|MSG_NOSIGNAL);
}
static void AuthStopSignal(int value) { (void)value; stopping=1; }
static int ServeAuthLocked(void) {
  NSString *error=nil;
  NSString *path=[SocketDirectory stringByAppendingPathComponent:@"auth.sock"];
  struct sockaddr_un address;
  if(!KuroUnixSocketAddress(path,&address,&error))return 1;
  NSDictionary *record=nil;
  if (!ProveNeverStarted(@"",0,&record,&error)) return 1;
  NSString *directory=[Tools stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:record[@"release"]]];
  NSString *selfPath=[directory stringByAppendingPathComponent:@"helper"];
  NSDictionary *manifest=ReadJSON(@"",[directory stringByAppendingPathComponent:@"manifest.json"],0,&error);
  NSData *bytes=ReadProtected(@"",selfPath,0,&error);
  if (![Executable() isEqual:selfPath] || !ValidManifest(manifest,&error) || !manifest[@"client"] || !bytes ||
      ![Hash(bytes) isEqual:record[@"helperSHA256"]] || ![Hash(bytes) isEqual:manifest[@"helper"][@"sha256"]]) return 1;
  int lock=ServiceLock(@"",0,&error); if(lock<0)return 1;
  NSString *observer=[State stringByAppendingPathComponent:@"auth-observer.json"];
  // An unexpected stale endpoint is evidence, not permission to unlink it.
  if(Exists(path) || Exists(observer)) { close(lock); return 1; }
  int listener=socket(AF_UNIX,SOCK_STREAM,0);
  struct stat owned={0}; BOOL bound=NO; int result=1; NSData *receipt=nil;
  if(listener<0) { close(lock); return 1; }
  if(bind(listener,(struct sockaddr *)&address,sizeof(address)))goto finish;
  if(lstat(path.fileSystemRepresentation,&owned))goto finish;
  bound=YES;
  receipt=JSONData(@{@"format":@1,@"socketDevice":@((uint64_t)owned.st_dev),@"socketInode":@((uint64_t)owned.st_ino),@"helperSHA256":Hash(bytes)});
  if(!WriteNew(observer,receipt,0600,&error))goto finish;
  // Emergency exit is safe only after exact endpoint recovery evidence exists.
  struct sigaction watchdog={.sa_handler=SIG_DFL}; sigemptyset(&watchdog.sa_mask);
  sigset_t unblocked; sigemptyset(&unblocked); sigaddset(&unblocked,SIGALRM);
  if(sigaction(SIGALRM,&watchdog,NULL) || sigprocmask(SIG_UNBLOCK,&unblocked,NULL))goto finish;
  alarm(310);
  if(chmod(path.fileSystemRepresentation,0666) || listen(listener,8))goto finish;
  stopping=0; signal(SIGTERM,AuthStopSignal); signal(SIGINT,AuthStopSignal); signal(SIGPIPE,SIG_IGN);
  // No daemon registration, production service, Core or network object exists here.
  uint64_t deadline=KuroMonotonicMilliseconds()+300000;
  while(!stopping && KuroMonotonicMilliseconds()<deadline) {
    struct pollfd ready={.fd=listener,.events=POLLIN}; if(poll(&ready,1,250)<=0)continue;
    int peer=accept(listener,NULL,NULL); if(peer<0)continue;
    @autoreleasepool { AuthPeer(peer); } close(peer);
  }
  result=0;
finish:
  close(listener);
  struct stat current;
  if(bound && (lstat(path.fileSystemRepresentation,&current) || current.st_ino!=owned.st_ino || current.st_dev!=owned.st_dev || unlink(path.fileSystemRepresentation))) result=1;
  if(receipt && Exists(observer)) {
    if(![ReadProtected(@"",observer,0,&error) isEqual:receipt] || Exists(path) || unlink(observer.fileSystemRepresentation))result=1;
  }
  alarm(0);
  close(lock); return result;
}
static int ServeAuth(void) {
  NSString *error=nil;
  NSString *parent=@"/Library/PrivilegedHelperTools";
  if(!SafeChain(@"",parent,0,YES,&error))return 1;
  int guard=open(parent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(guard<0)return 1;
  if(flock(guard,LOCK_SH|LOCK_NB)) { close(guard); return 1; }
  int result=ServeAuthLocked(); close(guard); return result;
}
