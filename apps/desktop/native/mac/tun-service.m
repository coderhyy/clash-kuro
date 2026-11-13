#import "tun-core-control.m"
#import "tun-output.m"
// Included after the fixed installer helpers. Internal APIs only; this class
// never takes a caller-supplied executable, HTTP method/path, or working directory.
// A read-only fixed job observation, not a general command transport. No RPC value
// supplies executable, arguments, label or the resulting owner provenance.
#ifdef KURO_TESTING
static int KuroSupervisorOutputFixture=-1;
#endif
static NSString *KuroReadSupervisorJob(NSString **error) {
  int pipeFD[2];if(pipe(pipeFD)) {Fail(error,@"supervisor observation pipe unavailable");return nil;}
  int reader=fcntl(pipeFD[0],F_DUPFD_CLOEXEC,4),writer=fcntl(pipeFD[1],F_DUPFD_CLOEXEC,4);close(pipeFD[0]);close(pipeFD[1]);
  if(reader<0 || writer<0) {if(reader>=0)close(reader);if(writer>=0)close(writer);Fail(error,@"supervisor observation descriptors unavailable");return nil;}
  int flags=fcntl(reader,F_GETFL);
  if(flags<0 || fcntl(reader,F_SETFL,flags|O_NONBLOCK)) {close(reader);close(writer);Fail(error,@"supervisor observation nonblocking pipe unavailable");return nil;}
  posix_spawn_file_actions_t actions;int setup=posix_spawn_file_actions_init(&actions);
  if(setup) {close(reader);close(writer);Fail(error,@"supervisor observation actions unavailable");return nil;}
  setup|=posix_spawn_file_actions_adddup2(&actions,writer,STDOUT_FILENO);
  setup|=posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
  setup|=posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
  setup|=posix_spawn_file_actions_addclose(&actions,reader);
  setup|=posix_spawn_file_actions_addclose(&actions,writer);
  posix_spawnattr_t attr;int initialized=posix_spawnattr_init(&attr);setup|=initialized;
  if(!initialized)setup|=posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
  char *argv[]={"/bin/launchctl","print","system/dev.kuro.tun",NULL};
  NSString *program=@"/bin/launchctl";
#ifdef KURO_TESTING
  NSString *mode=[NSString stringWithFormat:@"%d",KuroSupervisorOutputFixture];
  char *fixtureArgv[]={(char *)Executable().fileSystemRepresentation,"--supervision-output-fixture",(char *)mode.UTF8String,NULL};
  char **selected=argv;if(KuroSupervisorOutputFixture>=0){program=Executable();selected=fixtureArgv;}
#else
  char **selected=argv;
#endif
  char *environment[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t child=0;
  int spawned=setup?setup:posix_spawn(&child,program.fileSystemRepresentation,&actions,&attr,selected,environment);
  posix_spawn_file_actions_destroy(&actions);if(!initialized)posix_spawnattr_destroy(&attr);close(writer);
  if(spawned) {close(reader);Fail(error,@"fixed supervisor observation could not launch");return nil;}
  NSMutableData *bytes=[NSMutableData data];BOOL held=YES,eof=NO,valid=YES;int status=0;
  uint64_t deadline=KuroMonotonicMilliseconds()+750;
  while(held || !eof) {
    unsigned char buffer[4096];ssize_t count=read(reader,buffer,sizeof(buffer));
    if(count>0) {if(bytes.length+(NSUInteger)count>65536){valid=NO;break;}[bytes appendBytes:buffer length:(NSUInteger)count];}
    else if(!count)eof=YES;
    else if(errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR){valid=NO;break;}
    if(held) {pid_t done=waitpid(child,&status,WNOHANG);if(done==child)held=NO;else if(done<0 && errno!=EINTR){held=NO;valid=NO;break;}}
    if(!held && eof)break;
    if(KuroMonotonicMilliseconds()>=deadline){valid=NO;break;}
    struct pollfd event={.fd=reader,.events=POLLIN|POLLHUP};(void)poll(&event,1,5);
  }
  close(reader);
  if(held) {
    // This is only our still-unreaped direct launchctl child, never a saved PID.
    if(kill(child,SIGKILL) && errno!=ESRCH)valid=NO;
    uint64_t reapDeadline=KuroMonotonicMilliseconds()+250;
    while(held && KuroMonotonicMilliseconds()<reapDeadline) {
      pid_t done=waitpid(child,&status,WNOHANG);if(done==child)held=NO;else if(done<0&&errno!=EINTR){held=NO;valid=NO;}
      if(held){struct timespec pause={.tv_nsec=5000000};nanosleep(&pause,NULL);}
    }
    // A kernel-stalled child may outlive this bounded observation. Never report
    // child absence or grant cleanup authority from this failure path.
    if(held){Fail(error,@"supervisor observation timed out; direct child reap is unconfirmed");return nil;}
    valid=NO;
  }
  NSString *text=valid&&!held&&eof&&WIFEXITED(status)&&!WEXITSTATUS(status)?[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding]:nil;
  if(!text || [text rangeOfString:@"\0"].location!=NSNotFound){Fail(error,@"fixed supervisor observation failed, timed out, overflowed or was not strict UTF-8");return nil;}return text;
}
static BOOL KuroSupervisorJob(NSString *text,NSString *program,pid_t pid,NSString **error) {
  if(![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>65536 || [text rangeOfString:@"\0"].location!=NSNotFound)return Fail(error,@"invalid fixed supervisor job text");
  NSArray *lines=[text componentsSeparatedByString:@"\n"];NSInteger depth=0;BOOL opened=NO,closed=NO,arguments=NO;NSMutableArray *argv=[NSMutableArray array];NSMutableDictionary *fields=[NSMutableDictionary dictionary];
  NSSet *wanted=[NSSet setWithArray:@[@"path",@"program",@"pid",@"state",@"type",@"properties"]];BOOL sawArguments=NO;
  for(NSString *raw in lines) {
    NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!line.length)continue;
    if(!opened) {if(![line isEqual:@"system/dev.kuro.tun = {"])return Fail(error,@"supervisor job label/context mismatch");opened=YES;depth=1;continue;}
    if(closed)return Fail(error,@"trailing supervisor job data");
    if(arguments) {
      if([line isEqual:@"}"]) {arguments=NO;depth--;continue;}
      if([line containsString:@"{"]||[line containsString:@"}"]||argv.count>=2)return Fail(error,@"ambiguous supervisor arguments");
      [argv addObject:line];continue;
    }
    if([line isEqual:@"}"]) {if(--depth==0)closed=YES;else if(depth<0)return Fail(error,@"unbalanced supervisor job");continue;}
    if(depth==1 && [line isEqual:@"arguments = {"]) {if(sawArguments)return Fail(error,@"duplicate supervisor arguments");sawArguments=YES;arguments=YES;depth++;continue;}
    if([line hasSuffix:@"{"]) {depth++;if(depth>16)return Fail(error,@"supervisor nesting exceeds limit");continue;}
    if([line containsString:@"{"]||[line containsString:@"}"])return Fail(error,@"ambiguous supervisor structure");
    if(depth!=1)continue;
    NSRange separator=[line rangeOfString:@" = "];if(separator.location==NSNotFound)continue;
    NSString *key=[line substringToIndex:separator.location];if(![wanted containsObject:key])continue;
    if(fields[key])return Fail(error,@"duplicate supervisor job identity field");fields[key]=[line substringFromIndex:NSMaxRange(separator)];
  }
// This conservative known print shape is not positive proof of loaded AbandonProcessGroup=false.
  // Provenance never substitutes for the separately required fixed-Core/rootkill evidence.
  return (opened&&closed&&!arguments&&sawArguments&&[fields[@"path"]isEqual:Plist]&&[fields[@"program"]isEqual:program]&&
    [fields[@"properties"]isEqual:@"inferred program"]&&[fields[@"pid"]isEqual:[NSString stringWithFormat:@"%d",pid]]&&[fields[@"state"]isEqual:@"running"]&&[fields[@"type"]isEqual:@"LaunchDaemon"]&&[argv isEqual:@[program,@"--serve"]]) || Fail(error,@"loaded supervisor job does not match fixed running helper");
}
static NSDictionary *KuroSupervisorEvidence(struct proc_bsdinfo process,NSString *path,NSString *expected,NSString *actualHash,NSString *expectedHash,NSString *job,NSString **error) {
  if(process.pbi_pid<1 || process.pbi_ppid!=1 || process.pbi_uid || process.pbi_ruid || process.pbi_pgid!=process.pbi_pid || ![path isEqual:expected] || !Match(actualHash,@"\\A[0-9a-f]{64}\\z") || ![actualHash isEqual:expectedHash] || !KuroSupervisorJob(job,expected,(pid_t)process.pbi_pid,error)) {Fail(error,@"kernel/helper pin/loaded supervisor binding is not established");return nil;}
  NSDictionary *value=@{@"policy":@"fixed-mihomo-launchd-v1",@"helperSHA256":actualHash,@"startSeconds":@(process.pbi_start_tvsec),@"startMicros":@(process.pbi_start_tvusec)};
  if(!KuroSupervisionEvidence(value)) {Fail(error,@"kernel helper start identity is invalid");return nil;}return value;
}

// Fixed protected installation provenance, not writer-exit or cleanup authority.
static NSDictionary *KuroProtectedInstallationSnapshot(NSString *prefix,uid_t owner,NSString *executingHelper,NSString **error) {
  if(!KuroSessionActivationAt(prefix,owner,executingHelper,error))return nil;
  NSString *installedPath=At(prefix,[State stringByAppendingPathComponent:@"installed.json"]);
  NSData *installedBytes=ReadProtected(prefix,installedPath,owner,error);
  NSDictionary *installed=installedBytes?KuroDecodeJSON(installedBytes,MessageLimit,error):nil;
  if(!Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroNumber(installed[@"format"],1,1) || !KuroBool(installed[@"neverStarted"]) || !Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z")) {Fail(error,@"supervision installation identity unavailable");return nil;}
  NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:installed[@"release"]]];
  NSString *manifestPath=[version stringByAppendingPathComponent:@"manifest.json"],*helperPath=[version stringByAppendingPathComponent:@"helper"],*corePath=[version stringByAppendingPathComponent:@"mihomo"];
  NSData *manifestBytes=ReadProtected(prefix,manifestPath,owner,error),*receiptBytes=ReadProtected(prefix,At(prefix,FreshReceipt),owner,error),*core=ReadProtected(prefix,corePath,owner,error),*helper=ReadProtected(prefix,helperPath,owner,error),*plist=ReadProtected(prefix,At(prefix,Plist),owner,error);
  NSDictionary *manifest=manifestBytes?KuroDecodeJSON(manifestBytes,MessageLimit,error):nil,*receipt=receiptBytes?DecodeFreshReceipt(receiptBytes,error):nil;
  if(!ValidManifest(manifest,error) || ![manifest[@"activationAllowed"]boolValue] || ![manifest[@"release"]isEqual:installed[@"release"]] || ![manifest[@"core"][@"version"]isEqual:@"v1.19.33"] || !receipt || receipt[@"uninstall"] || ![receipt[@"manifestBytes"]isEqual:manifestBytes] || ![receipt[@"plist"]isEqual:plist] || !FixedPlist(plist,installed[@"release"],error) ||
     ![helperPath isEqual:executingHelper] || !core || !helper || !MachExecutable(core) || !MachExecutable(helper) || ![Hash(core)isEqual:manifest[@"core"][@"sha256"]] || ![Hash(helper)isEqual:manifest[@"helper"][@"sha256"]] || ![Hash(helper)isEqual:installed[@"helperSHA256"]]) {Fail(error,@"supervision installation manifest/receipt/helper/Core binding failed");return nil;}
  NSDictionary *files=@{installedPath:installedBytes,manifestPath:manifestBytes,At(prefix,FreshReceipt):receiptBytes,corePath:core,helperPath:helper,At(prefix,Plist):plist};
  for(NSString *path in files)if(![files[path]isEqual:ReadProtected(prefix,path,owner,error)]) {Fail(error,@"protected installation changed during supervision binding");return nil;}
  if(!KuroSessionActivationAt(prefix,owner,executingHelper,error))return nil;
  // neverStarted is mutable during the three supervision samples; bind immutable identity only.
  return @{@"installation":@{@"release":installed[@"release"],@"manifestSHA256":Hash(manifestBytes),@"freshReceiptSHA256":Hash(receiptBytes),@"coreSHA256":Hash(core)},@"helperSHA256":Hash(helper)};
}

// Finite fixed-Core writer contract: no arbitrary executable/config/HTTP or
// detached-writer support. PID/group absence remains a separate repeated gate.
static BOOL KuroInstalledRestartWriter(NSDictionary *record,NSDictionary *snapshot,NSString **error) {
  if(!KuroRestartRecord(record,error))return NO;
  NSDictionary *supervision=record[@"supervision"],*launch=record[@"launch"],*work=record[@"work"];
  if(!Keys(snapshot,@[@"installation",@"helperSHA256"]) || !supervision[@"installation"] ||
    ![supervision[@"installation"]isEqual:snapshot[@"installation"]] || ![supervision[@"helperSHA256"]isEqual:snapshot[@"helperSHA256"]] ||
    ![supervision[@"policy"]isEqual:@"fixed-mihomo-launchd-v1"] || ![launch[@"template"]isEqual:@"macos-dual-stack-v1"] ||
    ![launch[@"coreSHA256"]isEqual:snapshot[@"installation"][@"coreSHA256"]] || ![launch[@"runtimeSHA256"]isEqual:work[@"configSHA256"]] || !KuroWorkCacheOrigin(work[@"cacheOrigin"]))
    return Fail(error,@"old writer is not bound to this exact protected fixed-Core installation/runtime/cache origin");
  return YES;
}

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
@property(nonatomic, copy) BOOL (^prepareNetwork)(NSString *session,NSDictionary *binding,NSString **error);
@property(nonatomic, copy) KuroServiceStopped confirmStopped;
@property(nonatomic, copy) KuroServiceProcessHook ready;
@property(nonatomic, copy) KuroServiceProcessHook applyNetwork;
@property(nonatomic, copy) KuroServiceRecovery recoverNetwork;
@property(nonatomic, copy) NSDictionary *(^networkRecoveryObservation)(void);
@property(nonatomic, copy) BOOL (^identityValid)(int peer);
@property(nonatomic, copy) NSString *(^physicalInterface)(void);
@property(nonatomic, copy) NSDictionary *(^readinessHosts)(void);
@property(nonatomic, copy) KuroServiceRecovery verifyNetwork;
@property(nonatomic, copy) KuroSessionHook recoverResidualNetwork;
@property(nonatomic, copy) KuroRestartWorkCleanup recoverOwnedNetwork;
@property(nonatomic, copy) NSDictionary *(^recoveredNetworkEvidence)(NSDictionary *record,NSString **error);
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
  BOOL _resumeCheckpointAttempted, _stopCheckpointAttempted, _stopCheckpointComplete, _stopProofArmed;
  NSString *_stopCheckpointFailure;
  NSString *_configDigest;
  NSString *_runtimeDigest;
  NSString *_secret;
  uint64_t _nextNetworkCheck;
  NSDictionary *_socketIdentity;
  KuroCoreOutput *_output;
  NSString *_diagnosticDirectory,*_diagnosticFailure,*_diagnosticStage,*_primaryFailure;
  NSMutableDictionary<NSString *,NSData *> *_diagnosticPublished;
  NSMutableSet<NSString *> *_diagnosticDurable;
  NSArray<NSString *> *_diagnosticSecrets;
  BOOL _diagnosticComplete,_captureComplete;
  NSDictionary *_diagnosticNetwork;
  uint64_t _nextDiagnosticCheckpoint;
#ifdef KURO_TESTING
  NSString *_fixtureCore;
#endif
}
- (instancetype)initWithHooks:(KuroTunServiceHooks *)hooks;
#ifdef KURO_TESTING
- (instancetype)initFixtureDirectory:(NSString *)directory core:(NSString *)core hooks:(KuroTunServiceHooks *)hooks;
- (instancetype)initFixtureInstallation:(NSDictionary *)installation hooks:(KuroTunServiceHooks *)hooks;
@property(nonatomic, copy) void (^fixtureAfterSupervise)(void);
@property(nonatomic, copy) KuroSessionSupervisionSource fixtureSupervisionSource;
@property(nonatomic, copy) NSString *fixtureInstallationPrefix;
@property(nonatomic) KuroRestartReader fixtureRestartReader;
@property(nonatomic) KuroRestartGroupReader fixtureRestartGroupReader;
@property(nonatomic, copy) void (^fixtureBeforeResume)(void);
@property(nonatomic, copy) void (^fixtureBeforeCachePrepare)(KuroOwnedSession *session);
@property(nonatomic, copy) void (^fixtureBeforeDiagnosticFinish)(NSString *directory);
@property(nonatomic, copy) void (^fixtureBeforeWorkCreation)(void);
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
- (instancetype)initFixtureInstallation:(NSDictionary *)installation hooks:(KuroTunServiceHooks *)hooks {
  NSString *prefix=installation[@"prefix"];
  if((self=[self initFixtureDirectory:At(prefix,State) core:installation[@"core"] hooks:hooks])) {
    self.fixtureInstallationPrefix=prefix;
    _snapshot=[Status(prefix,geteuid())[@"status"] copy];
  }
  return self;
}
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
- (NSString *)diagnosticRoot {
#ifdef KURO_TESTING
  if(_fixtureCore)return [_directory stringByAppendingPathComponent:@"TunDiagnostics"];
#endif
  return [State.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"TunDiagnostics"];
}
- (BOOL)diagnosticProtected:(NSString *)file error:(NSString **)error {
  struct stat info={0};
  if(!_diagnosticDirectory || !SafeChain([self anchor],_diagnosticDirectory,_owner,YES,error) || lstat(_diagnosticDirectory.fileSystemRepresentation,&info) || (info.st_mode&07777)!=0700 || info.st_nlink<1)return Fail(error,@"diagnostics directory must remain protected mode0700");
  if(file && (!SafeChain([self anchor],file,_owner,NO,error) || lstat(file.fileSystemRepresentation,&info) || (info.st_mode&07777)!=0600 || info.st_nlink!=1))return Fail(error,@"diagnostics file must remain protected mode0600 with one link");
  return YES;
}
- (BOOL)saveDiagnostic:(NSString *)name bytes:(NSData *)bytes error:(NSString **)error {
  if(![@[@"config.redacted.json",@"launch.json",@"diagnostics.json"]containsObject:name] || !bytes)return Fail(error,@"fixed diagnostic metadata is required");
  NSString *path=[_diagnosticDirectory stringByAppendingPathComponent:name];NSData *previous=_diagnosticPublished[name];
  if(![self diagnosticProtected:Exists(path)?path:nil error:error])return NO;
  if(previous) {
    if(![ReadProtected([self anchor],path,_owner,error)isEqual:previous])return Fail(error,@"diagnostic checkpoint changed; preserve unknown bytes");
    if([previous isEqual:bytes] && [_diagnosticDurable containsObject:name])return YES;
    if(![previous isEqual:bytes]) {
      [_diagnosticDurable removeObject:name];
      NSString *temporary=[_diagnosticDirectory stringByAppendingPathComponent:[@".diagnostic-"stringByAppendingString:NSUUID.UUID.UUIDString]];
      if(!WriteNew(temporary,bytes,0600,error))return NO;
      if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation))return Fail(error,@"diagnostic metadata publish failed; preserved");
      _diagnosticPublished[name]=bytes;
    }
  } else {
    if(Exists(path))return Fail(error,@"unknown diagnostic checkpoint collision; preserved");
    if(!WriteNew(path,bytes,0600,error))return NO;
    _diagnosticPublished[name]=bytes;
  }
  if(!SyncInstallDirectory(_diagnosticDirectory,error))return NO;
  [_diagnosticDurable addObject:name];return YES;
}
- (void)diagnosticError:(NSString *)error {
  if(!_diagnosticFailure)_diagnosticFailure=error?:@"diagnostic persistence failed";
}
- (BOOL)prepareDiagnostics:(NSDictionary *)mapping runtime:(NSData *)runtime core:(NSString *)core coreSHA256:(NSString *)coreSHA256 error:(NSString **)error {
  NSDictionary *redacted=KuroDiagnosticRuntime(mapping);_diagnosticSecrets=KuroDiagnosticSecrets(mapping);
  if(!redacted || !_diagnosticSecrets)return Fail(error,@"closed runtime diagnostic redaction is unavailable");
  NSString *root=[self diagnosticRoot];struct stat node={0};
  if(!SafeChain([self anchor],root.stringByDeletingLastPathComponent,_owner,YES,error) || !EnsureDirectory([self anchor],root,_owner,0700,error) || lstat(root.fileSystemRepresentation,&node) || (node.st_mode&07777)!=0700 || node.st_nlink<1 || !SyncInstallDirectory(root.stringByDeletingLastPathComponent,error))return Fail(error,@"fixed diagnostics root must be protected mode0700");
  _diagnosticDirectory=[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  if(mkdir(_diagnosticDirectory.fileSystemRepresentation,0700) || ![self diagnosticProtected:nil error:error] || !SyncInstallDirectory(root,error))return Fail(error,@"exclusive diagnostics session directory creation failed");
  _diagnosticPublished=[NSMutableDictionary dictionary];_diagnosticDurable=[NSMutableSet set];
  NSData *redactedBytes=[NSJSONSerialization dataWithJSONObject:redacted options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
  NSArray *arguments=@[core,@"-d",[self work],@"-f",[[self work]stringByAppendingPathComponent:@"config.json"]];NSMutableArray *safeArguments=[NSMutableArray array];
  for(NSString *argument in arguments){NSString *safe=KuroDiagnosticText(argument,_diagnosticSecrets);if(!safe)return Fail(error,@"diagnostic launch argument redaction failed");[safeArguments addObject:safe];}
  NSString *safeWork=KuroDiagnosticText([self work],_diagnosticSecrets);if(!safeWork)return Fail(error,@"diagnostic work directory redaction failed");
  for(NSString *digest in @[Hash(runtime),Hash(redactedBytes),coreSHA256])if([_diagnosticSecrets containsObject:digest])return Fail(error,@"diagnostic hash conflicts with a confidential value");
  NSDictionary *launch=@{@"format":@1,@"argv":safeArguments,@"workingDirectory":safeWork,@"configSHA256":Hash(runtime),@"redactedConfigSHA256":Hash(redactedBytes),@"coreSHA256":coreSHA256,
    @"environment":@{@"PATH":@YES,@"LANG":@YES,@"SKIP_SYSTEM_IPV6_CHECK":@YES,@"HOME":@NO,@"DYLD_INSERT_LIBRARIES":@NO,@"DYLD_LIBRARY_PATH":@NO,@"DYLD_FRAMEWORK_PATH":@NO,@"CLASH_HOME_DIR":@NO,@"CLASH_CONFIG_FILE":@NO,@"CLASH_OVERRIDE_CONFIG":@NO,@"CLASH_OVERRIDE_RULES":@NO},@"stdio":@"bounded-redacted-capture"};
  if(![self saveDiagnostic:@"config.redacted.json" bytes:redactedBytes error:error] || ![self saveDiagnostic:@"launch.json" bytes:JSONData(launch) error:error])return NO;
  _output=[[KuroCoreOutput alloc]initWithSecrets:_diagnosticSecrets];
  if(!_output || ![_session setOutputStdout:[_output writer:0] stderr:[_output writer:1] error:error])return Fail(error,@"mandatory Core diagnostic capture is unavailable");
  return [_output checkpointTo:_diagnosticDirectory error:error] && SyncInstallDirectory(_diagnosticDirectory,error);
}
- (BOOL)persistDiagnosticSummary:(NSString **)error {
  NSString *safeStage=KuroDiagnosticText(_diagnosticStage?:@"startup",_diagnosticSecrets),*safeError=KuroDiagnosticText(_primaryFailure?:([_session.stopContext[@"unexpected"]boolValue]?_session.stopContext[@"reason"]:@""),_diagnosticSecrets),*safeDiagnostic=KuroDiagnosticText(_diagnosticFailure?:@"",_diagnosticSecrets);
  NSString *safeNetwork=KuroDiagnosticText(_diagnosticNetwork[@"error"]?:@"",_diagnosticSecrets);
  NSString *safeReason=KuroDiagnosticText(_session.stopContext[@"reason"]?:@"",_diagnosticSecrets);
  NSDictionary *metadata=safeStage&&safeError&&safeDiagnostic&&safeNetwork&&safeReason?@{@"format":@1,@"stage":safeStage,@"error":safeError,@"diagnosticError":safeDiagnostic,@"termination":_session.terminationEvidence?:@{@"request":@"none",@"observed":@NO},@"capture":[_output statistics],@"captureComplete":@(_captureComplete),@"stopContext":@{@"reason":safeReason,@"unexpected":_session.stopContext[@"unexpected"]?:@NO},@"networkRecovery":@{@"attempted":_diagnosticNetwork[@"attempted"]?:@NO,@"restored":_diagnosticNetwork[@"restored"]?:@NO,@"error":safeNetwork}}:nil;
  if(!metadata)return Fail(error,@"diagnostic summary redaction failed; preserve work");
  if(metadata && _session) {
    NSMutableDictionary *updated=[metadata mutableCopy];
    updated[@"timeline"]=@{@"clock":@"CLOCK_MONOTONIC",@"unit":@"milliseconds",@"wallClock":@"CLOCK_REALTIME Unix epoch",@"events":_session.lifecycleTiming};
    NSDictionary *first=_session.firstCleanupFailure;
    if(first) {
      NSString *reason=KuroDiagnosticText(first[@"error"],_diagnosticSecrets);
      if(!reason)return Fail(error,@"first cleanup error redaction failed; preserve work");
      updated[@"firstCleanupFailure"]=@{@"at":first[@"at"],@"stage":first[@"stage"],@"error":reason};
    }
    metadata=updated;
  }
  NSDictionary *observation=_diagnosticNetwork[@"observation"];
  if(observation) {
    NSString *difference=KuroDiagnosticText(observation[@"routeDifference"],_diagnosticSecrets);
    if(![observation[@"kind"]isEqual:@"current-owned-absence"] || !KuroBool(observation[@"systemRouteBaselineRestored"]) || !difference || difference.length>4096)return Fail(error,@"network absence observation is invalid; preserve work");
    NSMutableDictionary *network=[metadata[@"networkRecovery"]mutableCopy];
    network[@"observation"]=@{@"kind":@"current-owned-absence",@"systemRouteBaselineRestored":observation[@"systemRouteBaselineRestored"],@"routeDifference":difference};
    NSMutableDictionary *updated=[metadata mutableCopy];updated[@"networkRecovery"]=network;metadata=updated;
  }
  return [self saveDiagnostic:@"diagnostics.json" bytes:JSONData(metadata) error:error];
}
- (BOOL)finishDiagnostics:(NSString **)error {
  if(_diagnosticComplete)return YES;
  if(!_output || !_diagnosticDirectory)return Fail(error,_diagnosticFailure?:@"diagnostic preparation is incomplete; preserve work");
#ifdef KURO_TESTING
  if(self.fixtureBeforeDiagnosticFinish)self.fixtureBeforeDiagnosticFinish(_diagnosticDirectory);
#endif
  NSString *outputFailure=nil;_captureComplete=[_output finishTo:_diagnosticDirectory error:&outputFailure];
  if(!_captureComplete)[self diagnosticError:outputFailure];
  NSString *saveFailure=nil;BOOL saved=[self persistDiagnosticSummary:&saveFailure];
  if(!saved)[self diagnosticError:saveFailure];
  _diagnosticComplete=_captureComplete && saved;
  return _diagnosticComplete || Fail(error,_diagnosticFailure?:@"diagnostic completion checkpoint failed");
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
      // The cleanup hook's summary precedes stop returning. Persist the completed
      // transition (or first stop failure) now, without erasing the earlier error.
      NSString *timingFailure=nil;
      if(![self persistDiagnosticSummary:&timingFailure]) {
        [self diagnosticError:timingFailure];_diagnosticComplete=NO;
        if(!failure)failure=timingFailure;ok=NO;
      }
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
- (BOOL)restartWriterValid:(NSDictionary *)record error:(NSString **)error {
  NSString *prefix=@"",*helper=Executable();uid_t owner=0;
#ifdef KURO_TESTING
  if(_fixtureCore && self.fixtureInstallationPrefix) {
    prefix=self.fixtureInstallationPrefix;owner=_owner;
    if(![_directory isEqual:At(prefix,State)])return Fail(error,@"isolated installation must use its exact fixed State layout");
    NSDictionary *installed=ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),owner,error);
    if(!Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z"))return Fail(error,@"isolated installation release unavailable");
    helper=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:[installed[@"release"]stringByAppendingPathComponent:@"helper"]]];
  } else
#endif
  if(geteuid()!=0 || ![_directory isEqual:State])return Fail(error,@"fixed protected root installation required for writer validation");
  NSDictionary *snapshot=KuroProtectedInstallationSnapshot(prefix,owner,helper,error);
  return snapshot && KuroInstalledRestartWriter(record,snapshot,error);
}
- (BOOL)replayStoppedEvidenceForOwner:(NSDictionary *)record error:(NSString **)error {
  if(!Exists([_directory stringByAppendingPathComponent:@"stopped.json"]))return YES;
  NSString *prefix=@"",*helper=Executable();uid_t owner=0;
#ifdef KURO_TESTING
  if(_fixtureCore && self.fixtureInstallationPrefix) {
    prefix=self.fixtureInstallationPrefix;owner=_owner;
    if(![_directory isEqual:At(prefix,State)])return Fail(error,@"isolated stopped replay requires the fixed State layout");
    NSDictionary *installed=ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),owner,error);
    if(!Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z"))return Fail(error,@"isolated stopped replay installation unavailable");
    helper=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:[installed[@"release"]stringByAppendingPathComponent:@"helper"]]];
  } else
#endif
  if(geteuid()!=0 || ![_directory isEqual:State])return Fail(error,@"fixed protected root stopped replay required");
  NSString *proofPath=[_directory stringByAppendingPathComponent:@"stopped.json"];NSData *proofBytes=ReadProtected(prefix,proofPath,owner,error);
  if(!proofBytes || !KuroReplayStoppedCheckpoint(prefix,owner,helper,record,error) || ![ReadProtected(prefix,proofPath,owner,error)isEqual:proofBytes])return NO;
  NSDictionary *proof=KuroDecodeJSON(proofBytes,MessageLimit,error);
  if([proof[@"format"]isEqual:@3]) {
    NSDictionary *source=KuroDecodeJSON([proof[@"ownerJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
    if(!_hooks.recoveredNetworkEvidence || !KuroRecoveredNetworkValid(_hooks.recoveredNetworkEvidence(source,error),source[@"session"]))return Fail(error,@"recovered checkpoint current backend absence is not confirmed");
  }
  return YES;
}
- (BOOL)checkpointRecoveredOwner:(NSDictionary *)record bytes:(NSData *)bytes stillAbsent:(KuroSessionHook)stillAbsent error:(NSString **)error {
  if(Exists([_directory stringByAppendingPathComponent:@"stopped.json"]))return [self replayStoppedEvidenceForOwner:record error:error];
  // Legacy receipt-only recovery gets no new uninstall authority. Production
  // supplies a real backend readback for the new installation-bound owner.
  if(!record[@"supervision"][@"installation"] || !_hooks.recoveredNetworkEvidence)return YES;
  NSString *prefix=@"",*helper=Executable();uid_t owner=0;
#ifdef KURO_TESTING
  if(_fixtureCore && self.fixtureInstallationPrefix) {
    prefix=self.fixtureInstallationPrefix;owner=_owner;
    if(![_directory isEqual:At(prefix,State)])return Fail(error,@"recovered proof requires fixed isolated State layout");
    NSDictionary *installed=ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),owner,error);
    if(!Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z"))return NO;
    helper=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:[installed[@"release"]stringByAppendingPathComponent:@"helper"]]];
  } else
#endif
  if(geteuid()!=0 || ![_directory isEqual:State])return Fail(error,@"recovered proof requires fixed protected root installation");
  if(![self restartWriterValid:record error:error])return NO;
  return KuroMarkSessionRecovered(prefix,owner,helper,record,bytes,stillAbsent,^NSDictionary *(NSString **failure){return self->_hooks.recoveredNetworkEvidence(record,failure);},error);
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
    // A route intent can precede Core writes; retire it only behind the existing writer-exit proof.
    BOOL ownedRoutes=Exists([_directory stringByAppendingPathComponent:@"owner.json"]) && Exists([_directory stringByAppendingPathComponent:@"network.json"]);
    if(ownedRoutes&&!_hooks.recoverOwnedNetwork)return Fail(error,@"recorded routes require writer-proven network recovery");
    NSString *networkFailure=nil;
    if(!ownedRoutes&&!_hooks.recoverResidualNetwork(&networkFailure))return Fail(error,networkFailure?:@"residual network recovery not confirmed");
    if(!Exists([_directory stringByAppendingPathComponent:@"owner.json"]) && ![self replayStoppedEvidenceForOwner:nil error:error])return NO;
    KuroOwnedSession *observed=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    observed.recoveredNetwork=_hooks.recoverOwnedNetwork;
#ifdef KURO_TESTING
    observed.fixtureRestartReader=self.fixtureRestartReader;observed.fixtureRestartGroupReader=self.fixtureRestartGroupReader;
#endif
    if(![observed recoverExitedOwnerWithNetwork:_hooks.recoverResidualNetwork writerValidator:^BOOL(NSDictionary *record,NSString **failure) {
      return [self restartWriterValid:record error:failure];
    } workCleanup:^BOOL(NSDictionary *record,KuroSessionHook stillAbsent,NSString **failure) {
      if(record[@"supervision"][@"installation"] && ![self restartWriterValid:record error:failure])return NO;
      if(![self replayStoppedEvidenceForOwner:record error:failure])return NO;
      return [self recoverExitedWork:record stillAbsent:stillAbsent error:failure];
    } beforeOwnerRemoval:^BOOL(NSDictionary *record,NSData *bytes,KuroSessionHook stillAbsent,NSString **failure) {
      return [self checkpointRecoveredOwner:record bytes:bytes stillAbsent:stillAbsent error:failure];
    } error:error])return NO;
    ok=observed.off && (!_session || _session.off) && !Exists([self work]);
    return ok || Fail(error,@"network/Core recovery did not independently clear ownership receipts");
  } @finally {
    [self snapshot:ok?@"off":@"unknown" error:ok?_stopCheckpointFailure:((error&&*error)?*error:@"residual ownership recovery is not proven")];
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
  if(!ValidManifest(manifest,error) || !KuroMapping(manifest,@[@"format",@"label",@"release",@"target",@"protocol",@"activationAllowed",@"core",@"helper"],@[@"client",@"clientInventorySHA256",@"installerProtocol"]) || !KuroNumber(manifest[@"format"],1,1) || ![manifest[@"label"] isEqual:Label] || ![manifest[@"release"] isEqual:installed[@"release"]] || !KuroNumber(manifest[@"protocol"],1,1) || !KuroBool(manifest[@"activationAllowed"]) || ![manifest[@"activationAllowed"] boolValue] ||
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
- (NSDictionary *)supervisionEvidence:(NSString **)error {
  // Ordinary fixtures never call launchctl or masquerade as root deployment.
  if(geteuid()!=0 || ![_directory isEqual:State]) {Fail(error,@"fixed root deployment required for launchd provenance");return nil;}
  NSString *core=[self approvedCore:error];if(!core)return nil;
  NSString *version=core.stringByDeletingLastPathComponent,*helper=[version stringByAppendingPathComponent:@"helper"];
  NSDictionary *snapshot=KuroProtectedInstallationSnapshot(@"",0,helper,error);if(!snapshot)return nil;
  NSData *installedBytes=ReadProtected(@"",[State stringByAppendingPathComponent:@"installed.json"],0,error);
  NSData *manifestBytes=ReadProtected(@"",[version stringByAppendingPathComponent:@"manifest.json"],0,error),*helperBytes=ReadProtected(@"",helper,0,error),*plistBytes=ReadProtected(@"",Plist,0,error);
  NSDictionary *manifest=manifestBytes?KuroDecodeJSON(manifestBytes,65536,error):nil;
  NSDictionary *plist=plistBytes?[NSPropertyListSerialization propertyListWithData:plistBytes options:NSPropertyListImmutable format:NULL error:NULL]:nil;
  if(!ValidManifest(manifest,error) || ![manifest[@"core"][@"version"]isEqual:@"v1.19.33"] || !helperBytes || ![helper isEqual:Executable()] || ![Hash(helperBytes)isEqual:manifest[@"helper"][@"sha256"]] || !FixedPlist(plistBytes,version.lastPathComponent,error)) {Fail(error,@"fixed-mihomo launchd policy requires current protected manifest/helper/plist");return nil;}
  for(NSString *key in @[@"Disabled",@"RunAtLoad",@"KeepAlive",@"AbandonProcessGroup"])if(!KuroBool(plist[key])) {Fail(error,@"supervision plist policy fields must be booleans");return nil;}
  struct proc_bsdinfo before={0},after={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};
  if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&before,sizeof(before))!=sizeof(before) || proc_pidpath(getpid(),path,sizeof(path))<=0) {Fail(error,@"kernel helper identity unavailable");return nil;}
  NSString *job=KuroReadSupervisorJob(error);if(!job)return nil;
  if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&after,sizeof(after))!=sizeof(after) || before.pbi_pid!=after.pbi_pid || before.pbi_ppid!=after.pbi_ppid || before.pbi_pgid!=after.pbi_pgid || before.pbi_uid!=after.pbi_uid || before.pbi_ruid!=after.pbi_ruid || before.pbi_start_tvsec!=after.pbi_start_tvsec || before.pbi_start_tvusec!=after.pbi_start_tvusec ||
    ![installedBytes isEqual:ReadProtected(@"",[State stringByAppendingPathComponent:@"installed.json"],0,error)] || ![manifestBytes isEqual:ReadProtected(@"",[version stringByAppendingPathComponent:@"manifest.json"],0,error)] || ![helperBytes isEqual:ReadProtected(@"",helper,0,error)] || ![plistBytes isEqual:ReadProtected(@"",Plist,0,error)]) {Fail(error,@"protected helper deployment changed during supervisor snapshot");return nil;}
  NSDictionary *current=KuroProtectedInstallationSnapshot(@"",0,helper,error);
  if(!current || ![current isEqual:snapshot]) {Fail(error,@"protected installation identity changed during supervisor snapshot");return nil;}
  NSMutableDictionary *evidence=[KuroSupervisorEvidence(after,@(path),helper,Hash(helperBytes),manifest[@"helper"][@"sha256"],job,error)mutableCopy];
  if(!evidence)return nil;evidence[@"installation"]=snapshot[@"installation"];
  return KuroSupervisionEvidence(evidence)?evidence:nil;
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
  if(![self finishDiagnostics:error])return NO;
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
  if(_output && now>=_nextDiagnosticCheckpoint) {
    _nextDiagnosticCheckpoint=now+1000;NSString *captureFailure=nil;
    if(![_output checkpointTo:_diagnosticDirectory error:&captureFailure] || !SyncInstallDirectory(_diagnosticDirectory,&captureFailure)) {
      [self diagnosticError:captureFailure];return Fail(error,@"Core diagnostic checkpoint failed; owned stop required");
    }
  }
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
    _resumeCheckpointAttempted=NO; _stopCheckpointAttempted=NO; _stopCheckpointComplete=NO; _stopCheckpointFailure=nil; _stopProofArmed=NO;
    _snapshot=@{@"availability":@"blocked",@"state":@"unknown",@"error":@"session startup transaction is active"};
  }
  BOOL success=NO,acknowledged=NO; NSString *failure=nil; __block NSString *stage=@"open decode";
  _output=nil;_diagnosticDirectory=nil;_diagnosticFailure=nil;_diagnosticStage=nil;_primaryFailure=nil;_diagnosticPublished=nil;_diagnosticDurable=nil;_diagnosticSecrets=nil;_diagnosticComplete=NO;_captureComplete=NO;_diagnosticNetwork=nil;_nextDiagnosticCheckpoint=0;
  @try {
    id open=KuroDecodeJSON(frame,66000,&failure);
    if(!Keys(open,@[@"version",@"operation",@"config"]) || !KuroNumber(open[@"version"],2,2) || ![open[@"operation"] isEqual:@"open"] || ![open[@"config"] isKindOfClass:NSDictionary.class]) { failure=@"invalid closed version-2 open frame"; return NO; }
    NSData *canonical=[NSJSONSerialization dataWithJSONObject:open[@"config"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:NULL];
    stage=@"closed config validation"; _admitted=KuroValidateTunConfig(canonical,&failure); if(!_admitted)return NO; _configDigest=Hash(canonical);
    if(!_hooks.authorize||!_hooks.preflight||!_hooks.beforeStart||!_hooks.beforeResume||!_hooks.prepareNetwork||!_hooks.confirmStopped||!_hooks.ready||!_hooks.applyNetwork||!_hooks.recoverNetwork||!_hooks.identityValid) { failure=@"complete authorization, process and network hooks are required"; return NO; }
    if(!_hooks.authorize(peer,_configDigest,&failure) || !_hooks.identityValid(peer) || !_hooks.preflight(_admitted,&failure)) { failure=failure ?: @"caller or process/network prerequisites are not proven"; return NO; }
    if(![self startupAllowed:&failure])return NO;
    stage=@"fixed Core approval"; NSString *core=[self approvedCore:&failure]; if(!core)return NO;
    if(!SafeChain([self anchor],_directory,_owner,YES,&failure) || Exists([self work])) { failure=@"protected clean session directory is required"; return NO; }
    stage=@"clean ownership"; _session=[[KuroOwnedSession alloc] initWithDirectory:_directory owner:_owner];
    if(!_session.off) { failure=@"persisted ownership cannot be proven off"; return NO; }
    __weak KuroTunService *checkpointOwner=self;
    if(![_session setBeforeOwnerRemoval:^BOOL(NSDictionary *process,NSString **problem) {
      KuroTunService *strong=checkpointOwner;if(!strong)return Fail(problem,@"held-stop owner disappeared");
      if(!strong->_stopProofArmed)return YES;
      NSString *checkpointFailure=nil;BOOL saved=strong->_hooks.confirmStopped && strong->_hooks.confirmStopped(process,&checkpointFailure);
      strong->_stopCheckpointAttempted=YES;strong->_stopCheckpointComplete=saved;
      strong->_stopCheckpointFailure=saved?nil:[@"cleanup confirmed, uninstall checkpoint failed: "stringByAppendingString:checkpointFailure?:@"held-stop confirmation hook unavailable"];
      return saved || Fail(problem,strong->_stopCheckpointFailure);
    } error:&failure])return NO;

#ifdef KURO_TESTING
    if(_fixtureCore && self.fixtureSupervisionSource) {if(![_session setSupervisionSource:self.fixtureSupervisionSource error:&failure])return NO;}
    if(!_fixtureCore)
#endif
    {
      __weak KuroTunService *sourceOwner=self;
      if(![_session setSupervisionSource:^NSDictionary *(NSString **problem) {return [sourceOwner supervisionEvidence:problem];} error:&failure])return NO;
    }
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
    stage=@"diagnostic preparation";
    if(![self prepareDiagnostics:mapping runtime:runtime core:core coreSHA256:Hash(coreBytes) error:&failure]) { [self diagnosticError:failure];return NO; }
    stage=@"private runtime creation";
#ifdef KURO_TESTING
    if(self.fixtureBeforeWorkCreation)self.fixtureBeforeWorkCreation();
#endif
    if(mkdir([self work].fileSystemRepresentation,0700)) { failure=@"private work directory creation failed"; return NO; } _workCreated=YES;
    if(!WriteNew([[self work] stringByAppendingPathComponent:@"config.json"],runtime,0600,&failure))return NO;
    stage=@"cache provenance preparation";
#ifdef KURO_TESTING
    if(self.fixtureBeforeCachePrepare)self.fixtureBeforeCachePrepare(_session);
#endif
    if(![_session prepareWorkCache:&failure])return NO;
    if(![_session setLaunchEvidence:@{@"configSHA256":_configDigest,@"runtimeSHA256":_runtimeDigest,@"coreSHA256":Hash(coreBytes),@"template":@"macos-dual-stack-v1"} error:&failure])return NO;
    __weak KuroTunService *weakSelf=self;
    stage=@"owned Core spawn";NSString *spawnFailure=nil; BOOL spawned=[_session spawnExecutable:core arguments:@[@"-d",[self work],@"-f",[[self work] stringByAppendingPathComponent:@"config.json"]] workingDirectory:[self work] beforeResume:^BOOL(NSString **problem) {
      KuroTunService *strong=weakSelf;BOOL prepared=strong && [strong startupAllowed:problem] && strong->_hooks.identityValid(peer) && SafeChain([strong anchor],[strong work],strong->_owner,YES,problem);
      if(!prepared && strong && problem && *problem && !strong->_primaryFailure)strong->_primaryFailure=*problem;
      return prepared;
    } afterReap:^BOOL(NSString **problem) {
      KuroTunService *strong=weakSelf;if(!strong)return Fail(problem,@"service owner disappeared during cleanup");
      strong->_diagnosticStage=stage;
      NSString *diagnostic=nil,*network=nil;BOOL saved=[strong finishDiagnostics:&diagnostic];
      // Network recovery must run even if logging failed; it retains its own ownership gates.
      if(!saved)[strong->_session noteCleanupFailure:diagnostic stage:@"diagnostic finish"];
      BOOL restored=strong->_hooks.recoverNetwork(strong->_session.identifier,&network);
      if(!restored)[strong->_session noteCleanupFailure:network?:@"network restoration is not proven" stage:@"network recovery"];
      NSMutableDictionary *recovery=[@{@"attempted":@YES,@"restored":@(restored),@"error":network?:@""}mutableCopy];
      NSDictionary *observation=restored&&strong->_hooks.networkRecoveryObservation?strong->_hooks.networkRecoveryObservation():nil;
      if(observation)recovery[@"observation"]=observation;
      strong->_diagnosticNetwork=recovery;
      NSString *summaryFailure=nil;BOOL summary=[strong persistDiagnosticSummary:&summaryFailure];
      if(!summary){[strong->_session noteCleanupFailure:summaryFailure stage:@"diagnostic summary"];[strong diagnosticError:summaryFailure];strong->_diagnosticComplete=NO;saved=NO;diagnostic=summaryFailure;}
      if(!saved || !restored)return Fail(problem,!restored?(network?:@"network restoration is not proven"):(diagnostic?:@"diagnostic persistence is not proven"));
      NSString *workFailure=nil;BOOL removed=[strong removeWork:&workFailure];
      if(!removed){[strong->_session noteCleanupFailure:workFailure stage:@"work removal"];return Fail(problem,workFailure?:@"work removal is not proven");}return YES;
    } resumeGate:^BOOL(KuroSessionHook resume,NSString **problem) {
      KuroTunService *strong=weakSelf; if(!strong)return Fail(problem,@"service owner disappeared");
#ifdef KURO_TESTING
      if(strong.fixtureBeforeResume)strong.fixtureBeforeResume();
#endif
      // Cancellation and SIGCONT share the lock with requestStop.
      @synchronized(strong) {
        if(![strong startupAllowed:problem] || !strong->_hooks.identityValid(peer)) {
          strong->_primaryFailure=@"owned child resume refused: stop or identity loss before Core resume";return Fail(problem,strong->_primaryFailure);
        }
        strong->_resumeCheckpointAttempted=YES;
        if(!strong->_hooks.beforeStart(problem)) {if(problem&&*problem)strong->_primaryFailure=*problem;return NO;}
        strong->_stopProofArmed=YES;
        if(!strong->_hooks.beforeResume(problem)) {if(problem&&*problem)strong->_primaryFailure=*problem;return NO;}
        NSDictionary *binding=[strong->_session preparedNetworkBinding:problem];
        if(!binding || !strong->_hooks.prepareNetwork(strong->_session.identifier,binding,problem)) {if(problem&&*problem)strong->_primaryFailure=*problem;return NO;}
        BOOL resumed=resume(problem);if(!resumed&&problem&&*problem)strong->_primaryFailure=*problem;return resumed;
      }
    } error:&spawnFailure];
    if(spawnFailure)failure=spawnFailure;
    [_output closeWriters];
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
    acknowledged=YES;stage=@"authenticated owner supervision";
    NSString *supervisionFailure=nil;
    success=[_session superviseSocket:peer leaseMilliseconds:15000 identityValid:^BOOL { KuroTunService *strong=weakSelf; return strong && strong->_hooks.identityValid(peer); } tick:^BOOL(NSString **problem) { return [weakSelf tick:problem]; } stopCheckpoint:^BOOL(NSString **problem) { return [weakSelf checkpointStopped:problem]; } error:&supervisionFailure];
    if(supervisionFailure)failure=supervisionFailure;
#ifdef KURO_TESTING
    if(self.fixtureAfterSupervise)self.fixtureAfterSupervise();
#endif
  } @finally {
    _diagnosticStage=stage;if(!success && failure && !_primaryFailure && !_diagnosticFailure)_primaryFailure=failure;
    [_output closeWriters];
    if(_session && !_session.off) { NSString *cleanup=nil; if(![_session stop:&cleanup])failure=cleanup ?: failure; }
    if(_output && !_session.child) {
      NSString *diagnostic=nil;
      if(![self finishDiagnostics:&diagnostic] || ![self persistDiagnosticSummary:&diagnostic]) {
        [self diagnosticError:diagnostic];_diagnosticComplete=NO;success=NO;
      }
    }
    if(_workCreated && (!_session || _session.off)) { NSString *cleanup=nil; if(![self removeWork:&cleanup])failure=cleanup ?: failure; }
    BOOL off=(_session ? _session.off : previouslyOff) && !_workCreated && !Exists([self work]);
    if(off) {
      NSString *checkpoint=nil;
      if(_session && ![self checkpointStopped:&checkpoint]) {success=NO;failure=checkpoint;}
      [self snapshot:@"off" error:_stopCheckpointFailure?:(!_diagnosticComplete?_diagnosticFailure:nil)];
    }
    else if(_session||_workCreated)[self snapshot:@"unknown" error:failure ?: @"cleanup cannot be proven"];
    if(_primaryFailure)failure=_primaryFailure;
    else if(_diagnosticFailure)failure=[@"diagnostic failure: "stringByAppendingString:_diagnosticFailure];
    if(!success && !failure)failure=[@"failed stage: " stringByAppendingString:stage];
    if(!success && !acknowledged)KuroServiceReply(peer,KuroServiceError(failure));
    [self finishPending];
    if(!off)[self retainCleanupOnPeer:peer];
    @synchronized(self) { _busy=NO; }
    if(error)*error=failure;
  }
  return success;
}
@end
