#import "tun-core-control.m"
// Included after the fixed installer helpers. Internal APIs only; this class
// never takes a caller-supplied executable, HTTP method/path, or working directory.
typedef BOOL (^KuroServiceAuthorize)(int peer, NSString *configDigest, NSString **error);
typedef BOOL (^KuroServicePreflight)(NSDictionary *config, NSString **error);
typedef BOOL (^KuroServiceProcessHook)(pid_t child, NSString *session, NSString **error);
typedef BOOL (^KuroServiceRecovery)(NSString *session, NSString **error);
typedef BOOL (^KuroServiceStopped)(NSDictionary *sessionEvidence, NSString **error);
@interface KuroTunServiceHooks : NSObject
@property(nonatomic, copy) KuroServiceAuthorize authorize;
@property(nonatomic, copy) KuroServicePreflight preflight;
@property(nonatomic, copy) KuroSessionHook beforeStart;
@property(nonatomic, copy) KuroSessionHook beforeResume;
@property(nonatomic, copy) KuroServiceStopped confirmStopped;
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
  BOOL _shutdownRequested;
  NSString *_retainedSession;
  KuroControlCall *_recoveryCall;
  NSCondition *_recoveryWake;
  BOOL _workCreated;
  BOOL _resumeCheckpointAttempted, _stopCheckpointAttempted, _stopCheckpointComplete;
  NSString *_stopCheckpointFailure;
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
@property(nonatomic, copy) void (^fixtureRetained)(void);
@property(nonatomic, copy) void (^fixtureBeforeRecovery)(void);
@property(nonatomic, copy) void (^fixtureRecoveryCompleted)(void);
#endif
// Must run on the dedicated owner worker. Other workers may call the methods below.
- (BOOL)serveOpenFrame:(NSData *)frame peer:(int)peer error:(NSString **)error;
- (NSDictionary *)statusSnapshot;
- (void)requestStop;
- (void)requestShutdown;
- (BOOL)recoverHeldSession:(NSString *)session deadline:(uint64_t)deadline error:(NSString **)error;
- (BOOL)recoverNetworkOnly:(NSString **)error;
// Typed internal control only; a protocol adapter must independently authorize its caller.
- (BOOL)writeMode:(NSString *)mode error:(NSString **)error;
- (BOOL)selectProxy:(NSString *)proxy group:(NSString *)group error:(NSString **)error;
@end
@implementation KuroTunService
- (instancetype)initWithHooks:(KuroTunServiceHooks *)hooks {
  if((self=[super init])) {
    _directory=State; _owner=0; _hooks=hooks; _commands=[NSMutableArray array]; _recoveryWake=[NSCondition new];
    _snapshot=[Status(@"",0)[@"status"] copy];
  }
  return self;
}
#ifdef KURO_TESTING
- (instancetype)initFixtureDirectory:(NSString *)directory core:(NSString *)core hooks:(KuroTunServiceHooks *)hooks {
  if((self=[super init])) {
    _directory=[directory copy]; _owner=geteuid(); _fixtureCore=[core copy]; _hooks=hooks; _commands=[NSMutableArray array]; _recoveryWake=[NSCondition new];
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
- (void)requestShutdown {
  @synchronized(self) { _stopRequested=YES; _shutdownRequested=YES; }
  [_recoveryWake lock]; [_recoveryWake broadcast]; [_recoveryWake unlock];
}
- (BOOL)recoverHeldSession:(NSString *)session deadline:(uint64_t)deadline error:(NSString **)error {
  KuroControlCall *call=[KuroControlCall new];call.condition=[NSCondition new];call.deadline=deadline;
  call.command=@{@"session":session?:@""};
  @synchronized(self) {
    if(!_retainedSession || ![_retainedSession isEqual:session] || _recoveryCall || _shutdownRequested || KuroMonotonicMilliseconds()>=deadline)
      return Fail(error,@"no matching retained owner or recovery already pending/shutting down");
    _recoveryCall=call;
  }
  [_recoveryWake lock];[_recoveryWake broadcast];[_recoveryWake unlock];
  [call.condition lock];
  while(!call.done && KuroMonotonicMilliseconds()<deadline)[call.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
  if(!call.done)call.cancelled=YES;
  BOOL ok=call.done && [call.result isEqual:@YES] && !call.failure;NSString *failure=call.failure;
  [call.condition unlock];
  return ok || Fail(error,failure?:@"held recovery deadline expired; an already executing cleanup may still finish");
}
- (void)retainCleanupOnPeer:(int)peer {
  if(![_session heldCleanupCanRetry])return;
  @synchronized(self) { _retainedSession=_session.identifier; }
  // The old V2 caller must see disconnection while this exact owner worker stays alive.
  shutdown(peer,SHUT_RDWR);
#ifdef KURO_TESTING
  if(self.fixtureRetained)self.fixtureRetained();
#endif
  for(;;) @autoreleasepool {
    [_recoveryWake lock];
    KuroControlCall *call=nil;BOOL quitting=NO;
    @synchronized(self) { quitting=_shutdownRequested;call=_recoveryCall; }
    if(!quitting && !call) { [_recoveryWake waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];[_recoveryWake unlock];continue; }
    [_recoveryWake unlock];
    if(quitting)break;
#ifdef KURO_TESTING
    if(self.fixtureBeforeRecovery)self.fixtureBeforeRecovery();
#endif
    [call.condition lock];
    BOOL admitted=!call.cancelled && KuroMonotonicMilliseconds()<call.deadline;
    [call.condition unlock];
    @synchronized(self) { admitted=admitted && !_shutdownRequested && [call.command[@"session"]isEqual:_retainedSession]; }
    NSString *failure=nil;BOOL ok=NO;
    if(admitted && [_session heldCleanupCanRetry]) {
      ok=[_session stop:&failure] && _session.off && !_workCreated;
      if(ok)ok=[self checkpointStopped:&failure];
      else [self snapshot:@"unknown" error:failure?:@"held cleanup retry not proven"];
    } else failure=@"held recovery expired, cancelled, or ownership no longer admits retry";
    [call.condition lock];call.result=@(ok);call.failure=failure;call.done=YES;[call.condition broadcast];[call.condition unlock];
    @synchronized(self) { if(_recoveryCall==call)_recoveryCall=nil; }
#ifdef KURO_TESTING
    if(self.fixtureRecoveryCompleted)self.fixtureRecoveryCompleted();
#endif
    // A failed checkpoint after physical cleanup cannot authorize repeating network cleanup.
    if(_session.off && !_workCreated)break;
  }
  KuroControlCall *pending=nil;
  @synchronized(self) { _retainedSession=nil;pending=_recoveryCall;_recoveryCall=nil; }
  if(pending) { [pending.condition lock];pending.failure=@"helper shutting down with ownership evidence preserved";pending.done=YES;[pending.condition broadcast];[pending.condition unlock]; }
}
- (BOOL)recoverNetworkOnly:(NSString **)error {
  NSString *held=nil;
  @synchronized(self) {
    held=_retainedSession;
    if(!held) { if(_busy || _shutdownRequested)return Fail(error,@"session transaction active or shutting down; recovery refused");_busy=YES; }
  }
  if(held)return [self recoverHeldSession:held deadline:KuroMonotonicMilliseconds()+2000 error:error];
  BOOL ok=NO;
  @try {
    if((_session && _session.child>0) || (_session && Exists([_directory stringByAppendingPathComponent:@"owner.json"])))return Fail(error,@"in-memory Core owner requires its original stop/reconcile; no PID adoption");
    if(!SafeChain([self anchor],_directory,_owner,YES,error) || !_hooks.recoverResidualNetwork)return NO;
    KuroOwnedSession *observed=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    if(![observed recoverExitedOwnerWithNetwork:_hooks.recoverResidualNetwork workCleanup:^BOOL(NSDictionary *record,KuroSessionHook stillAbsent,NSString **failure) {
      return [self recoverExitedWork:record stillAbsent:stillAbsent error:failure];
    } error:error])return NO;
    ok=observed.off && (!_session || _session.off) && !Exists([self work]);
    return ok || Fail(error,@"network/Core recovery did not independently clear ownership receipts");
  } @finally {
    [self snapshot:ok?@"off":@"unknown" error:ok?_stopCheckpointFailure:@"residual ownership recovery is not proven"];
    @synchronized(self) { _busy=NO; }
  }
}
- (BOOL)recoverExitedWork:(NSDictionary *)record stillAbsent:(KuroSessionHook)stillAbsent error:(NSString **)error {
  NSString *work=[self work]; if(!Exists(work))return YES;
  if(![record[@"format"]isEqual:@2] || !SafeChain([self anchor],work,_owner,YES,error))return Fail(error,@"old work has no protected versioned runtime receipt");
  NSArray *names=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:work error:NULL];
  if(!names)return Fail(error,@"old Core work cannot be enumerated");
  for(NSString *name in names)if(![@[@"config.json",@"core.sock",@"cache.db"]containsObject:name])return Fail(error,@"unknown old Core work is preserved");
  NSString *config=[work stringByAppendingPathComponent:@"config.json"],*socket=[work stringByAppendingPathComponent:@"core.sock"];
  NSDictionary *receipt=record[@"work"];
  NSString *cache=[work stringByAppendingPathComponent:@"cache.db"];
  NSDictionary *cacheIdentity=nil;
  if(Exists(cache)) {
    cacheIdentity=KuroWorkCacheSnapshot(_directory,_owner,error);
    if(!cacheIdentity || ![cacheIdentity isEqual:receipt[@"cache"]])return Fail(error,@"old cache lacks an exact durable receipt; preserving all work");
  }
  // Validate all present objects before removing any work file.
  if(Exists(config)) {
    NSData *bytes=ReadProtected([self anchor],config,_owner,error);
    if(!bytes || ![Hash(bytes)isEqual:receipt[@"configSHA256"]])return Fail(error,@"old runtime config changed; preserving work");
  }
  struct stat before={0};
  if(Exists(socket)) {
    id expected=receipt[@"socket"];
    if(!Keys(expected,@[@"device",@"inode"]) || lstat(socket.fileSystemRepresentation,&before) || !S_ISSOCK(before.st_mode) || before.st_uid!=_owner || before.st_nlink!=1 ||
      (unsigned long long)before.st_dev!=[expected[@"device"]unsignedLongLongValue] || before.st_ino!=[expected[@"inode"]unsignedLongLongValue])return Fail(error,@"old private socket lacks an exact owner receipt; preserving work");
  }
  if(Exists(config)) {
    if(!stillAbsent(error))return NO;
    NSData *bytes=ReadProtected([self anchor],config,_owner,error);
    if(!bytes || ![Hash(bytes)isEqual:receipt[@"configSHA256"]] || unlink(config.fileSystemRepresentation))return Fail(error,@"old config absence cleanup could not be confirmed");
  }
  if(Exists(socket)) {
    struct stat current={0}; if(!stillAbsent(error) || lstat(socket.fileSystemRepresentation,&current) || !S_ISSOCK(current.st_mode) || current.st_uid!=_owner || current.st_nlink!=1 || current.st_dev!=before.st_dev || current.st_ino!=before.st_ino || unlink(socket.fileSystemRepresentation))return Fail(error,@"old socket changed before exact removal");
  }
  if(Exists(cache)) {
    if(!stillAbsent(error) || ![KuroWorkCacheSnapshot(_directory,_owner,error)isEqual:cacheIdentity] || unlink(cache.fileSystemRepresentation))return Fail(error,@"old cache changed before exact removal");
  }
  if(!stillAbsent(error) || rmdir(work.fileSystemRepresentation))return Fail(error,@"old Core work remains; preserving owner receipt");
  int directory=open(_directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); BOOL durable=directory>=0 && !fsync(directory); if(directory>=0)close(directory);
  return durable || Fail(error,@"old work removal directory sync failed");
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
  if(!ValidManifest(manifest,error) || !KuroMapping(manifest,@[@"format",@"label",@"release",@"target",@"protocol",@"activationAllowed",@"core",@"helper"],@[@"client",@"clientInventorySHA256"]) || !KuroNumber(manifest[@"format"],1,1) || ![manifest[@"label"] isEqual:Label] || ![manifest[@"release"] isEqual:installed[@"release"]] || !KuroNumber(manifest[@"protocol"],1,1) || !KuroBool(manifest[@"activationAllowed"]) || ![manifest[@"activationAllowed"] boolValue] ||
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
  if(!_socketIdentity && (![_session recordWorkSocket:identity error:error]))return NO;
  _socketIdentity=identity; return YES;
}
- (id)coreRequest:(NSDictionary *)command error:(NSString **)error {
  return KuroCoreControlRequest([self socket],_secret,_admitted[@"groups"],^BOOL(NSString **failure) {
    return [self socketProtected:failure];
  },command,error);
}
- (BOOL)removeWork:(NSString **)error {
  if(!_workCreated)return YES;
  if(!SafeChain([self anchor],[self work],_owner,YES,error))return NO;
  NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self work] error:NULL];
  for(NSString *name in names) if(![@[@"config.json",@"core.sock",@"cache.db"] containsObject:name])return Fail(error,@"unknown Core work files preserved");
  if(!names)return Fail(error,@"Core work directory cannot be observed");
  NSString *cache=[[self work]stringByAppendingPathComponent:@"cache.db"];
  NSDictionary *cacheIdentity=nil;
  if(Exists(cache)) {
    cacheIdentity=KuroWorkCacheSnapshot(_directory,_owner,error);
    if(!cacheIdentity || ![_session recordReapedWorkCache:cacheIdentity error:error])return NO;
  }
  NSString *config=[[self work] stringByAppendingPathComponent:@"config.json"];
  if(Exists(config)) {
    NSData *bytes=ReadProtected([self anchor],config,_owner,error);
    if(!bytes || ![Hash(bytes) isEqual:_runtimeDigest])return Fail(error,@"private config changed; preserving owner journal");
    if(unlink(config.fileSystemRepresentation))return Fail(error,@"private config removal failed");
  }
  if(Exists([self socket])) {
    if(![self socketProtected:error] || unlink([self socket].fileSystemRepresentation))return Fail(error,@"private Core socket cleanup not proven");
  }
  if(Exists(cache) && (![KuroWorkCacheSnapshot(_directory,_owner,error)isEqual:cacheIdentity] || unlink(cache.fileSystemRepresentation)))return Fail(error,@"private Core cache changed before exact removal");
  if(rmdir([self work].fileSystemRepresentation))return Fail(error,@"private work directory removal failed");
  _workCreated=NO; return YES;
}
- (BOOL)checkpointStopped:(NSString **)error {
  if(!_session || !_session.off || _workCreated)return Fail(error,@"session cleanup is not complete");
  // Physical off remains true even when its uninstall checkpoint cannot be saved.
  [self snapshot:@"off" error:nil];
  if(!_resumeCheckpointAttempted)return YES;
  if(_stopCheckpointAttempted) {
    if(!_stopCheckpointComplete)[self snapshot:@"off" error:_stopCheckpointFailure];
    return _stopCheckpointComplete || Fail(error,_stopCheckpointFailure);
  }
  _stopCheckpointAttempted=YES;
  NSString *failure=nil;NSDictionary *evidence=[_session completedStopEvidence:&failure];
  _stopCheckpointComplete=evidence && _hooks.confirmStopped && _hooks.confirmStopped(evidence,&failure);
  if(!_stopCheckpointComplete) {
    _stopCheckpointFailure=[@"cleanup confirmed, uninstall checkpoint failed: "stringByAppendingString:failure?:@"same-session confirmation hook unavailable"];
    [self snapshot:@"off" error:_stopCheckpointFailure];return Fail(error,_stopCheckpointFailure);
  }
  return YES;
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
    if(_busy || _shutdownRequested) { KuroServiceReply(peer,KuroServiceError(@"a session owner is already active or shutting down")); return Fail(error,@"single owner busy"); }
    previouslyOff=[_snapshot[@"state"] isEqual:@"off"];
    _busy=YES; _stopRequested=NO; _nextNetworkCheck=0;
    _resumeCheckpointAttempted=NO; _stopCheckpointAttempted=NO; _stopCheckpointComplete=NO; _stopCheckpointFailure=nil;
    _snapshot=@{@"availability":@"blocked",@"state":@"unknown",@"error":@"session startup transaction is active"};
  }
  BOOL success=NO,acknowledged=NO; NSString *failure=nil; NSString *stage=@"open decode";
  @try {
    id open=KuroDecodeJSON(frame,66000,&failure);
    if(!Keys(open,@[@"version",@"operation",@"config"]) || !KuroNumber(open[@"version"],2,2) || ![open[@"operation"] isEqual:@"open"] || ![open[@"config"] isKindOfClass:NSDictionary.class]) { failure=@"invalid closed version-2 open frame"; return NO; }
    NSData *canonical=[NSJSONSerialization dataWithJSONObject:open[@"config"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    stage=@"closed config validation"; _admitted=KuroValidateTunConfig(canonical,&failure); if(!_admitted)return NO; _configDigest=Hash(canonical);
    if(!_hooks.authorize||!_hooks.preflight||!_hooks.beforeStart||!_hooks.beforeResume||!_hooks.confirmStopped||!_hooks.ready||!_hooks.applyNetwork||!_hooks.recoverNetwork||!_hooks.identityValid) { failure=@"complete authorization, process and network hooks are required"; return NO; }
    if(!_hooks.authorize(peer,_configDigest,&failure) || !_hooks.identityValid(peer) || !_hooks.preflight(_admitted,&failure)) { failure=failure ?: @"caller or process/network prerequisites are not proven"; return NO; }
    if(![self startupAllowed:&failure])return NO;
    stage=@"fixed Core approval"; NSString *core=[self approvedCore:&failure]; if(!core)return NO;
    if(!SafeChain([self anchor],_directory,_owner,YES,&failure) || Exists([self work])) { failure=@"protected clean session directory is required"; return NO; }
    stage=@"clean ownership"; _session=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    if(!_session.off) { failure=@"persisted ownership cannot be proven off"; return NO; }
    stage=@"prior stopped proof revocation";if(!_hooks.beforeStart(&failure))return NO;
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
        strong->_resumeCheckpointAttempted=YES;
        if(!strong->_hooks.beforeResume(problem))return NO;
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
    success=[_session superviseSocket:peer leaseMilliseconds:15000 identityValid:^BOOL { KuroTunService *strong=weakSelf; return strong && strong->_hooks.identityValid(peer); } tick:^BOOL(NSString **problem) { return [weakSelf tick:problem]; } stopCheckpoint:^BOOL(NSString **problem) { return [weakSelf checkpointStopped:problem]; } error:&failure];
#ifdef KURO_TESTING
    if(self.fixtureAfterSupervise)self.fixtureAfterSupervise();
#endif
    return success;
  } @finally {
    if(_session && !_session.off) { NSString *cleanup=nil; if(![_session stop:&cleanup])failure=cleanup ?: failure; }
    if(_workCreated && (!_session || _session.off)) { NSString *cleanup=nil; if(![self removeWork:&cleanup])failure=cleanup ?: failure; }
    BOOL off=(_session ? _session.off : previouslyOff) && !_workCreated;
    if(off) {
      NSString *checkpoint=nil;
      if(_session && ![self checkpointStopped:&checkpoint]) {success=NO;failure=checkpoint;}
      [self snapshot:@"off" error:_stopCheckpointFailure];
    }
    else if(_session||_workCreated)[self snapshot:@"unknown" error:failure ?: @"cleanup cannot be proven"];
    if(!success && !failure)failure=[@"failed stage: " stringByAppendingString:stage];
    if(!success && !acknowledged)KuroServiceReply(peer,KuroServiceError(failure));
    [self finishPending];
    if(!off)[self retainCleanupOnPeer:peer];
    @synchronized(self) { _busy=NO; }
    if(error)*error=failure;
  }
}
@end
