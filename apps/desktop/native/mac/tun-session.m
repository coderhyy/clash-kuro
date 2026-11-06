// Internal supervisor, not an RPC executor. Only the authenticated, validated launch
// path may supply an executable. The production start gate remains closed.
#include <libproc.h>
#include <sys/proc_info.h>
#include <pthread.h>

static uint64_t KuroMonotonicMilliseconds(void) {
  struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
typedef BOOL (^KuroSessionHook)(NSString **error);
typedef BOOL (^KuroSessionStopEvidenceCheckpoint)(NSDictionary *process,NSString **error);
typedef NSDictionary *(^KuroSessionSupervisionSource)(NSString **error);
static BOOL KuroSessionTemplate(NSString *value) {
#ifdef KURO_CORE_EXPERIMENT
  return [value isEqual:@"core-control-experiment-v1"];
#else
  return [value isEqual:@"macos-dual-stack-v1"];
#endif
}
typedef BOOL (^KuroSessionResumeGate)(KuroSessionHook resume, NSString **error);
typedef int (*KuroRestartReader)(int,int,uint64_t,void *,int);
typedef int (*KuroRestartGroupReader)(uint32_t,uint32_t,void *,int);
typedef BOOL (^KuroRestartWriterValidator)(NSDictionary *owner,NSString **error);
typedef BOOL (^KuroRestartEvidenceCheckpoint)(NSDictionary *record, NSData *originalOwnerBytes, KuroSessionHook stillAbsent, NSString **error);
typedef BOOL (^KuroRestartWorkCleanup)(NSDictionary *record,KuroSessionHook stillAbsent,NSString **error);
// A fresh helper never kills or adopts this PID. Any observed process, including
// a different start identity, prevents deletion; only explicit ESRCH is absence.
static BOOL KuroRestartAbsent(NSDictionary *record,KuroRestartReader reader,NSString **error) {
  struct proc_bsdinfo observed={0}; errno=0;
  int count=reader([record[@"pid"]intValue],PROC_PIDTBSDINFO,0,&observed,sizeof(observed)); int failure=errno;
  if(count==0 && failure==ESRCH)return YES;
  if(count==sizeof(observed)) {
    BOOL same=observed.pbi_pid==[record[@"pid"]unsignedIntValue] && observed.pbi_start_tvsec==[record[@"startSeconds"]unsignedLongLongValue] && observed.pbi_start_tvusec==[record[@"startMicros"]unsignedLongLongValue];
    return Fail(error,same?@"old Core identity is still present; no restart PID adoption":@"old Core PID now has a different identity; preserving owner/work");
  }
  return Fail(error,@"old Core absence is not observable; preserving owner/work");
}
// Additional refusal gate only: helper absence grants no new writer/cleanup proof.
static BOOL KuroRestartSupervisorAbsent(NSDictionary *record,KuroRestartReader reader,NSString **error) {
  NSDictionary *supervision=record[@"supervision"];
  if(!supervision)return YES;
  struct proc_bsdinfo observed={0};errno=0;
  int count=reader([record[@"parent"]intValue],PROC_PIDTBSDINFO,0,&observed,sizeof(observed));int failure=errno;
  if(count==0 && failure==ESRCH)return YES;
  if(count==sizeof(observed)) {
    BOOL same=observed.pbi_pid==[record[@"parent"]unsignedIntValue] && observed.pbi_start_tvsec==[supervision[@"startSeconds"]unsignedLongLongValue] && observed.pbi_start_tvusec==[supervision[@"startMicros"]unsignedLongLongValue];
    return Fail(error,same?@"old helper identity is still present; preserving owner/work":@"old helper PID now has a different identity; preserving owner/work");
  }
  return Fail(error,@"old helper absence is not observable; preserving owner/work");
}
// Reject-only observation: a reused PGID may block recovery, never authorize it.
// Empty samples do not establish that detached descendants/writers have exited.
static BOOL KuroRestartGroupEmpty(NSDictionary *record,KuroRestartGroupReader reader,NSString **error) {
  pid_t members[64]={0};errno=0;
  int count=reader(PROC_PGRP_ONLY,[record[@"processGroup"]unsignedIntValue],members,sizeof(members));int failure=errno;
  if(count<0 || count>=(int)sizeof(members) || count%(int)sizeof(pid_t) || failure)
    return Fail(error,@"old Core process group cannot be fully observed; preserving owner/work");
  for(NSUInteger i=0;i<(NSUInteger)count/sizeof(pid_t);i++) {
    if(members[i]<0)return Fail(error,@"old Core process group observation is invalid; preserving owner/work");
    if(members[i]>0)return Fail(error,@"old Core process group is not empty; preserving owner/work without PID/PGID adoption");
  }
  return YES;
}
// Fixed work/cache.db only. No path is stored or accepted from a caller.
static BOOL KuroWorkCacheReceipt(id value) {
  if(!Keys(value,@[@"device",@"inode",@"size",@"mode",@"modifiedSeconds",@"modifiedNanos",@"changedSeconds",@"changedNanos",@"sha256"]))return NO;
  for(NSString *key in @[@"device",@"inode",@"size",@"mode",@"modifiedSeconds",@"modifiedNanos",@"changedSeconds",@"changedNanos"])
    if(!KuroNumber(value[key],[key isEqual:@"inode"]?1:0,9007199254740991ULL))return NO;
  return [value[@"size"]unsignedLongLongValue]<=1024*1024 && [value[@"mode"]unsignedIntValue]<=07777 && !([value[@"mode"]unsignedIntValue]&06022) &&
    [value[@"modifiedNanos"]unsignedIntValue]<1000000000 && [value[@"changedNanos"]unsignedIntValue]<1000000000 && Match(value[@"sha256"],@"\\A[0-9a-f]{64}\\z");
}
static NSDictionary *KuroWorkCacheSnapshot(NSString *directory,uid_t owner,NSString **error) {
  NSString *path=[[directory stringByAppendingPathComponent:@"session-work"]stringByAppendingPathComponent:@"cache.db"];
  struct stat before={0},after={0};
  if(lstat(path.fileSystemRepresentation,&before) || !SafeMetadata(before,owner,NO) || before.st_size<0 || before.st_size>1024*1024) { Fail(error,@"fixed Core cache is not a safe bounded owned regular file");return nil; }
  NSData *bytes=ReadProtected(directory,path,owner,error);
  if(!bytes || lstat(path.fileSystemRepresentation,&after) || !SafeMetadata(after,owner,NO) || before.st_dev!=after.st_dev || before.st_ino!=after.st_ino || before.st_size!=after.st_size || before.st_mode!=after.st_mode ||
    before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec || before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec || bytes.length!=(NSUInteger)after.st_size) { Fail(error,@"fixed Core cache changed while reading; preserve work");return nil; }
  NSDictionary *receipt=@{@"device":@((uint64_t)after.st_dev),@"inode":@((uint64_t)after.st_ino),@"size":@((uint64_t)after.st_size),@"mode":@(after.st_mode&07777),
    @"modifiedSeconds":@(after.st_mtimespec.tv_sec),@"modifiedNanos":@(after.st_mtimespec.tv_nsec),@"changedSeconds":@(after.st_ctimespec.tv_sec),@"changedNanos":@(after.st_ctimespec.tv_nsec),@"sha256":Hash(bytes)};
  if(!KuroWorkCacheReceipt(receipt)) { Fail(error,@"fixed Core cache identity exceeds its closed receipt");return nil; } return receipt;
}
static BOOL KuroWorkDirectoryReceipt(id value) {
  return Keys(value,@[@"device",@"inode",@"owner",@"mode"]) && KuroNumber(value[@"device"],0,9007199254740991ULL) &&
    KuroNumber(value[@"inode"],1,9007199254740991ULL) && KuroNumber(value[@"owner"],0,UINT_MAX) && KuroNumber(value[@"mode"],0700,0700);
}
static NSDictionary *KuroWorkDirectorySnapshot(NSString *directory,uid_t owner,NSString **error) {
  NSString *work=[directory stringByAppendingPathComponent:@"session-work"];struct stat node={0};
  if(!SafeChain(directory,work,owner,YES,error) || lstat(work.fileSystemRepresentation,&node) || !SafeMetadata(node,owner,YES) || (node.st_mode&07777)!=0700) {Fail(error,@"fixed work directory ownership or mode changed");return nil;}
  NSDictionary *value=@{@"device":@((uint64_t)node.st_dev),@"inode":@((uint64_t)node.st_ino),@"owner":@(node.st_uid),@"mode":@(node.st_mode&07777)};
  if(!KuroWorkDirectoryReceipt(value)){Fail(error,@"fixed work directory identity exceeds its closed receipt");return nil;}return value;
}
// Provenance only: it never establishes that any writer has stopped.
static BOOL KuroWorkCacheOrigin(id value) {
  return Keys(value,@[@"device",@"inode",@"owner",@"mode"]) && KuroNumber(value[@"device"],0,9007199254740991ULL) &&
    KuroNumber(value[@"inode"],1,9007199254740991ULL) && KuroNumber(value[@"owner"],0,UINT_MAX) && KuroNumber(value[@"mode"],0600,0600);
}
static BOOL KuroWorkCacheMatchesOrigin(NSDictionary *snapshot,NSDictionary *origin,uid_t owner) {
  return KuroWorkCacheReceipt(snapshot) && KuroWorkCacheOrigin(origin) && [origin[@"owner"]unsignedLongLongValue]==owner &&
    [snapshot[@"device"]isEqual:origin[@"device"]] && [snapshot[@"inode"]isEqual:origin[@"inode"]] && [snapshot[@"mode"]isEqual:origin[@"mode"]];
}
// Provenance only. This does not prove writer exit or grant restart deletion rights.
static BOOL KuroSupervisionEvidence(id value) {
  if(!KuroMapping(value,@[@"policy",@"helperSHA256",@"startSeconds",@"startMicros"],@[@"installation"]))return NO;
  NSDictionary *installation=value[@"installation"];
  if(installation && (!Keys(installation,@[@"release",@"manifestSHA256",@"freshReceiptSHA256",@"coreSHA256"]) || !Match(installation[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z") ||
    !Match(installation[@"manifestSHA256"],@"\\A[0-9a-f]{64}\\z") || !Match(installation[@"freshReceiptSHA256"],@"\\A[0-9a-f]{64}\\z") || !Match(installation[@"coreSHA256"],@"\\A[0-9a-f]{64}\\z")))return NO;
  return
    [value[@"policy"]isEqual:@"fixed-mihomo-launchd-v1"] && Match(value[@"helperSHA256"],@"\\A[0-9a-f]{64}\\z") &&
    KuroNumber(value[@"startSeconds"],1,9007199254740991ULL) && KuroNumber(value[@"startMicros"],0,999999);
}
static BOOL KuroRestartRecord(NSDictionary *record,NSString **error) {
  NSArray *base=@[@"format",@"session",@"pid",@"parent",@"startSeconds",@"startMicros",@"executableSHA256",@"phase",@"processGroup"];
  if(!KuroMapping(record,base,@[@"launch",@"work",@"supervision"]) || !KuroNumber(record[@"format"],1,2) || !KuroNumber(record[@"pid"],1,INT_MAX) || !KuroNumber(record[@"parent"],1,INT_MAX) ||
    !KuroNumber(record[@"startSeconds"],1,9007199254740991ULL) || !KuroNumber(record[@"startMicros"],0,999999) || !KuroNumber(record[@"processGroup"],1,INT_MAX) ||
    !Match(record[@"executableSHA256"],@"\\A[0-9a-f]{64}\\z") || ![record[@"phase"]isEqual:@"prepared"] || ![record[@"session"]isKindOfClass:NSString.class])return Fail(error,@"invalid closed old Core owner receipt");
  NSUUID *session=[[NSUUID alloc]initWithUUIDString:record[@"session"]]; if(!session || ![session.UUIDString isEqual:record[@"session"]])return Fail(error,@"invalid old Core owner session");
  if(record[@"supervision"] && (!KuroSupervisionEvidence(record[@"supervision"]) || !KuroNumber(record[@"format"],2,2) ||
     ![record[@"parent"]isEqual:record[@"processGroup"]] || [record[@"pid"]isEqual:record[@"parent"]]))return Fail(error,@"invalid closed helper supervision provenance");
  NSDictionary *launch=record[@"launch"];
  if(launch && (!KuroMapping(launch,@[@"configSHA256",@"coreSHA256",@"template"],@[@"runtimeSHA256"]) || !Match(launch[@"configSHA256"],@"\\A[0-9a-f]{64}\\z") || ![launch[@"coreSHA256"]isEqual:record[@"executableSHA256"]] || !KuroSessionTemplate(launch[@"template"]) || (launch[@"runtimeSHA256"] && !Match(launch[@"runtimeSHA256"],@"\\A[0-9a-f]{64}\\z"))))return Fail(error,@"old Core launch evidence does not match its owner");
  NSDictionary *work=record[@"work"];
  if([record[@"format"]isEqual:@1])return !work || Fail(error,@"legacy owner cannot carry unversioned work evidence");
  if(!launch || !KuroMapping(work,@[@"configSHA256",@"socket"],@[@"cache",@"cacheOrigin",@"cacheCheckpoint",@"directory"]) || !Match(work[@"configSHA256"],@"\\A[0-9a-f]{64}\\z"))return Fail(error,@"old Core work receipt is incomplete");
  if(work[@"cache"] && !KuroWorkCacheReceipt(work[@"cache"]))return Fail(error,@"old Core cache receipt is invalid");
  if(work[@"cacheOrigin"] && (!KuroWorkCacheOrigin(work[@"cacheOrigin"]) || (work[@"cache"] && !KuroWorkCacheMatchesOrigin(work[@"cache"],work[@"cacheOrigin"],[work[@"cacheOrigin"][@"owner"]unsignedIntValue]))))return Fail(error,@"old Core cache provenance is invalid or differs from final receipt");
  if(work[@"directory"] && !KuroWorkDirectoryReceipt(work[@"directory"]))return Fail(error,@"old Core work directory identity is invalid");
  NSDictionary *installation=record[@"supervision"][@"installation"];
  if(installation && (!work[@"directory"] || ![installation[@"coreSHA256"]isEqual:record[@"executableSHA256"]] || ![launch[@"runtimeSHA256"]isEqual:work[@"configSHA256"]]))return Fail(error,@"installed supervision does not match the fixed Core/runtime receipt");
  if(work[@"cacheCheckpoint"] && (![work[@"cacheCheckpoint"]isEqual:@"validated-restart-v1"] || !installation || !work[@"cacheOrigin"] || !work[@"cache"]))return Fail(error,@"restart cache checkpoint lacks its closed source binding");
  id socket=work[@"socket"];
  return socket==NSNull.null || (Keys(socket,@[@"device",@"inode"]) && KuroNumber(socket[@"device"],0,9007199254740991ULL) && KuroNumber(socket[@"inode"],1,9007199254740991ULL)) || Fail(error,@"old Core socket receipt is invalid");
}
// This evidence is issued only by the serial instance that held and reaped
// the child. It proves that direct child and our recorded writers, not detached descendants.
static BOOL KuroCompletedStopEvidence(id value) {
  if(!Keys(value,@[@"format",@"session",@"owner",@"ownerSHA256",@"childReaped",@"cleanupComplete"]) || !KuroNumber(value[@"format"],1,1) ||
    !KuroBool(value[@"childReaped"]) || ![value[@"childReaped"]boolValue] || !KuroBool(value[@"cleanupComplete"]) || ![value[@"cleanupComplete"]boolValue] ||
    !KuroRestartRecord(value[@"owner"],NULL) || ![value[@"session"]isEqual:value[@"owner"][@"session"]] || ![Hash(JSONData(value[@"owner"]))isEqual:value[@"ownerSHA256"]])return NO;
  return YES;
}
static BOOL KuroCaptureWriters(int output,int errors,NSString **error) {
  if(output==errors)return Fail(error,@"distinct capture pipe writers are required");
  for(NSNumber *number in @[@(output),@(errors)]) {
    int fd=number.intValue;struct stat info={0};int flags=fd>3?fcntl(fd,F_GETFL):-1;
    if(fd<=3||flags<0||(flags&O_ACCMODE)!=O_WRONLY||fstat(fd,&info)||!S_ISFIFO(info.st_mode))return Fail(error,@"two valid capture pipe writers above FD3 are required");
  }
  return YES;
}
#ifdef KURO_CORE_EXPERIMENT
typedef NS_ENUM(NSUInteger,KuroExperimentStopTrigger) {
  KuroExperimentStopNone,KuroExperimentStopUnexpected,KuroExperimentStopOwnerRequest,KuroExperimentStopOwnerEOF
};
#endif
@interface KuroOwnedSession : NSObject {
  pid_t _child;
  pthread_t _thread;
  NSString *_directory;
  NSString *_identifier;
  uid_t _owner;
  BOOL _journaled;
  BOOL _unknown;
  BOOL _directorySyncPending;
  BOOL _ownerRemovalPending;
  KuroSessionHook _cleanup;
  NSDictionary *_launchEvidence;
  KuroSessionSupervisionSource _supervisionSource;
  NSDictionary *_initialSupervision;
  pid_t _reapedOwnedChild;
  NSDictionary *_completedStop;
  KuroSessionStopEvidenceCheckpoint _beforeOwnerRemoval;
  NSData *_heldOwnerBytes;
  NSDictionary *_workCacheInitial;
  NSDictionary *_workCacheOrigin;
  NSString *_terminationRequest;
  NSDictionary *_terminationEvidence;
  NSDictionary *_stopContext;
  int _stdoutDescriptor,_stderrDescriptor;
#ifdef KURO_CORE_EXPERIMENT
  KuroExperimentStopTrigger _experimentStopTrigger;
  BOOL _experimentStopAcknowledged;
#endif
}
@property(nonatomic, readonly) pid_t child;
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) BOOL off;
@property(nonatomic, readonly) NSDictionary *terminationEvidence;
@property(nonatomic, readonly) NSDictionary *stopContext;
@property(nonatomic, copy) KuroRestartWorkCleanup recoveredNetwork;
- (NSDictionary *)preparedNetworkBinding:(NSString **)error;
- (BOOL)setOutputStdout:(int)output stderr:(int)errors error:(NSString **)error;
#ifdef KURO_CORE_EXPERIMENT
@property(nonatomic, readonly) KuroExperimentStopTrigger experimentStopTrigger;
@property(nonatomic, readonly) BOOL experimentStopAcknowledged;
@property(nonatomic) int experimentStdoutDescriptor;
@property(nonatomic) int experimentStderrDescriptor;
#endif
#ifdef KURO_TESTING
@property(nonatomic) KuroRestartReader fixtureRestartReader;
@property(nonatomic) KuroRestartGroupReader fixtureRestartGroupReader;
@property(nonatomic) BOOL fixtureFailWorkCacheSync;
@property(nonatomic) BOOL fixtureFailOwnerPublish;
@property(nonatomic) BOOL fixtureFailOwnerUnlink;
@property(nonatomic) BOOL fixtureFailDirectorySync;
#endif
- (BOOL)prepareWorkCache:(NSString **)error;
- (BOOL)recordWorkSocket:(NSDictionary *)identity error:(NSString **)error;
- (BOOL)recordReapedWorkCache:(NSDictionary *)identity error:(NSString **)error;
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error;
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network writerValidator:(KuroRestartWriterValidator)validator workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error;
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network writerValidator:(KuroRestartWriterValidator)validator workCleanup:(KuroRestartWorkCleanup)workCleanup beforeOwnerRemoval:(KuroRestartEvidenceCheckpoint)checkpoint error:(NSString **)error;

- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error;
- (BOOL)setLaunchEvidence:(NSDictionary *)evidence error:(NSString **)error;
- (BOOL)setSupervisionSource:(KuroSessionSupervisionSource)source error:(NSString **)error;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup resumeGate:(KuroSessionResumeGate)resumeGate error:(NSString **)error;
- (BOOL)setBeforeOwnerRemoval:(KuroSessionStopEvidenceCheckpoint)checkpoint error:(NSString **)error;
- (BOOL)stop:(NSString **)error;
- (BOOL)heldCleanupCanRetry;
- (NSDictionary *)completedStopEvidence:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid error:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick error:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopConfirmed:(void (^)(void))stopConfirmed error:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopCheckpoint:(KuroSessionHook)stopCheckpoint error:(NSString **)error;
@end
@implementation KuroOwnedSession
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner {
  if ((self = [super init])) { _directory = [directory copy]; _owner = owner; _thread = pthread_self(); _identifier = NSUUID.UUID.UUIDString; }
  return self;
}
- (pid_t)child { return _child; }
- (NSString *)identifier { return _identifier; }
#ifdef KURO_CORE_EXPERIMENT
- (KuroExperimentStopTrigger)experimentStopTrigger {return _experimentStopTrigger;}
- (BOOL)experimentStopAcknowledged {return _experimentStopAcknowledged;}
- (int)experimentStdoutDescriptor {return _stdoutDescriptor;}
- (void)setExperimentStdoutDescriptor:(int)value {_stdoutDescriptor=value;}
- (int)experimentStderrDescriptor {return _stderrDescriptor;}
- (void)setExperimentStderrDescriptor:(int)value {_stderrDescriptor=value;}
#endif
- (NSDictionary *)preparedNetworkBinding:(NSString **)error {
  NSDictionary *record=_heldOwnerBytes?[NSJSONSerialization JSONObjectWithData:_heldOwnerBytes options:0 error:NULL]:nil;
  if(!_journaled || _child<=0 || !KuroRestartRecord(record,error) || ![record[@"session"]isEqual:_identifier] || [record[@"pid"]intValue]!=_child || !record[@"launch"]) {
    Fail(error,@"prepared network binding requires the held persisted Core owner");return nil;
  }
  NSMutableDictionary *binding=[record[@"launch"]mutableCopy];
  binding[@"process"]=@{@"pid":record[@"pid"],@"startSeconds":record[@"startSeconds"],@"startMicros":record[@"startMicros"]};
  return binding;
}
- (NSDictionary *)stopContext {return _stopContext;}
- (NSDictionary *)terminationEvidence { return _terminationEvidence ?: @{@"request":@"none",@"observed":@NO}; }
- (BOOL)setOutputStdout:(int)output stderr:(int)errors error:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || !KuroCaptureWriters(output,errors,error))return Fail(error,@"clean session and valid output capture writers required");
  _stdoutDescriptor=output;_stderrDescriptor=errors;return YES;
}
- (BOOL)setSupervisionSource:(KuroSessionSupervisionSource)source error:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || !source)return Fail(error,@"clean session and internal supervision source required");
  NSDictionary *observed=source(error);
  if(!KuroSupervisionEvidence(observed) || getpgrp()!=getpid())return Fail(error,@"fixed launchd supervision could not be established before work creation");
  NSDictionary *initial=[[NSDictionary alloc]initWithDictionary:observed copyItems:YES];
  _supervisionSource=[source copy];_initialSupervision=initial;return YES;
}
- (BOOL)off {
  if (_child || _journaled || _unknown || _directorySyncPending || _ownerRemovalPending) return NO;
  for (NSString *name in @[@"owner.json", @"network.json", @"network-dns.json"]) if (Exists([_directory stringByAppendingPathComponent:name])) return NO;
  return [self directoryProtected:NULL];
}
- (BOOL)directoryProtected:(NSString **)error {
  NSString *anchor = @"";
#if defined(KURO_TESTING) || defined(KURO_CORE_EXPERIMENT)
  anchor = _directory;
#endif
  return SafeChain(anchor, _directory, _owner, YES, error);
}
- (BOOL)onThread:(NSString **)error { return pthread_equal(_thread, pthread_self()) || Fail(error, @"session must be used on its owning serial thread"); }
- (BOOL)syncDirectory:(NSString **)error {
  int fd = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  BOOL ok = fd >= 0;
#ifdef KURO_TESTING
  if(self.fixtureFailDirectorySync)ok=NO;
#endif
  ok=ok && !fsync(fd);if(fd>=0)close(fd);
  _directorySyncPending=!ok;
  return ok || Fail(error, @"owner journal directory could not be synchronized");
}
- (BOOL)publishOwner:(NSDictionary *)record replacing:(NSData *)previous error:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"];
  if(![self directoryProtected:error] || ![ReadProtected(_directory,path,_owner,error)isEqual:previous])return Fail(error,@"owner receipt changed before checkpoint");
  NSString *temporary=[_directory stringByAppendingPathComponent:[@".owner-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!WriteNew(temporary,JSONData(record),0600,error))return NO;
  if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)) { unlink(temporary.fileSystemRepresentation);return Fail(error,@"owner checkpoint publish failed"); }
  _heldOwnerBytes=JSONData(record);
  return [self syncDirectory:error];
}
- (BOOL)prepareWorkCache:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || _workCacheInitial || ![self directoryProtected:error])return Fail(error,@"clean held context required for cache precreation");
  NSString *work=[_directory stringByAppendingPathComponent:@"session-work"],*path=[work stringByAppendingPathComponent:@"cache.db"];
  struct stat directory={0};
  if(!SafeChain(_directory,work,_owner,YES,error) || lstat(work.fileSystemRepresentation,&directory) || (directory.st_mode&07777)!=0700)return Fail(error,@"cache precreation requires fixed private work mode0700");
  int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  if(fd<0)return Fail(error,@"fixed cache precreation refused existing or inaccessible object; preserve work");
  struct stat created={0};BOOL ok=!fstat(fd,&created) && SafeMetadata(created,_owner,NO) && (created.st_mode&07777)==0600 && created.st_size==0;
  NSDictionary *initial=ok?KuroWorkCacheSnapshot(_directory,_owner,error):nil;
  ok=initial && [initial[@"device"]unsignedLongLongValue]==(uint64_t)created.st_dev && [initial[@"inode"]unsignedLongLongValue]==created.st_ino && !fsync(fd);
#ifdef KURO_TESTING
  if(self.fixtureFailWorkCacheSync)ok=NO;
#endif
  close(fd);
  int parent=ok?open(work.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
  ok=ok && parent>=0 && !fsync(parent);if(parent>=0)close(parent);
  if(!ok)return Fail(error,@"cache precreation identity or durable synchronization failed; preserve work");
  _workCacheInitial=initial;
  _workCacheOrigin=@{@"device":initial[@"device"],@"inode":initial[@"inode"],@"owner":@(_owner),@"mode":initial[@"mode"]};
  return YES;
}
- (BOOL)recordWorkSocket:(NSDictionary *)identity error:(NSString **)error {
  if(![self onThread:error] || !_child || !_journaled || _unknown || !Keys(identity,@[@"device",@"inode"]) || !KuroNumber(identity[@"device"],0,9007199254740991ULL) || !KuroNumber(identity[@"inode"],1,9007199254740991ULL))return Fail(error,@"held session and exact private socket identity required");
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"]; NSData *bytes=ReadProtected(_directory,path,_owner,error);
  NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if(!KuroRestartRecord(record,error) || ![record[@"format"]isEqual:@2] || ![record[@"session"]isEqual:_identifier] || ![record[@"pid"]isEqual:@(_child)])return Fail(error,@"private socket checkpoint has no matching work owner");
  if(record[@"work"][@"directory"] && ![KuroWorkDirectorySnapshot(_directory,_owner,error)isEqual:record[@"work"][@"directory"]])return Fail(error,@"private socket work directory differs from its owner receipt");
  id previous=record[@"work"][@"socket"];
  if(previous!=NSNull.null)return ([previous isEqual:identity] && [self syncDirectory:error]) || Fail(error,@"private socket differs from durable owner checkpoint or directory sync failed");
  NSMutableDictionary *updated=[record mutableCopy],*work=[record[@"work"]mutableCopy]; work[@"socket"]=[identity copy]; updated[@"work"]=work;
  return [self publishOwner:updated replacing:bytes error:error];
}
- (BOOL)recordReapedWorkCache:(NSDictionary *)identity error:(NSString **)error {
  // Only this instance's waitpid/reap transition can clear a journaled _child.
  // Fresh contexts and stored PIDs cannot authorize adopting a cache file.
  if(![self onThread:error] || _child || !_journaled || _unknown || !KuroWorkCacheReceipt(identity))return Fail(error,@"same reaped held session and closed cache identity required");
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"];NSData *bytes=ReadProtected(_directory,path,_owner,error);
  NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if(!KuroRestartRecord(record,error) || ![record[@"format"]isEqual:@2] || ![record[@"session"]isEqual:_identifier] || ![bytes isEqual:_heldOwnerBytes])return Fail(error,@"cache checkpoint has no matching held work owner");
  if(record[@"work"][@"directory"] && ![KuroWorkDirectorySnapshot(_directory,_owner,error)isEqual:record[@"work"][@"directory"]])return Fail(error,@"reaped cache work directory differs from its owner receipt");
  NSDictionary *origin=record[@"work"][@"cacheOrigin"];
  if(_workCacheOrigin || origin) {
    if(![origin isEqual:_workCacheOrigin] || !KuroWorkCacheMatchesOrigin(identity,origin,_owner))return Fail(error,@"reaped cache differs from precreated provenance; preserve work");
  }
  id previous=record[@"work"][@"cache"];
  if(previous)return ([previous isEqual:identity] && [self syncDirectory:error]) || Fail(error,@"cache differs from durable checkpoint or directory sync failed; preserve work");
  NSMutableDictionary *updated=[record mutableCopy],*work=[record[@"work"]mutableCopy];work[@"cache"]=[identity copy];updated[@"work"]=work;
  return [self publishOwner:updated replacing:bytes error:error];
}
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error {
  return [self recoverExitedOwnerWithNetwork:network writerValidator:nil workCleanup:workCleanup error:error];
}
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network writerValidator:(KuroRestartWriterValidator)validator workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error {
  return [self recoverExitedOwnerWithNetwork:network writerValidator:validator workCleanup:workCleanup beforeOwnerRemoval:nil error:error];
}
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network writerValidator:(KuroRestartWriterValidator)validator workCleanup:(KuroRestartWorkCleanup)workCleanup beforeOwnerRemoval:(KuroRestartEvidenceCheckpoint)checkpoint error:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || !network || !workCleanup || ![self directoryProtected:error])return Fail(error,@"fresh protected owner context and bounded recovery hooks required");
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"],*work=[_directory stringByAppendingPathComponent:@"session-work"];
  if(!Exists(path)) {
    if(Exists(work))return Fail(error,@"unrecorded Core work/ownership cannot be cleared");
    if(!network(error))return NO;
    if(![self syncDirectory:error])return NO;
    return self.off || Fail(error,@"residual network receipts remain");
  }
  __block NSData *bytes=ReadProtected(_directory,path,_owner,error); __block NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if(!KuroRestartRecord(record,error))return NO;
  if([record[@"format"]isEqual:@1] && Exists(work))return Fail(error,@"legacy owner lacks runtime/socket evidence; preserving Core work");
  KuroRestartReader reader=proc_pidinfo;KuroRestartGroupReader groupReader=proc_listpids;
#ifdef KURO_TESTING
  if(self.fixtureRestartReader)reader=self.fixtureRestartReader;
  if(self.fixtureRestartGroupReader)groupReader=self.fixtureRestartGroupReader;
#endif
  __block BOOL cacheCheckpoint=record[@"work"][@"cacheCheckpoint"]!=nil;
  __block BOOL workGone=!Exists(work);
  KuroSessionHook stillAbsent=^BOOL(NSString **failure) {
    NSDictionary *expected=record[@"work"][@"directory"];
    if(expected) {
      if(Exists(work)) {
        if(workGone || ![KuroWorkDirectorySnapshot(self->_directory,self->_owner,failure)isEqual:expected])return Fail(failure,@"recorded work directory was replaced or reappeared; preserve all objects");
      } else workGone=YES;
    }
    return [self directoryProtected:failure] && [ReadProtected(self->_directory,path,self->_owner,failure)isEqual:bytes] && KuroRestartAbsent(record,reader,failure) && KuroRestartSupervisorAbsent(record,reader,failure) && KuroRestartGroupEmpty(record,groupReader,failure) && (!record[@"supervision"][@"installation"] || (validator && validator(record,failure)) || Fail(failure,@"installed recovery requires its explicit internal writer validator"));
  };
  // Sample twice before invoking even a receipt-only network cleanup.
  if(!stillAbsent(error) || !stillAbsent(error) || !(self.recoveredNetwork?self.recoveredNetwork(record,stillAbsent,error):network(error)) || !stillAbsent(error))return NO;
  NSString *cache=[work stringByAppendingPathComponent:@"cache.db"];
  NSDictionary *origin=record[@"work"][@"cacheOrigin"];
  if(Exists(cache) && origin && !record[@"work"][@"cache"]) {
    if(!validator || !record[@"supervision"][@"installation"])return Fail(error,@"origin-only cache requires an explicit installed writer validator; preserve work");
    NSDictionary *first=KuroWorkCacheSnapshot(_directory,_owner,error);
    if(!first || !KuroWorkCacheMatchesOrigin(first,origin,_owner) || !validator(record,error) || !stillAbsent(error))return Fail(error,@"origin-only cache writer or identity is not confirmed; preserve work");
    NSDictionary *second=KuroWorkCacheSnapshot(_directory,_owner,error);
    if(![first isEqual:second])return Fail(error,@"origin-only cache changed while validating writer exit; preserve work");
    int descriptor=open(cache.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);struct stat held={0};
    BOOL stable=descriptor>=0 && !fstat(descriptor,&held) && SafeMetadata(held,_owner,NO) && (uint64_t)held.st_dev==[first[@"device"]unsignedLongLongValue] && held.st_ino==[first[@"inode"]unsignedLongLongValue] && !fsync(descriptor);
    if(descriptor>=0)close(descriptor);
    if(!stable || ![KuroWorkCacheSnapshot(_directory,_owner,error)isEqual:first] || !stillAbsent(error))return Fail(error,@"origin-only cache stable synchronization failed; preserve work");
    NSMutableDictionary *updated=[record mutableCopy],*receipt=[record[@"work"]mutableCopy];
    receipt[@"cache"]=first;receipt[@"cacheCheckpoint"]=@"validated-restart-v1";updated[@"work"]=receipt;
#ifdef KURO_TESTING
    if(self.fixtureFailOwnerPublish)return Fail(error,@"injected restart owner publish refusal");
#endif
    if(!KuroRestartRecord(updated,error) || ![self publishOwner:updated replacing:bytes error:error])return NO;
    bytes=JSONData(updated);record=KuroDecodeJSON(bytes,MessageLimit,error);cacheCheckpoint=YES;
  }
  // A renamed checkpoint from a failed prior attempt must be revalidated and synced.
  if(cacheCheckpoint && (!stillAbsent(error) || ![self syncDirectory:error]))return NO;
  if(!workCleanup(record,stillAbsent,error) || !stillAbsent(error))return NO;
  if(Exists(work) || Exists([_directory stringByAppendingPathComponent:@"network.json"]) || Exists([_directory stringByAppendingPathComponent:@"network-dns.json"]))return Fail(error,@"old Core/network footprint remains; preserving owner receipt");
  // This fresh checkpoint records observed fixed-writer recovery, never held reap.
  if(checkpoint && !checkpoint(record,bytes,stillAbsent,error))return NO;
  if(checkpoint && (!stillAbsent(error) || Exists(work) || Exists([_directory stringByAppendingPathComponent:@"network.json"]) || Exists([_directory stringByAppendingPathComponent:@"network-dns.json"])))return Fail(error,@"ownership/work/network changed after recovered checkpoint; preserve owner");
#ifdef KURO_TESTING
  if(self.fixtureFailOwnerUnlink)return Fail(error,@"injected recovered owner unlink refusal");
#endif
  if(unlink(path.fileSystemRepresentation) || ![self syncDirectory:error])return Fail(error,@"old Core owner absence receipt removal was not durable");
  return self.off || Fail(error,@"old Core recovery did not establish off");
}
- (NSDictionary *)completedStopEvidence:(NSString **)error {
  if(![self onThread:error] || !_reapedOwnedChild || !KuroCompletedStopEvidence(_completedStop) || !self.off || Exists([_directory stringByAppendingPathComponent:@"session-work"])) {
    Fail(error,@"same held/reaped session and durable complete cleanup are required; no proof from absent receipts");return nil;
  }
  return [_completedStop copy];
}
- (BOOL)setLaunchEvidence:(NSDictionary *)evidence error:(NSString **)error {
  if (![self onThread:error] || _child || _journaled || _unknown) return Fail(error, @"cannot replace active launch evidence");
  if (!KuroMapping(evidence, @[@"configSHA256", @"coreSHA256", @"template"], @[@"runtimeSHA256"]) ||
      !Match(evidence[@"configSHA256"], @"\\A[0-9a-f]{64}\\z") || !Match(evidence[@"coreSHA256"], @"\\A[0-9a-f]{64}\\z") ||
      !KuroSessionTemplate(evidence[@"template"]) || (evidence[@"runtimeSHA256"] && !Match(evidence[@"runtimeSHA256"], @"\\A[0-9a-f]{64}\\z"))) return Fail(error, @"invalid fixed launch evidence");
  _launchEvidence = [evidence copy]; return YES;
}
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error {
  return [self spawnExecutable:executable arguments:arguments workingDirectory:nil beforeResume:prepare afterReap:cleanup error:error];
}
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error {
  return [self spawnExecutable:executable arguments:arguments workingDirectory:workingDirectory beforeResume:prepare afterReap:cleanup resumeGate:nil error:error];
}
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup resumeGate:(KuroSessionResumeGate)resumeGate error:(NSString **)error {
  if (![self onThread:error]) return NO;
  BOOL captureRequired=workingDirectory!=nil;
#ifdef KURO_CORE_EXPERIMENT
  captureRequired=YES;
#endif
  if(captureRequired && !KuroCaptureWriters(_stdoutDescriptor,_stderrDescriptor,error))return NO;
  if (_child || _journaled || _unknown || !prepare || !cleanup) return Fail(error, @"session is not clean or lifecycle hooks are absent");
  // No resume from a persisted PID: only this process's unreaped direct child is owned.
  NSString *journal = [_directory stringByAppendingPathComponent:@"owner.json"];
  if (![self directoryProtected:error] || !self.off || Exists(journal)) return Fail(error, @"protected clean owner directory is required");
  NSString *launchAnchor = @"";
#if defined(KURO_TESTING) || defined(KURO_CORE_EXPERIMENT)
  launchAnchor = _directory;
#endif
  NSData *bytes = ReadProtected(launchAnchor, executable, _owner, error);
  // Test fixtures use the ordinary user's protected executable; production root
  // launch requires root-owned fixed Core and validated config at its caller.
  if (!bytes || !executable.isAbsolutePath || arguments.count > 32) return Fail(error, @"protected executable is required");
  NSDictionary *supervision=nil;
  if(_supervisionSource) {
    if(!workingDirectory || !_launchEvidence)return Fail(error,@"supervision requires a versioned fixed launch/work receipt before spawn");
    supervision=_initialSupervision;
    if(!KuroSupervisionEvidence(supervision) || !workingDirectory || getpgrp()!=getpid())return Fail(error,@"fixed launchd supervision could not be established before spawn");
  }
#if !defined(KURO_TESTING) && !defined(KURO_CORE_EXPERIMENT)
  else return Fail(error,@"production Core requires fixed launchd supervision provenance");
#endif
  _identifier = NSUUID.UUID.UUIDString;
  char *argv[34] = {0}; argv[0] = (char *)executable.fileSystemRepresentation;
  for (NSUInteger i = 0; i < arguments.count; i++) {
    if (![arguments[i] isKindOfClass:NSString.class] || [arguments[i] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != strlen([arguments[i] UTF8String])) return Fail(error, @"invalid native launch argument");
    argv[i + 1] = (char *)arguments[i].UTF8String;
  }
  posix_spawnattr_t attr; posix_spawn_file_actions_t actions;
  if (posix_spawnattr_init(&attr)) return Fail(error, @"spawn attributes unavailable");
  if (posix_spawn_file_actions_init(&actions)) { posix_spawnattr_destroy(&attr); return Fail(error, @"spawn file actions unavailable"); }
  sigset_t empty, defaults; sigemptyset(&empty); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE);
  int setup = posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
  setup |= posix_spawnattr_setsigmask(&attr, &empty); setup |= posix_spawnattr_setsigdefault(&attr, &defaults);
  for (int descriptor = 0; descriptor < 3; descriptor++) {
    int captured=descriptor==1?_stdoutDescriptor:descriptor==2?_stderrDescriptor:0;
    if(captureRequired && captured>3) {setup|=posix_spawn_file_actions_adddup2(&actions,captured,descriptor);continue;}
    setup|=posix_spawn_file_actions_addopen(&actions,descriptor,"/dev/null",descriptor?O_WRONLY:O_RDONLY,0);
  }
  if (workingDirectory) {
    if (![workingDirectory isEqual:[_directory stringByAppendingPathComponent:@"session-work"]] || !SafeChain(_directory, workingDirectory, _owner, YES, error)) setup = EINVAL;
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      // The _np spelling also supports macOS releases older than SDK 26.
      setup |= posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.fileSystemRepresentation);
#pragma clang diagnostic pop
    }
  }
  NSDictionary *workDirectory=workingDirectory?KuroWorkDirectorySnapshot(_directory,_owner,error):nil;
  if(workingDirectory && !workDirectory)setup=EINVAL;
  // Fixed mihomo otherwise drops inet6-address when the host has no existing
  // global IPv6 address. Our owned internal dual-stack utun is verified after
  // resume; this switch does not claim physical IPv6 connectivity.
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", "SKIP_SYSTEM_IPV6_CHECK=true", NULL};
  _terminationRequest=nil;_terminationEvidence=nil;_stopContext=nil;
  int spawned = setup ? setup : posix_spawn(&_child, executable.fileSystemRepresentation, &actions, &attr, argv, environment);
  posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
  if (spawned) { _child = 0; return Fail(error, @"owned child spawn failed"); }
  struct proc_bsdinfo process = {0};
  BOOL known = proc_pidinfo(_child, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) == sizeof(process) && process.pbi_ppid == (uint32_t)getpid() && process.pbi_pgid == (uint32_t)getpgrp();
  NSMutableDictionary *record = [@{ @"format":@1, @"session":_identifier, @"pid":@(_child), @"parent":@(getpid()), @"startSeconds":@(process.pbi_start_tvsec), @"startMicros":@(process.pbi_start_tvusec), @"executableSHA256":Hash(bytes), @"phase":@"prepared", @"processGroup":@(process.pbi_pgid) } mutableCopy];
  if (_launchEvidence) record[@"launch"] = _launchEvidence;
  if(workingDirectory) {
    NSData *configuration=ReadProtected(_directory,[workingDirectory stringByAppendingPathComponent:@"config.json"],_owner,error);
    if(configuration && _launchEvidence && [KuroWorkDirectorySnapshot(_directory,_owner,error)isEqual:workDirectory]) {
      record[@"format"]=@2;NSMutableDictionary *work=[@{@"configSHA256":Hash(configuration),@"socket":NSNull.null,@"directory":workDirectory}mutableCopy];
      if(_workCacheOrigin)work[@"cacheOrigin"]=_workCacheOrigin;
      record[@"work"]=work;
    }
    else known=NO;
  }

  if(supervision) {
    NSDictionary *current=_supervisionSource(error);
    known=known && KuroSupervisionEvidence(current) && [supervision isEqual:current];
    record[@"supervision"]=supervision;
  }
  if(supervision[@"installation"])known=known && KuroRestartRecord(record,error);
  _reapedOwnedChild=0; _completedStop=nil;
  _cleanup = [cleanup copy];
  // Mark uncertainty before creating the journal, including partial-write failures.
  _journaled = YES;
  _heldOwnerBytes=JSONData(record);
  BOOL publishAllowed=YES;
#ifdef KURO_TESTING
  publishAllowed=!self.fixtureFailOwnerPublish;
#endif
  BOOL ready = known && publishAllowed && WriteNew(journal, _heldOwnerBytes, 0600, error) && [self syncDirectory:error] && prepare(error);
  if (!ready) { NSString *ignored = nil; [self stop:&ignored]; return Fail(error, @"owner preparation failed; child was never resumed (cleanup status must be inspected)"); }
  __block BOOL resumed=NO;
  KuroSessionHook resume=^BOOL(NSString **problem) {
    if(resumed)return Fail(problem,@"owned child resume may run only once");
    if(supervision) {
      NSDictionary *current=self->_supervisionSource(problem);
      if(!KuroSupervisionEvidence(current) || ![supervision isEqual:current])return Fail(problem,@"fixed launchd supervision changed before Core resume");
    }
    if(workDirectory && ![KuroWorkDirectorySnapshot(self->_directory,self->_owner,problem)isEqual:workDirectory])return Fail(problem,@"fixed work directory changed before Core resume");
    if(self->_workCacheOrigin && ![KuroWorkCacheSnapshot(self->_directory,self->_owner,problem)isEqual:self->_workCacheInitial])return Fail(problem,@"precreated cache changed before Core resume; preserve work");
    if(kill(self->_child,SIGCONT))return Fail(problem,@"owned child could not be resumed");
    resumed=YES; return YES;
  };
  BOOL permitted=resumeGate ? resumeGate(resume,error) : resume(error);
  if(!permitted || !resumed) { NSString *ignored=nil; [self stop:&ignored]; return Fail(error,@"owned child resume refused; cleanup status must be inspected"); }
  return YES;
}
- (BOOL)reapUntil:(uint64_t)deadline error:(NSString **)error {
  while (_child) {
    int status=0;pid_t result = waitpid(_child, &status, WNOHANG);
    if (result == _child) {
      _reapedOwnedChild=_child;
      _terminationEvidence=@{@"request":_terminationRequest ?: @"none",@"observed":@YES,@"exitCode":WIFEXITED(status)?@(WEXITSTATUS(status)):NSNull.null,@"signal":WIFSIGNALED(status)?@(WTERMSIG(status)):NSNull.null};
      _child = 0; return YES;
    }
    if (result < 0 && errno != EINTR) { _unknown = YES; return Fail(error, @"direct child ownership was lost; refusing PID-based cleanup"); }
    if (KuroMonotonicMilliseconds() >= deadline) return NO;
    struct timespec pause = {.tv_nsec = 5000000}; nanosleep(&pause, NULL);
  }
  return YES;
}
- (BOOL)heldCleanupCanRetry {
  return [self onThread:NULL] && _journaled && !_unknown && !_child && _reapedOwnedChild>0;
}
- (BOOL)setBeforeOwnerRemoval:(KuroSessionStopEvidenceCheckpoint)checkpoint error:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || !checkpoint)return Fail(error,@"clean session and internal held-stop checkpoint required");
  _beforeOwnerRemoval=[checkpoint copy];return YES;
}
- (BOOL)stop:(NSString **)error {
  if (![self onThread:error]) return NO;
  if (_unknown) return Fail(error, @"session ownership is unknown");
  if (_child) {
    // Check/reap first. An unreaped child cannot have its PID reused; no other
    // component may waitpid this child. ECHILD above never leads to kill(pid).
    [self reapUntil:KuroMonotonicMilliseconds() error:error];
    if (_unknown) return NO;
    if (_child) {
      _terminationRequest=@"SIGTERM";
      if (kill(_child, SIGTERM) && errno != ESRCH) return Fail(error, @"owned child termination failed");
    }
    if (_child && ![self reapUntil:KuroMonotonicMilliseconds() + 150 error:error]) {
      if (_unknown) return NO;
      _terminationRequest=@"SIGKILL";
      if (kill(_child, SIGKILL) && errno != ESRCH) return Fail(error, @"owned child forced termination failed");
      if (![self reapUntil:KuroMonotonicMilliseconds() + 1000 error:error]) return Fail(error, @"owned child has not been reaped");
    }
  }
  if(_ownerRemovalPending) {
    // Only the original held/reaped cleanup may retry its own successful unlink.
    for(NSString *name in @[@"owner.json",@"session-work",@"network.json",@"network-dns.json"])
      if(Exists([_directory stringByAppendingPathComponent:name]))return Fail(error,@"post-unlink owner/work/network footprint appeared; preserving uncertain cleanup");
    if(![self directoryProtected:error] || ![self syncDirectory:error])return NO;
    _ownerRemovalPending=NO;_journaled=NO;_cleanup=nil;
  }
  if (_journaled) {
    NSString *heldPath=[_directory stringByAppendingPathComponent:@"owner.json"];
    if(!_heldOwnerBytes || ![ReadProtected(_directory,heldPath,_owner,error)isEqual:_heldOwnerBytes])return Fail(error,@"held owner journal changed; network cleanup refused");
    if (!_cleanup || !_cleanup(error)) return Fail(error, @"child reaped but network restoration is not proven");
    NSString *path = [_directory stringByAppendingPathComponent:@"owner.json"];
    NSData *bytes=ReadProtected(_directory,path,_owner,error);
    NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
    if (![record[@"session"] isEqual:_identifier]) return Fail(error, @"owner journal is incomplete or belongs to another session");
    NSDictionary *completed=nil;
    if(_reapedOwnedChild && [record[@"pid"]intValue]==_reapedOwnedChild && KuroRestartRecord(record,NULL))
      completed=@{@"format":@1,@"session":_identifier,@"owner":record,@"ownerSHA256":Hash(bytes),@"childReaped":@YES,@"cleanupComplete":@YES};
    // Persist genuine held/reaped evidence while the exact owner still survives.
    // Consumers must continue to refuse the remaining owner footprint.
    if(_beforeOwnerRemoval && (!completed || !_beforeOwnerRemoval(completed,error)))return Fail(error,@"held-stop checkpoint is not durable; owner preserved");
#ifdef KURO_TESTING
    if(self.fixtureFailOwnerUnlink)return Fail(error,@"injected owner unlink failure; held proof and owner preserved");
#endif
    if(![ReadProtected(_directory,path,_owner,error)isEqual:bytes] || unlink(path.fileSystemRepresentation))return Fail(error,@"owner journal removal is not durable");
    _ownerRemovalPending=YES;_completedStop=completed;
    if(![self syncDirectory:error])return Fail(error,@"owner journal removal is not durable");
    _ownerRemovalPending=NO;_journaled=NO;_cleanup=nil;
  }
  if(_directorySyncPending && ![self syncDirectory:error])return NO;
  return YES;
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid error:(NSString **)error {
  return [self superviseSocket:socket leaseMilliseconds:lease identityValid:identityValid tick:nil error:error];
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick error:(NSString **)error {
  return [self superviseSocket:socket leaseMilliseconds:lease identityValid:identityValid tick:tick stopConfirmed:nil error:error];
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopConfirmed:(void (^)(void))stopConfirmed error:(NSString **)error {
  KuroSessionHook checkpoint=stopConfirmed?^BOOL(NSString **failure) { (void)failure;stopConfirmed();return YES; }:nil;
  return [self superviseSocket:socket leaseMilliseconds:lease identityValid:identityValid tick:tick stopCheckpoint:checkpoint error:error];
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopCheckpoint:(KuroSessionHook)stopCheckpoint error:(NSString **)error {
  if (![self onThread:error]) return NO;
  if (!_child || !_journaled || !identityValid || lease < 50 || lease > 30000) {
    _stopContext=@{@"reason":@"invalid authenticated session lease",@"unexpected":@YES};
    NSString *ignored = nil; [self stop:&ignored];
    return Fail(error, @"invalid authenticated session lease; owned child stop attempted");
  }
#ifdef KURO_CORE_EXPERIMENT
  _experimentStopTrigger=KuroExperimentStopUnexpected;_experimentStopAcknowledged=NO;
#endif
  uint64_t deadline = KuroMonotonicMilliseconds() + lease, sequence = 1;
  NSMutableData *buffer = [NSMutableData data]; NSString *reason = @"session closed";BOOL unexpected=YES;
  for (;;) {
    if (!identityValid()) { reason = @"authenticated client identity exited or changed"; break; }
    if (tick && !tick(error)) { reason = @"session owner requested stop or control gate failed"; break; }
    if ([self reapUntil:KuroMonotonicMilliseconds() error:error] || _unknown) { reason = @"owned child exited"; break; }
    uint64_t now = KuroMonotonicMilliseconds(); if (now >= deadline) { reason = @"authenticated session lease expired"; break; }
    struct pollfd descriptor = {.fd = socket, .events = POLLIN};
    int result = poll(&descriptor, 1, (int)MIN(deadline - now, 50));
    if (result < 0 && errno == EINTR) continue;
    if (result < 0 || (descriptor.revents & (POLLERR | POLLNVAL))) { reason = @"session socket failed"; break; }
    if (!result) continue;
    unsigned char bytes[4096]; ssize_t count = recv(socket, bytes, sizeof(bytes), MSG_DONTWAIT);
    if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
    if (count <= 0) {
      if(count==0)unexpected=NO;
#ifdef KURO_CORE_EXPERIMENT
      if(count==0)_experimentStopTrigger=KuroExperimentStopOwnerEOF;
#endif
      break;
    }
    [buffer appendBytes:bytes length:(NSUInteger)count];
    if (buffer.length > MessageLimit) { reason = @"session frame exceeds limit"; break; }
    const unsigned char *start = buffer.bytes; const unsigned char *newline = memchr(start, '\n', buffer.length);
    if (!newline) continue;
    // One outstanding heartbeat, exact finite grammar; session IDs are not bearer
    // credentials. No paths, commands or arbitrary Core API enter this channel.
    NSData *frame = [NSData dataWithBytes:start length:(NSUInteger)(newline - start)];
    id message = KuroDecodeJSON(frame, MessageLimit, NULL);
    BOOL valid = Keys(message, @[@"version", @"operation", @"session", @"sequence"]) && KuroNumber(message[@"version"], 2, 2) &&
      [message[@"session"] isEqual:_identifier] && KuroNumber(message[@"sequence"], 1, 9007199254740991ULL) && [message[@"sequence"] unsignedLongLongValue] == sequence;
    if (!valid || (![[message objectForKey:@"operation"] isEqual:@"heartbeat"] && ![[message objectForKey:@"operation"] isEqual:@"stop"])) { reason = @"invalid session frame or sequence"; break; }
    NSUInteger consumed = (NSUInteger)(newline - start) + 1;
    if (consumed != buffer.length || sequence == 9007199254740991ULL) { reason = @"pipelined session frame refused"; break; }
    if ([message[@"operation"] isEqual:@"stop"]) {
#ifdef KURO_CORE_EXPERIMENT
      _experimentStopTrigger=KuroExperimentStopOwnerRequest;
#endif
      _stopContext=@{@"reason":@"authenticated owner requested stop",@"unexpected":@NO};
      BOOL stopped = [self stop:error] && self.off;
      // Publish proven off before the client can receive its stop acknowledgement.
      if (stopped && stopCheckpoint && !stopCheckpoint(error)) stopped=NO;
      NSDictionary *reply = stopped ? @{@"version":@2,@"ok":@YES,@"sequence":@(sequence),@"status":@{@"availability":@"ready",@"state":@"off"}} : @{@"version":@2,@"ok":@NO,@"error":(error && *error) ? *error : @"cleanup is not proven"};
      NSMutableData *encoded = [JSONData(reply) mutableCopy]; [encoded appendBytes:"\n" length:1];
#ifdef KURO_CORE_EXPERIMENT
      _experimentStopAcknowledged=send(socket,encoded.bytes,encoded.length,MSG_NOSIGNAL|MSG_DONTWAIT)==(ssize_t)encoded.length && stopped;
#else
      (void)send(socket, encoded.bytes, encoded.length, MSG_NOSIGNAL | MSG_DONTWAIT);
#endif
      return stopped;
    }
    [buffer setLength:0]; sequence++; deadline = KuroMonotonicMilliseconds() + lease;
    NSString *reply = [NSString stringWithFormat:@"{\"version\":2,\"ok\":true,\"sequence\":%llu}\n", (unsigned long long)(sequence - 1)];
    const char *replyBytes = reply.UTF8String; size_t length = strlen(replyBytes);
    if (send(socket, replyBytes, length, MSG_NOSIGNAL | MSG_DONTWAIT) != (ssize_t)length) { reason = @"session acknowledgement failed"; break; }
  }
  _stopContext=@{@"reason":(unexpected&&error&&*error)?*error:reason,@"unexpected":@(unexpected)};
  BOOL stopped = [self stop:error] && self.off;
  if (stopped && stopCheckpoint && !stopCheckpoint(error)) stopped=NO;
  if (stopped && error) *error = reason;
  return stopped;
}
@end
