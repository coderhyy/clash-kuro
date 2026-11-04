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
@interface KuroOwnedSession : NSObject {
  pid_t _child;
  pthread_t _thread;
  NSString *_directory;
  NSString *_identifier;
  uid_t _owner;
  BOOL _journaled;
  BOOL _unknown;
  KuroSessionHook _cleanup;
}
@property(nonatomic, readonly) pid_t child;
@property(nonatomic, readonly) NSString *identifier;
@property(nonatomic, readonly) BOOL off;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner;
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error;
- (BOOL)stop:(NSString **)error;
- (BOOL)superviseSocket:(int)socket leaseMilliseconds:(NSUInteger)lease identityValid:(BOOL (^)(void))identityValid error:(NSString **)error;
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
- (BOOL)spawnExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments beforeResume:(KuroSessionHook)prepare afterReap:(KuroSessionHook)cleanup error:(NSString **)error {
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
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
  int spawned = setup ? setup : posix_spawn(&_child, executable.fileSystemRepresentation, &actions, &attr, argv, environment);
  posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
  if (spawned) { _child = 0; return Fail(error, @"owned child spawn failed"); }
  struct proc_bsdinfo process = {0};
  BOOL known = proc_pidinfo(_child, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) == sizeof(process) && process.pbi_ppid == (uint32_t)getpid();
  NSDictionary *record = @{ @"format":@1, @"session":_identifier, @"pid":@(_child), @"parent":@(getpid()), @"startSeconds":@(process.pbi_start_tvsec), @"startMicros":@(process.pbi_start_tvusec), @"executableSHA256":Hash(bytes), @"phase":@"prepared" };
  _cleanup = [cleanup copy];
  // Mark uncertainty before creating the journal, including partial-write failures.
  _journaled = YES;
  BOOL ready = known && WriteNew(journal, JSONData(record), 0600, error) && [self syncDirectory:error] && prepare(error);
  if (!ready) { NSString *ignored = nil; [self stop:&ignored]; return Fail(error, @"owner preparation failed; child was never resumed (cleanup status must be inspected)"); }
  if (kill(_child, SIGCONT)) { NSString *ignored = nil; [self stop:&ignored]; return Fail(error, @"owned child could not be resumed"); }
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
  if (![self onThread:error]) return NO;
  if (!_child || !_journaled || !identityValid || lease < 50 || lease > 30000) {
    NSString *ignored = nil; [self stop:&ignored];
    return Fail(error, @"invalid authenticated session lease; owned child stop attempted");
  }
  uint64_t deadline = KuroMonotonicMilliseconds() + lease, sequence = 1;
  NSMutableData *buffer = [NSMutableData data]; NSString *reason = @"session closed";
  for (;;) {
    if (!identityValid()) { reason = @"authenticated client identity exited or changed"; break; }
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
      BOOL stopped = [self stop:error];
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
  BOOL stopped = [self stop:error];
  if (stopped && error) *error = reason;
  return stopped;
}
@end
