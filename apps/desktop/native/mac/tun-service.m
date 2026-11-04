// Included after the fixed installer helpers. Internal APIs only; this class
// never takes a caller-supplied executable, HTTP method/path, or working directory.
typedef BOOL (^KuroServiceAuthorize)(int peer, NSString *configDigest, NSString **error);
typedef BOOL (^KuroServicePreflight)(NSDictionary *config, NSString **error);
typedef BOOL (^KuroServiceProcessHook)(pid_t child, NSString *session, NSString **error);
typedef BOOL (^KuroServiceRecovery)(NSString *session, NSString **error);
@interface KuroTunServiceHooks : NSObject
@property(nonatomic, copy) KuroServiceAuthorize authorize;
@property(nonatomic, copy) KuroServicePreflight preflight;
@property(nonatomic, copy) KuroServiceProcessHook ready;
@property(nonatomic, copy) KuroServiceProcessHook applyNetwork;
@property(nonatomic, copy) KuroServiceRecovery recoverNetwork;
@property(nonatomic, copy) BOOL (^identityValid)(int peer);
@property(nonatomic, copy) NSString *(^physicalInterface)(void);
@property(nonatomic, copy) NSDictionary *(^readinessHosts)(void);
@property(nonatomic, copy) KuroServiceRecovery verifyNetwork;
@property(nonatomic, copy) KuroSessionHook recoverResidualNetwork;
@end
@implementation KuroTunServiceHooks @end

static NSDictionary *KuroServiceError(NSString *message) { return @{@"version":@2,@"ok":@NO,@"error":message ?: @"session refused"}; }
static BOOL KuroServiceReply(int peer, NSDictionary *value) {
  NSMutableData *bytes=[JSONData(value) mutableCopy]; [bytes appendBytes:"\n" length:1];
  return send(peer,bytes.bytes,bytes.length,MSG_NOSIGNAL|MSG_DONTWAIT)==(ssize_t)bytes.length;
}
static NSString *KuroPathComponent(NSString *name) {
  NSData *bytes=[name dataUsingEncoding:NSUTF8StringEncoding]; NSMutableString *encoded=[NSMutableString string];
  const unsigned char *input=bytes.bytes;
  for(NSUInteger i=0;i<bytes.length;i++) {
    unsigned char c=input[i];
    if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~') [encoded appendFormat:@"%c",c];
    else [encoded appendFormat:@"%%%02X",c];
  }
  return encoded;
}
@interface KuroControlCall : NSObject
@property(nonatomic) NSCondition *condition;
@property(nonatomic) NSDictionary *command;
@property(nonatomic) id result;
@property(nonatomic) NSString *failure;
@property(nonatomic) BOOL done;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) uint64_t deadline;
@end
@implementation KuroControlCall @end

@interface KuroTunService : NSObject {
  NSString *_directory;
  uid_t _owner;
  KuroTunServiceHooks *_hooks;
  KuroOwnedSession *_session;
  NSDictionary *_snapshot;
  NSDictionary *_admitted;
  NSMutableArray<KuroControlCall *> *_commands;
  BOOL _busy;
  BOOL _stopRequested;
  BOOL _workCreated;
  NSString *_configDigest;
  NSString *_runtimeDigest;
  NSString *_secret;
  uint64_t _nextNetworkCheck;
  NSDictionary *_socketIdentity;
#ifdef KURO_TESTING
  NSString *_fixtureCore;
#endif
}
- (instancetype)initWithHooks:(KuroTunServiceHooks *)hooks;
#ifdef KURO_TESTING
- (instancetype)initFixtureDirectory:(NSString *)directory core:(NSString *)core hooks:(KuroTunServiceHooks *)hooks;
@property(nonatomic, copy) void (^fixtureAfterSupervise)(void);
@property(nonatomic, copy) void (^fixtureBeforeResume)(void);
#endif
// Must run on the dedicated owner worker. Other workers may call the methods below.
- (BOOL)serveOpenFrame:(NSData *)frame peer:(int)peer error:(NSString **)error;
- (NSDictionary *)statusSnapshot;
- (void)requestStop;
- (BOOL)recoverNetworkOnly:(NSString **)error;
// Typed internal control only; a protocol adapter must independently authorize its caller.
- (BOOL)writeMode:(NSString *)mode error:(NSString **)error;
- (BOOL)selectProxy:(NSString *)proxy group:(NSString *)group error:(NSString **)error;
@end
@implementation KuroTunService
- (instancetype)initWithHooks:(KuroTunServiceHooks *)hooks {
  if((self=[super init])) {
    _directory=State; _owner=0; _hooks=hooks; _commands=[NSMutableArray array];
    _snapshot=[Status(@"",0)[@"status"] copy];
  }
  return self;
}
#ifdef KURO_TESTING
- (instancetype)initFixtureDirectory:(NSString *)directory core:(NSString *)core hooks:(KuroTunServiceHooks *)hooks {
  if((self=[super init])) {
    _directory=[directory copy]; _owner=geteuid(); _fixtureCore=[core copy]; _hooks=hooks; _commands=[NSMutableArray array];
    _snapshot=@{@"availability":@"blocked",@"state":@"unknown",@"error":@"fixture has not established off evidence"};
  }
  return self;
}
#endif
- (NSString *)work { return [_directory stringByAppendingPathComponent:@"session-work"]; }
- (NSString *)socket { return [[self work] stringByAppendingPathComponent:@"core.sock"]; }
- (NSString *)anchor {
#ifdef KURO_TESTING
  if(_fixtureCore)return _directory;
#endif
  return @"";
}
- (NSDictionary *)statusSnapshot { @synchronized(self) { return [_snapshot copy]; } }
- (void)snapshot:(NSString *)state error:(NSString *)error {
  @synchronized(self) { _snapshot=error ? @{@"availability":@"blocked",@"state":state,@"error":error} : @{@"availability":@"ready",@"state":state}; }
}
- (void)requestStop { @synchronized(self) { _stopRequested=YES; } }
- (BOOL)recoverNetworkOnly:(NSString **)error {
  @synchronized(self) { if(_busy)return Fail(error,@"session transaction active; recovery refused"); _busy=YES; }
  BOOL ok=NO;
  @try {
    if((_session && _session.child>0) || Exists([_directory stringByAppendingPathComponent:@"owner.json"]) || Exists([self work]))return Fail(error,@"Core ownership/work residual needs separate recovery; no PID adoption");
    if(!SafeChain([self anchor],_directory,_owner,YES,error))return NO;
    // Network receipts are the recovery input, not proof of a live Core.
    if(!_hooks.recoverResidualNetwork || !_hooks.recoverResidualNetwork(error))return NO;
    KuroOwnedSession *observed=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    ok=observed.off && (!_session || _session.off) && !Exists([self work]);
    return ok || Fail(error,@"network recovery did not independently clear ownership receipts");
  } @finally {
    [self snapshot:ok?@"off":@"unknown" error:ok?nil:@"residual ownership recovery is not proven"];
    @synchronized(self) { _busy=NO; }
  }
}
- (BOOL)startupAllowed:(NSString **)error { @synchronized(self) { return !_stopRequested || Fail(error,@"stop requested during startup"); } }
- (NSString *)approvedCore:(NSString **)error {
#ifdef KURO_TESTING
  if(_fixtureCore) {
    if(!ReadProtected(_directory,_fixtureCore,_owner,error))return nil;
    return _fixtureCore;
  }
#endif
  if(geteuid()!=0 || ![_directory isEqual:State]) { Fail(error,@"root fixed service installation required"); return nil; }
  NSDictionary *installed=ReadJSON(@"",[State stringByAppendingPathComponent:@"installed.json"],0,error);
  if(!Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroNumber(installed[@"format"],1,1) || !KuroBool(installed[@"neverStarted"]) || !Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z")) { Fail(error,@"installed ownership record is not approved"); return nil; }
  NSString *version=[Tools stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:installed[@"release"]]];
  NSDictionary *manifest=ReadJSON(@"",[version stringByAppendingPathComponent:@"manifest.json"],0,error);
  if(!ValidManifest(manifest,error) || !KuroMapping(manifest,@[@"format",@"label",@"release",@"target",@"protocol",@"activationAllowed",@"core",@"helper"],@[@"client"]) || !KuroNumber(manifest[@"format"],1,1) || ![manifest[@"label"] isEqual:Label] || ![manifest[@"release"] isEqual:installed[@"release"]] || !KuroNumber(manifest[@"protocol"],1,1) || !KuroBool(manifest[@"activationAllowed"]) || ![manifest[@"activationAllowed"] boolValue] ||
     !Keys(manifest[@"core"],@[@"file",@"version",@"sha256",@"archiveSha256"]) || !Keys(manifest[@"helper"],@[@"file",@"version",@"sha256"]) || ![manifest[@"core"][@"file"] isEqual:@"mihomo"] || ![manifest[@"helper"][@"file"] isEqual:@"helper"]) { Fail(error,@"installed payload does not explicitly permit activation"); return nil; }
#if defined(__arm64__)
  NSString *target=@"darwin-arm64";
#else
  NSString *target=@"darwin-x64";
#endif
  NSString *core=[version stringByAppendingPathComponent:@"mihomo"],*helper=[version stringByAppendingPathComponent:@"helper"];
  NSData *coreBytes=ReadProtected(@"",core,0,error),*helperBytes=ReadProtected(@"",helper,0,error);
  if(![manifest[@"target"] isEqual:target] || !coreBytes || !helperBytes || !MachExecutable(coreBytes) || ![Hash(coreBytes) isEqual:manifest[@"core"][@"sha256"]] || ![Hash(helperBytes) isEqual:manifest[@"helper"][@"sha256"]] || ![installed[@"helperSHA256"] isEqual:manifest[@"helper"][@"sha256"]] || ![helper isEqual:Executable()]) { Fail(error,@"fixed Core/helper executable pin mismatch"); return nil; }
  return core;
}
- (BOOL)socketProtected:(NSString **)error {
  if(!SafeChain([self anchor],[self work],_owner,YES,error))return NO;
  struct stat value; NSString *path=[self socket];
  if(lstat(path.fileSystemRepresentation,&value) || !S_ISSOCK(value.st_mode) || value.st_uid!=_owner || value.st_nlink!=1) return Fail(error,@"private Core socket is not an owned Unix socket");
  NSDictionary *identity=@{@"device":@(value.st_dev),@"inode":@(value.st_ino)};
  if(_socketIdentity && ![_socketIdentity isEqual:identity])return Fail(error,@"private Core socket identity changed");
  _socketIdentity=identity; return YES;
}
- (BOOL)waitFD:(int)fd events:(short)events until:(uint64_t)deadline error:(NSString **)error {
  while(KuroMonotonicMilliseconds()<deadline) {
    struct pollfd value={.fd=fd,.events=events};
    uint64_t now=KuroMonotonicMilliseconds(); int remaining=now<deadline ? (int)(deadline-now) : 0;
    int count=poll(&value,1,MAX(remaining,0));
    if(count<0&&errno==EINTR)continue;
    if(count>0 && (value.revents&events))return YES;
    break;
  }
  return Fail(error,@"private Core request timed out or disconnected");
}
// Only callers below construct these three fixed request variants.
- (id)coreRequest:(NSDictionary *)command error:(NSString **)error {
  NSString *method=nil,*path=nil; NSDictionary *body=nil;
  if(Keys(command,@[@"operation"]) && [command[@"operation"] isEqual:@"version"]) { method=@"GET"; path=@"/version"; }
  else if(Keys(command,@[@"operation",@"mode"]) && [command[@"operation"] isEqual:@"mode"] && [@[@"rule",@"global",@"direct"] containsObject:command[@"mode"]]) { method=@"PATCH"; path=@"/configs"; body=@{@"mode":command[@"mode"]}; }
  else if(Keys(command,@[@"operation",@"group",@"proxy"]) && [command[@"operation"] isEqual:@"select"] && KuroText(command[@"group"],128) && KuroText(command[@"proxy"],128)) {
    BOOL allowed=NO;
    for(NSDictionary *group in _admitted[@"groups"]) if([group[@"name"] isEqual:command[@"group"]] && [group[@"proxies"] containsObject:command[@"proxy"]])allowed=YES;
    if(!allowed) { Fail(error,@"selection was not admitted by the session schema"); return nil; }
    method=@"PUT"; path=[@"/proxies/" stringByAppendingString:KuroPathComponent(command[@"group"])]; body=@{@"name":command[@"proxy"]};
  } else { Fail(error,@"unsupported typed Core control operation"); return nil; }
  if(![self socketProtected:error])return nil;
  NSData *payload=body ? JSONData(body) : [NSData data];
  NSString *header=[NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer %@\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %lu\r\n\r\n",method,path,_secret,(unsigned long)payload.length];
  NSMutableData *request=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [request appendData:payload];
  struct sockaddr_un address={.sun_family=AF_UNIX}; NSString *socketPath=[self socket];
  if([socketPath lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>=sizeof(address.sun_path)) { Fail(error,@"fixed private socket path is too long"); return nil; }
  strlcpy(address.sun_path,socketPath.fileSystemRepresentation,sizeof(address.sun_path));
  int fd=socket(AF_UNIX,SOCK_STREAM,0);
  if(fd<0) { Fail(error,@"private Core socket unavailable"); return nil; }
  fcntl(fd,F_SETFD,FD_CLOEXEC); int flags=fcntl(fd,F_GETFL); fcntl(fd,F_SETFL,flags|O_NONBLOCK);
  uint64_t deadline=KuroMonotonicMilliseconds()+500;
  BOOL ok=connect(fd,(struct sockaddr *)&address,sizeof(address))==0;
  if(!ok&&errno==EINPROGRESS) {
    ok=[self waitFD:fd events:POLLOUT until:deadline error:error]; int failure=0; socklen_t size=sizeof(failure);
    ok=ok && !getsockopt(fd,SOL_SOCKET,SO_ERROR,&failure,&size) && !failure;
  }
  NSUInteger offset=0;
  while(ok&&offset<request.length) {
    ssize_t count=send(fd,(const char *)request.bytes+offset,request.length-offset,MSG_NOSIGNAL);
    if(count<0&&(errno==EINTR||errno==EAGAIN)) { ok=[self waitFD:fd events:POLLOUT until:deadline error:error]; continue; }
    if(count<=0) { ok=NO; break; } offset+=(NSUInteger)count;
  }
  NSMutableData *response=[NSMutableData data]; BOOL ended=NO;
  while(ok && response.length<=MessageLimit) {
    unsigned char bytes[4096]; ssize_t count=recv(fd,bytes,sizeof(bytes),0);
    if(count<0&&(errno==EINTR||errno==EAGAIN)) { ok=[self waitFD:fd events:POLLIN until:deadline error:error]; continue; }
    if(count<0) { ok=NO; break; } if(!count) { ended=YES; break; }
    [response appendBytes:bytes length:(NSUInteger)count];
  }
  close(fd);
  if(!ok || !ended || response.length>MessageLimit) { Fail(error,@"private Core response is incomplete or oversized"); return nil; }
  NSData *delimiter=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]; NSRange range=[response rangeOfData:delimiter options:0 range:NSMakeRange(0,response.length)];
  if(range.location==NSNotFound || range.location>8192) { Fail(error,@"private Core response headers invalid"); return nil; }
  NSString *headers=[[NSString alloc] initWithData:[response subdataWithRange:NSMakeRange(0,range.location)] encoding:NSASCIIStringEncoding];
  NSArray *lines=[headers componentsSeparatedByString:@"\r\n"];
  if(!lines.count || !Match(lines[0],@"\\AHTTP/1\\.[01] (?:200|204)(?: [^\\r\\n]*)?\\z")) { Fail(error,@"private Core operation was not accepted"); return nil; }
  NSMutableDictionary *fields=[NSMutableDictionary dictionary];
  for(NSUInteger i=1;i<lines.count;i++) {
    NSRange separator=[lines[i] rangeOfString:@":"];
    if(separator.location==NSNotFound) { Fail(error,@"malformed private Core header"); return nil; }
    NSString *key=[[lines[i] substringToIndex:separator.location] lowercaseString];
    if(fields[key]) { Fail(error,@"duplicate private Core header"); return nil; }
    fields[key]=[[lines[i] substringFromIndex:separator.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  NSData *content=[response subdataWithRange:NSMakeRange(NSMaxRange(range),response.length-NSMaxRange(range))];
  BOOL noContent=[lines[0] hasPrefix:@"HTTP/1.1 204"] || [lines[0] hasPrefix:@"HTTP/1.0 204"];
  BOOL lengthOK=fields[@"content-length"] ? Match(fields[@"content-length"],@"\\A(?:0|[1-9][0-9]{0,5})\\z") && (unsigned long long)[fields[@"content-length"] longLongValue]==content.length : noContent && content.length==0;
  if(fields[@"transfer-encoding"] || !lengthOK || (noContent && content.length)) { Fail(error,@"private Core response must have one bounded content length"); return nil; }
  if([command[@"operation"] isEqual:@"version"]) {
    if(noContent) { Fail(error,@"version readiness requires a JSON response"); return nil; }
    id value=KuroDecodeJSON(content,MessageLimit,error);
    if(![value isKindOfClass:NSDictionary.class] || !KuroText(value[@"version"],128)) { Fail(error,@"Core version readiness response invalid"); return nil; }
    return value;
  }
  if(!noContent) { Fail(error,@"typed Core writes require an empty 204 response"); return nil; }
  return @{};
}
- (BOOL)removeWork:(NSString **)error {
  if(!_workCreated)return YES;
  if(!SafeChain([self anchor],[self work],_owner,YES,error))return NO;
  NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self work] error:NULL];
  for(NSString *name in names) if(![@[@"config.json",@"core.sock"] containsObject:name])return Fail(error,@"unknown Core work files preserved");
  if(!names)return Fail(error,@"Core work directory cannot be observed");
  NSString *config=[[self work] stringByAppendingPathComponent:@"config.json"];
  if(Exists(config)) {
    NSData *bytes=ReadProtected([self anchor],config,_owner,error);
    if(!bytes || ![Hash(bytes) isEqual:_runtimeDigest])return Fail(error,@"private config changed; preserving owner journal");
    if(unlink(config.fileSystemRepresentation))return Fail(error,@"private config removal failed");
  }
  if(Exists([self socket])) {
    if(![self socketProtected:error] || unlink([self socket].fileSystemRepresentation))return Fail(error,@"private Core socket cleanup not proven");
  }
  if(rmdir([self work].fileSystemRepresentation))return Fail(error,@"private work directory removal failed");
  _workCreated=NO; return YES;
}
- (void)finishPending {
  NSArray *pending; @synchronized(self) { pending=[_commands copy]; [_commands removeAllObjects]; }
  for(KuroControlCall *call in pending) { [call.condition lock]; call.failure=@"session is no longer active"; call.done=YES; [call.condition broadcast]; [call.condition unlock]; }
}
- (BOOL)tick:(NSString **)error {
  KuroControlCall *call=nil;
  @synchronized(self) {
    if(_stopRequested)return Fail(error,@"external owner requested stop");
    if(_commands.count) { call=_commands[0]; [_commands removeObjectAtIndex:0]; }
  }
  uint64_t now=KuroMonotonicMilliseconds();
  if(_hooks.verifyNetwork && now>=_nextNetworkCheck) {
    _nextNetworkCheck=now+1000;
    if(!_hooks.verifyNetwork(_session.identifier,error))return NO;
  }
  if(call) {
    [call.condition lock];
    if(!call.cancelled && KuroMonotonicMilliseconds()<call.deadline) {
      NSString *failure=nil; call.result=[self coreRequest:call.command error:&failure]; call.failure=failure; call.done=YES;
    } else { call.failure=@"typed control request expired"; call.done=YES; }
    [call.condition broadcast]; [call.condition unlock];
  }
  return YES;
}
- (BOOL)enqueue:(NSDictionary *)command error:(NSString **)error {
  KuroControlCall *call=[KuroControlCall new]; call.condition=[NSCondition new]; call.command=command; call.deadline=KuroMonotonicMilliseconds()+1500;
  @synchronized(self) {
    if(!_busy || ![_snapshot[@"state"] isEqual:@"on"] || _commands.count>=16)return Fail(error,@"no active bounded control session");
    [_commands addObject:call];
  }
  [call.condition lock];
  while(!call.done && KuroMonotonicMilliseconds()<call.deadline) [call.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
  if(!call.done)call.cancelled=YES;
  BOOL ok=call.done && call.result!=nil && !call.failure; NSString *failure=call.failure;
  [call.condition unlock];
  return ok || Fail(error,failure ?: @"typed Core request expired");
}
- (BOOL)writeMode:(NSString *)mode error:(NSString **)error {
  if(![@[@"rule",@"global",@"direct"] containsObject:mode])return Fail(error,@"unsupported routing mode");
  return [self enqueue:@{@"operation":@"mode",@"mode":mode} error:error];
}
- (BOOL)selectProxy:(NSString *)proxy group:(NSString *)group error:(NSString **)error {
  if(!KuroText(proxy,128)||!KuroText(group,128))return Fail(error,@"invalid selection name");
  return [self enqueue:@{@"operation":@"select",@"proxy":proxy,@"group":group} error:error];
}
- (BOOL)serveOpenFrame:(NSData *)frame peer:(int)peer error:(NSString **)error {
  BOOL previouslyOff=NO;
  @synchronized(self) {
    if(_busy) { KuroServiceReply(peer,KuroServiceError(@"a session owner is already active")); return Fail(error,@"single owner busy"); }
    previouslyOff=[_snapshot[@"state"] isEqual:@"off"];
    _busy=YES; _stopRequested=NO; _nextNetworkCheck=0;
    _snapshot=@{@"availability":@"blocked",@"state":@"unknown",@"error":@"session startup transaction is active"};
  }
  BOOL success=NO,acknowledged=NO; NSString *failure=nil; NSString *stage=@"open decode";
  @try {
    id open=KuroDecodeJSON(frame,66000,&failure);
    if(!Keys(open,@[@"version",@"operation",@"config"]) || !KuroNumber(open[@"version"],2,2) || ![open[@"operation"] isEqual:@"open"] || ![open[@"config"] isKindOfClass:NSDictionary.class]) { failure=@"invalid closed version-2 open frame"; return NO; }
    NSData *canonical=[NSJSONSerialization dataWithJSONObject:open[@"config"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    stage=@"closed config validation"; _admitted=KuroValidateTunConfig(canonical,&failure); if(!_admitted)return NO; _configDigest=Hash(canonical);
    if(!_hooks.authorize||!_hooks.preflight||!_hooks.ready||!_hooks.applyNetwork||!_hooks.recoverNetwork||!_hooks.identityValid) { failure=@"complete authorization, process and network hooks are required"; return NO; }
    if(!_hooks.authorize(peer,_configDigest,&failure) || !_hooks.identityValid(peer) || !_hooks.preflight(_admitted,&failure)) { failure=failure ?: @"caller or process/network prerequisites are not proven"; return NO; }
    if(![self startupAllowed:&failure])return NO;
    stage=@"fixed Core approval"; NSString *core=[self approvedCore:&failure]; if(!core)return NO;
    if(!SafeChain([self anchor],_directory,_owner,YES,&failure) || Exists([self work])) { failure=@"protected clean session directory is required"; return NO; }
    stage=@"clean ownership"; _session=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    if(!_session.off) { failure=@"persisted ownership cannot be proven off"; return NO; }
    _secret=NSUUID.UUID.UUIDString; _socketIdentity=nil;
    stage=@"runtime generation"; NSData *runtime=KuroTunRuntimeJSON(canonical,&failure); if(!runtime)return NO;
    NSMutableDictionary *mapping=[KuroDecodeJSON(runtime,128*1024,&failure) mutableCopy];
    if (_hooks.readinessHosts) mapping[@"hosts"]=_hooks.readinessHosts();
    if (_hooks.physicalInterface) {
      NSString *name=_hooks.physicalInterface();
      if (!Match(name,@"\\A[a-zA-Z][a-zA-Z0-9]{0,14}\\z") || [name hasPrefix:@"utun"]) { failure=@"validated physical egress interface unavailable"; return NO; }
      mapping[@"interface-name"]=name;
    }
    mapping[@"external-controller-unix"]=[self socket]; mapping[@"secret"]=_secret;
    runtime=[NSJSONSerialization dataWithJSONObject:mapping options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    // Keep the native JSON/YAML string encoding proven by the root config module.
    NSString *text=[[NSString alloc] initWithData:runtime encoding:NSUTF8StringEncoding];
    for(NSNumber *code in @[@0x85,@0x2028,@0x2029])text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C",(unichar)code.unsignedIntValue] withString:[NSString stringWithFormat:@"\\u%04x",code.unsignedIntValue]];
    runtime=[text dataUsingEncoding:NSUTF8StringEncoding]; _runtimeDigest=Hash(runtime);
    NSData *coreBytes=ReadProtected([self anchor],core,_owner,&failure); if(!coreBytes)return NO;
    if(mkdir([self work].fileSystemRepresentation,0700)) { failure=@"private work directory creation failed"; return NO; } _workCreated=YES;
    if(!WriteNew([[self work] stringByAppendingPathComponent:@"config.json"],runtime,0600,&failure))return NO;
    if(![_session setLaunchEvidence:@{@"configSHA256":_configDigest,@"coreSHA256":Hash(coreBytes),@"template":@"macos-dual-stack-v1"} error:&failure])return NO;
    __weak KuroTunService *weakSelf=self;
    stage=@"owned Core spawn"; BOOL spawned=[_session spawnExecutable:core arguments:@[@"-d",[self work],@"-f",[[self work] stringByAppendingPathComponent:@"config.json"]] workingDirectory:[self work] beforeResume:^BOOL(NSString **problem) {
      KuroTunService *strong=weakSelf; return strong && [strong startupAllowed:problem] && strong->_hooks.identityValid(peer) && SafeChain([strong anchor],[strong work],strong->_owner,YES,problem);
    } afterReap:^BOOL(NSString **problem) {
      KuroTunService *strong=weakSelf; return strong && strong->_hooks.recoverNetwork(strong->_session.identifier,problem) && [strong removeWork:problem];
    } resumeGate:^BOOL(KuroSessionHook resume,NSString **problem) {
      KuroTunService *strong=weakSelf; if(!strong)return Fail(problem,@"service owner disappeared");
#ifdef KURO_TESTING
      if(strong.fixtureBeforeResume)strong.fixtureBeforeResume();
#endif
      // Cancellation and SIGCONT share the lock with requestStop.
      @synchronized(strong) {
        if(![strong startupAllowed:problem] || !strong->_hooks.identityValid(peer))return Fail(problem,@"stop or identity loss before Core resume");
        return resume(problem);
      }
    } error:&failure];
    if(!spawned)return NO;
    [self snapshot:@"unknown" error:@"owned Core startup and network readback pending"];
    stage=@"private Core version readiness"; uint64_t deadline=KuroMonotonicMilliseconds()+1000; id version=nil;
    do {
      if(![self startupAllowed:&failure])break;
      if(!_hooks.identityValid(peer)) { failure=@"caller exited during Core startup"; break; }
      failure=nil; version=[self coreRequest:@{@"operation":@"version"} error:&failure];
      if(version)break;
      struct timespec pause={.tv_nsec=10000000}; nanosleep(&pause,NULL);
    } while(KuroMonotonicMilliseconds()<deadline);
    if(!version) { failure=failure ?: @"private Core version readiness not proven"; return NO; }
    stage=@"process and network readback"; if(![self startupAllowed:&failure] || !_hooks.ready(_session.child,_session.identifier,&failure) || !_hooks.applyNetwork(_session.child,_session.identifier,&failure) || ![self startupAllowed:&failure])return NO;
    [self snapshot:@"on" error:nil];
    if(!KuroServiceReply(peer,@{@"version":@2,@"ok":@YES,@"session":_session.identifier,@"leaseMilliseconds":@15000,@"sequence":@0,@"status":[self statusSnapshot]})) { failure=@"open acknowledgement failed"; return NO; }
    acknowledged=YES;
    success=[_session superviseSocket:peer leaseMilliseconds:15000 identityValid:^BOOL { KuroTunService *strong=weakSelf; return strong && strong->_hooks.identityValid(peer); } tick:^BOOL(NSString **problem) { return [weakSelf tick:problem]; } stopConfirmed:^{ [weakSelf snapshot:@"off" error:nil]; } error:&failure];
#ifdef KURO_TESTING
    if(self.fixtureAfterSupervise)self.fixtureAfterSupervise();
#endif
    return success;
  } @finally {
    if(_session && !_session.off) { NSString *cleanup=nil; if(![_session stop:&cleanup])failure=cleanup ?: failure; }
    if(_workCreated && (!_session || _session.off)) { NSString *cleanup=nil; if(![self removeWork:&cleanup])failure=cleanup ?: failure; }
    BOOL off=(_session ? _session.off : previouslyOff) && !_workCreated;
    if(off)[self snapshot:@"off" error:nil];
    else if(_session||_workCreated)[self snapshot:@"unknown" error:failure ?: @"cleanup cannot be proven"];
    if(!success && !failure)failure=[@"failed stage: " stringByAppendingString:stage];
    if(!success && !acknowledged)KuroServiceReply(peer,KuroServiceError(failure));
    [self finishPending];
    @synchronized(self) { _busy=NO; }
    if(error)*error=failure;
  }
}
@end
