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
typedef BOOL (^KuroSessionResumeGate)(KuroSessionHook resume, NSString **error);
typedef int (*KuroRestartReader)(int,int,uint64_t,void *,int);
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
static BOOL KuroRestartRecord(NSDictionary *record,NSString **error) {
  NSArray *base=@[@"format",@"session",@"pid",@"parent",@"startSeconds",@"startMicros",@"executableSHA256",@"phase",@"processGroup"];
  if(!KuroMapping(record,base,@[@"launch",@"work"]) || !KuroNumber(record[@"format"],1,2) || !KuroNumber(record[@"pid"],1,INT_MAX) || !KuroNumber(record[@"parent"],1,INT_MAX) ||
    !KuroNumber(record[@"startSeconds"],1,9007199254740991ULL) || !KuroNumber(record[@"startMicros"],0,999999) || !KuroNumber(record[@"processGroup"],1,INT_MAX) ||
    !Match(record[@"executableSHA256"],@"\\A[0-9a-f]{64}\\z") || ![record[@"phase"]isEqual:@"prepared"] || ![record[@"session"]isKindOfClass:NSString.class])return Fail(error,@"invalid closed old Core owner receipt");
  NSUUID *session=[[NSUUID alloc]initWithUUIDString:record[@"session"]]; if(!session || ![session.UUIDString isEqual:record[@"session"]])return Fail(error,@"invalid old Core owner session");
  NSDictionary *launch=record[@"launch"];
  if(launch && (!Keys(launch,@[@"configSHA256",@"coreSHA256",@"template"]) || !Match(launch[@"configSHA256"],@"\\A[0-9a-f]{64}\\z") || ![launch[@"coreSHA256"]isEqual:record[@"executableSHA256"]] || ![launch[@"template"]isEqual:@"macos-dual-stack-v1"]))return Fail(error,@"old Core launch evidence does not match its owner");
  NSDictionary *work=record[@"work"];
  if([record[@"format"]isEqual:@1])return !work || Fail(error,@"legacy owner cannot carry unversioned work evidence");
  if(!launch || !Keys(work,@[@"configSHA256",@"socket"]) || !Match(work[@"configSHA256"],@"\\A[0-9a-f]{64}\\z"))return Fail(error,@"old Core work receipt is incomplete");
  id socket=work[@"socket"];
  return socket==NSNull.null || (Keys(socket,@[@"device",@"inode"]) && KuroNumber(socket[@"device"],0,9007199254740991ULL) && KuroNumber(socket[@"inode"],1,9007199254740991ULL)) || Fail(error,@"old Core socket receipt is invalid");
}
@interface KuroOwnedSession : NSObject {
  pid_t _child;
  pthread_t _thread;
  NSString *_directory;
  NSString *_identifier;
  uid_t _owner;
  BOOL _journaled;
  BOOL _unknown;
  KuroSessionHook _cleanup;
  NSDictionary *_launchEvidence;
}
@property(nonatomic, readonly) pid_t child;
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) BOOL off;
#ifdef KURO_TESTING
@property(nonatomic) KuroRestartReader fixtureRestartReader;
#endif
- (BOOL)recordWorkSocket:(NSDictionary *)identity error:(NSString **)error;
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error;

- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error;
- (BOOL)setLaunchEvidence:(NSDictionary *)evidence error:(NSString **)error;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments workingDirectory:(NSString *)workingDirectory beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup resumeGate:(KuroSessionResumeGate)resumeGate error:(NSString **)error;
- (BOOL)stop:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid error:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick error:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopConfirmed:(void (^)(void))stopConfirmed error:(NSString **)error;
@end
@implementation KuroOwnedSession
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner {
  if ((self = [super init])) { _directory = [directory copy]; _owner = owner; _thread = pthread_self(); _identifier = NSUUID.UUID.UUIDString; }
  return self;
}
- (pid_t)child { return _child; }
- (NSString *)identifier { return _identifier; }
- (BOOL)off {
  if (_child || _journaled || _unknown) return NO;
  for (NSString *name in @[@"owner.json", @"network.json", @"network-dns.json"]) if (Exists([_directory stringByAppendingPathComponent:name])) return NO;
  return [self directoryProtected:NULL];
}
- (BOOL)directoryProtected:(NSString **)error {
  NSString *anchor = @"";
#ifdef KURO_TESTING
  anchor = _directory;
#endif
  return SafeChain(anchor, _directory, _owner, YES, error);
}
- (BOOL)onThread:(NSString **)error { return pthread_equal(_thread, pthread_self()) || Fail(error, @"session must be used on its owning serial thread"); }
- (BOOL)syncDirectory:(NSString **)error {
  int fd = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  BOOL ok = fd >= 0 && !fsync(fd); if (fd >= 0) close(fd);
  return ok || Fail(error, @"owner journal directory could not be synchronized");
}
- (BOOL)publishOwner:(NSDictionary *)record replacing:(NSData *)previous error:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"];
  if(![self directoryProtected:error] || ![ReadProtected(_directory,path,_owner,error)isEqual:previous])return Fail(error,@"owner receipt changed before checkpoint");
  NSString *temporary=[_directory stringByAppendingPathComponent:[@".owner-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!WriteNew(temporary,JSONData(record),0600,error))return NO;
  if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)) { unlink(temporary.fileSystemRepresentation);return Fail(error,@"owner checkpoint publish failed"); }
  return [self syncDirectory:error];
}
- (BOOL)recordWorkSocket:(NSDictionary *)identity error:(NSString **)error {
  if(![self onThread:error] || !_child || !_journaled || _unknown || !Keys(identity,@[@"device",@"inode"]) || !KuroNumber(identity[@"device"],0,9007199254740991ULL) || !KuroNumber(identity[@"inode"],1,9007199254740991ULL))return Fail(error,@"held session and exact private socket identity required");
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"]; NSData *bytes=ReadProtected(_directory,path,_owner,error);
  NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if(!KuroRestartRecord(record,error) || ![record[@"format"]isEqual:@2] || ![record[@"session"]isEqual:_identifier] || ![record[@"pid"]isEqual:@(_child)])return Fail(error,@"private socket checkpoint has no matching work owner");
  id previous=record[@"work"][@"socket"];
  if(previous!=NSNull.null)return [previous isEqual:identity] || Fail(error,@"private socket differs from durable owner checkpoint");
  NSMutableDictionary *updated=[record mutableCopy],*work=[record[@"work"]mutableCopy]; work[@"socket"]=[identity copy]; updated[@"work"]=work;
  return [self publishOwner:updated replacing:bytes error:error];
}
- (BOOL)recoverExitedOwnerWithNetwork:(KuroSessionHook)network workCleanup:(KuroRestartWorkCleanup)workCleanup error:(NSString **)error {
  if(![self onThread:error] || _child || _journaled || _unknown || !network || !workCleanup || ![self directoryProtected:error])return Fail(error,@"fresh protected owner context and bounded recovery hooks required");
  NSString *path=[_directory stringByAppendingPathComponent:@"owner.json"],*work=[_directory stringByAppendingPathComponent:@"session-work"];
  if(!Exists(path)) {
    if(Exists(work))return Fail(error,@"unrecorded Core work/ownership cannot be cleared");
    if(!network(error))return NO;
    return self.off || Fail(error,@"residual network receipts remain");
  }
  NSData *bytes=ReadProtected(_directory,path,_owner,error); NSDictionary *record=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if(!KuroRestartRecord(record,error))return NO;
  if([record[@"format"]isEqual:@1] && Exists(work))return Fail(error,@"legacy owner lacks runtime/socket evidence; preserving Core work");
  KuroRestartReader reader=proc_pidinfo;
#ifdef KURO_TESTING
  if(self.fixtureRestartReader)reader=self.fixtureRestartReader;
#endif
  KuroSessionHook stillAbsent=^BOOL(NSString **failure) {
    return [self directoryProtected:failure] && [ReadProtected(self->_directory,path,self->_owner,failure)isEqual:bytes] && KuroRestartAbsent(record,reader,failure);
  };
  // Sample twice before invoking even a receipt-only network cleanup.
  if(!stillAbsent(error) || !stillAbsent(error) || !network(error) || !stillAbsent(error) || !workCleanup(record,stillAbsent,error) || !stillAbsent(error))return NO;
  if(Exists(work) || Exists([_directory stringByAppendingPathComponent:@"network.json"]) || Exists([_directory stringByAppendingPathComponent:@"network-dns.json"]))return Fail(error,@"old Core/network footprint remains; preserving owner receipt");
  if(unlink(path.fileSystemRepresentation) || ![self syncDirectory:error])return Fail(error,@"old Core owner absence receipt removal was not durable");
  return self.off || Fail(error,@"old Core recovery did not establish off");
}
- (BOOL)setLaunchEvidence:(NSDictionary *)evidence error:(NSString **)error {
  if (![self onThread:error] || _child || _journaled || _unknown) return Fail(error, @"cannot replace active launch evidence");
  if (!Keys(evidence, @[@"configSHA256", @"coreSHA256", @"template"]) ||
      !Match(evidence[@"configSHA256"], @"\\A[0-9a-f]{64}\\z") || !Match(evidence[@"coreSHA256"], @"\\A[0-9a-f]{64}\\z") ||
      ![evidence[@"template"] isEqual:@"macos-dual-stack-v1"]) return Fail(error, @"invalid fixed launch evidence");
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
  if (_child || _journaled || _unknown || !prepare || !cleanup) return Fail(error, @"session is not clean or lifecycle hooks are absent");
  // No resume from a persisted PID: only this process's unreaped direct child is owned.
  NSString *journal = [_directory stringByAppendingPathComponent:@"owner.json"];
  if (![self directoryProtected:error] || !self.off || Exists(journal)) return Fail(error, @"protected clean owner directory is required");
  NSString *launchAnchor = @"";
#ifdef KURO_TESTING
  launchAnchor = _directory;
#endif
  NSData *bytes = ReadProtected(launchAnchor, executable, _owner, error);
  // Test fixtures use the ordinary user's protected executable; production root
  // launch requires root-owned fixed Core and validated config at its caller.
  if (!bytes || !executable.isAbsolutePath || arguments.count > 32) return Fail(error, @"protected executable is required");
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
  for (int descriptor = 0; descriptor < 3; descriptor++) setup |= posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor ? O_WRONLY : O_RDONLY, 0);
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
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
  int spawned = setup ? setup : posix_spawn(&_child, executable.fileSystemRepresentation, &actions, &attr, argv, environment);
  posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
  if (spawned) { _child = 0; return Fail(error, @"owned child spawn failed"); }
  struct proc_bsdinfo process = {0};
  BOOL known = proc_pidinfo(_child, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) == sizeof(process) && process.pbi_ppid == (uint32_t)getpid() && process.pbi_pgid == (uint32_t)getpgrp();
  NSMutableDictionary *record = [@{ @"format":@1, @"session":_identifier, @"pid":@(_child), @"parent":@(getpid()), @"startSeconds":@(process.pbi_start_tvsec), @"startMicros":@(process.pbi_start_tvusec), @"executableSHA256":Hash(bytes), @"phase":@"prepared", @"processGroup":@(process.pbi_pgid) } mutableCopy];
  if (_launchEvidence) record[@"launch"] = _launchEvidence;
  if(workingDirectory) {
    NSData *configuration=ReadProtected(_directory,[workingDirectory stringByAppendingPathComponent:@"config.json"],_owner,error);
    if(configuration && _launchEvidence) { record[@"format"]=@2; record[@"work"]=@{@"configSHA256":Hash(configuration),@"socket":NSNull.null}; }
    else known=NO;
  }

  _cleanup = [cleanup copy];
  // Mark uncertainty before creating the journal, including partial-write failures.
  _journaled = YES;
  BOOL ready = known && WriteNew(journal, JSONData(record), 0600, error) && [self syncDirectory:error] && prepare(error);
  if (!ready) { NSString *ignored = nil; [self stop:&ignored]; return Fail(error, @"owner preparation failed; child was never resumed (cleanup status must be inspected)"); }
  __block BOOL resumed=NO;
  KuroSessionHook resume=^BOOL(NSString **problem) {
    if(resumed)return Fail(problem,@"owned child resume may run only once");
    if(kill(self->_child,SIGCONT))return Fail(problem,@"owned child could not be resumed");
    resumed=YES; return YES;
  };
  BOOL permitted=resumeGate ? resumeGate(resume,error) : resume(error);
  if(!permitted || !resumed) { NSString *ignored=nil; [self stop:&ignored]; return Fail(error,@"owned child resume refused; cleanup status must be inspected"); }
  return YES;
}
- (BOOL)reapUntil:(uint64_t)deadline error:(NSString **)error {
  while (_child) {
    pid_t result = waitpid(_child, NULL, WNOHANG);
    if (result == _child) { _child = 0; return YES; }
    if (result < 0 && errno != EINTR) { _unknown = YES; return Fail(error, @"direct child ownership was lost; refusing PID-based cleanup"); }
    if (KuroMonotonicMilliseconds() >= deadline) return NO;
    struct timespec pause = {.tv_nsec = 5000000}; nanosleep(&pause, NULL);
  }
  return YES;
}
- (BOOL)stop:(NSString **)error {
  if (![self onThread:error]) return NO;
  if (_unknown) return Fail(error, @"session ownership is unknown");
  if (_child) {
    // Check/reap first. An unreaped child cannot have its PID reused; no other
    // component may waitpid this child. ECHILD above never leads to kill(pid).
    [self reapUntil:KuroMonotonicMilliseconds() error:error];
    if (_unknown) return NO;
    if (_child) { if (kill(_child, SIGTERM) && errno != ESRCH) return Fail(error, @"owned child termination failed"); }
    if (_child && ![self reapUntil:KuroMonotonicMilliseconds() + 150 error:error]) {
      if (_unknown) return NO;
      if (kill(_child, SIGKILL) && errno != ESRCH) return Fail(error, @"owned child forced termination failed");
      if (![self reapUntil:KuroMonotonicMilliseconds() + 1000 error:error]) return Fail(error, @"owned child has not been reaped");
    }
  }
  if (_journaled) {
    if (!_cleanup || !_cleanup(error)) return Fail(error, @"child reaped but network restoration is not proven");
    NSString *path = [_directory stringByAppendingPathComponent:@"owner.json"];
    NSDictionary *record = ReadJSON(_directory, path, _owner, error);
    if (![record[@"session"] isEqual:_identifier]) return Fail(error, @"owner journal is incomplete or belongs to another session");
    if (unlink(path.fileSystemRepresentation) || ![self syncDirectory:error]) return Fail(error, @"owner journal removal is not durable");
    _journaled = NO; _cleanup = nil;
  }
  return YES;
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid error:(NSString **)error {
  return [self superviseSocket:socket leaseMilliseconds:lease identityValid:identityValid tick:nil error:error];
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick error:(NSString **)error {
  return [self superviseSocket:socket leaseMilliseconds:lease identityValid:identityValid tick:tick stopConfirmed:nil error:error];
}
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid tick:(KuroSessionHook)tick stopConfirmed:(void (^)(void))stopConfirmed error:(NSString **)error {
  if (![self onThread:error]) return NO;
  if (!_child || !_journaled || !identityValid || lease < 50 || lease > 30000) {
    NSString *ignored = nil; [self stop:&ignored];
    return Fail(error, @"invalid authenticated session lease; owned child stop attempted");
  }
  uint64_t deadline = KuroMonotonicMilliseconds() + lease, sequence = 1;
  NSMutableData *buffer = [NSMutableData data]; NSString *reason = @"session closed";
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
    if (count <= 0) break;
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
      BOOL stopped = [self stop:error] && self.off;
      // Publish proven off before the client can receive its stop acknowledgement.
      if (stopped && stopConfirmed) stopConfirmed();
      NSDictionary *reply = stopped ? @{@"version":@2,@"ok":@YES,@"sequence":@(sequence),@"status":@{@"availability":@"ready",@"state":@"off"}} : @{@"version":@2,@"ok":@NO,@"error":(error && *error) ? *error : @"cleanup is not proven"};
      NSMutableData *encoded = [JSONData(reply) mutableCopy]; [encoded appendBytes:"\n" length:1];
      (void)send(socket, encoded.bytes, encoded.length, MSG_NOSIGNAL | MSG_DONTWAIT);
      return stopped;
    }
    [buffer setLength:0]; sequence++; deadline = KuroMonotonicMilliseconds() + lease;
    NSString *reply = [NSString stringWithFormat:@"{\"version\":2,\"ok\":true,\"sequence\":%llu}\n", (unsigned long long)(sequence - 1)];
    const char *replyBytes = reply.UTF8String; size_t length = strlen(replyBytes);
    if (send(socket, replyBytes, length, MSG_NOSIGNAL | MSG_DONTWAIT) != (ssize_t)length) { reason = @"session acknowledgement failed"; break; }
  }
  BOOL stopped = [self stop:error] && self.off;
  if (stopped && stopConfirmed) stopConfirmed();
  if (stopped && error) *error = reason;
  return stopped;
}
@end
