#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <bsm/libbsm.h>
#include <sys/acl.h>
#include <sys/attr.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static NSString *const Label = @"dev.kuro.tun";
static NSString *const Tools = @"/Library/PrivilegedHelperTools/dev.kuro.tun";
static NSString *const Recovery = @"/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall";
static NSString *const RecoveryRecord = @"/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall.json";
static NSString *const State = @"/Library/Application Support/Clash Kuro/Privileged";
static NSString *const SocketDirectory = @"/private/var/run/dev.kuro.tun";
static NSString *const SocketPath = @"/var/run/dev.kuro.tun/control.sock";
static NSString *const Plist = @"/Library/LaunchDaemons/dev.kuro.tun.plist";
static const NSUInteger MessageLimit = 65536;
static const NSUInteger OpenMessageLimit = 66000;
static volatile sig_atomic_t stopping = 0;

static BOOL Fail(NSString **error, NSString *message) { if (error) *error = message; return NO; }
static NSString *At(NSString *prefix, NSString *path) { return [prefix stringByAppendingString:path]; }
static NSString *Hex(NSData *data) {
  NSMutableString *result = [NSMutableString string];
  const unsigned char *bytes = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) [result appendFormat:@"%02x", bytes[i]];
  return result;
}
static NSString *Hash(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
  return result;
}
static BOOL Keys(NSDictionary *value, NSArray *keys) {
  return [value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}
static BOOL Match(NSString *value, NSString *pattern) {
  return [value isKindOfClass:NSString.class] && [value rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
static BOOL SafeMetadata(struct stat info, uid_t owner, BOOL directory) {
  return info.st_uid == owner && !(info.st_mode & 06022) &&
    (directory ? S_ISDIR(info.st_mode) : (S_ISREG(info.st_mode) && info.st_nlink == 1));
}
static BOOL SafeNode(NSString *path, uid_t owner, BOOL directory, NSString **error) {
  struct stat info;
  if (lstat(path.fileSystemRepresentation, &info) != 0 || !SafeMetadata(info, owner, directory)) return Fail(error, @"unprotected path, permissions, owner or file type");
  acl_t acl = acl_get_file(path.fileSystemRepresentation, ACL_TYPE_EXTENDED);
  if (!acl) {
    struct attrlist attributes = {.bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_EXTENDED_SECURITY};
    struct { uint32_t length; attrreference_t security; char data[65536]; } result = {0};
    if (!getattrlist(path.fileSystemRepresentation, &attributes, &result, sizeof(result), FSOPT_NOFOLLOW) && result.length >= sizeof(uint32_t) + sizeof(attrreference_t) && result.security.attr_length == 0) return YES;
    return Fail(error, @"unable to verify path ACL");
  }
  acl_entry_t entry;
  BOOL validACL = acl_valid(acl) == 0;
  errno = 0;
  int entries = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  BOOL emptyACL = entries == -1 && errno == EINVAL;
  acl_free(acl);
  if (!validACL || !emptyACL) return Fail(error, @"extended ACL is not approved");
  return YES;
}
static BOOL SafeChain(NSString *anchor, NSString *path, uid_t owner, BOOL directory, NSString **error) {
  NSString *base = anchor.length ? anchor : @"/";
  if (![path hasPrefix:base]) return Fail(error, @"path outside fixed anchor");
  NSString *relative = anchor.length ? [path substringFromIndex:anchor.length] : path;
  if (![path hasPrefix:base] || [relative.pathComponents containsObject:@".."] || !SafeNode(base, owner, YES, error)) return NO;
  NSString *current = base;
  NSArray *parts = relative.pathComponents;
  for (NSString *part in parts) {
    if ([part isEqualToString:@"/"] || !part.length) continue;
    current = [current stringByAppendingPathComponent:part];
    if (!SafeNode(current, owner, [current isEqualToString:path] ? directory : YES, error)) return NO;
  }
  return YES;
}
static NSData *ReadProtected(NSString *anchor, NSString *path, uid_t owner, NSString **error) {
  if (!SafeChain(anchor, path, owner, NO, error)) return nil;
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  struct stat before, after;
  if (fd < 0) { Fail(error, @"cannot open protected file"); return nil; }
  if (fstat(fd, &before) || !SafeMetadata(before, owner, NO) || before.st_size < 0 || before.st_size > 128 * 1024 * 1024) {
    close(fd); Fail(error, @"invalid protected file"); return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (NSUInteger)count;
  }
  BOOL valid = !fstat(fd, &after) && offset == data.length && before.st_ino == after.st_ino && before.st_dev == after.st_dev &&
    before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
    before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec && SafeMetadata(after, owner, NO);
  close(fd);
  if (!valid) { Fail(error, @"protected file changed during read"); return nil; }
  return data;
}
static NSDictionary *ReadJSON(NSString *anchor, NSString *path, uid_t owner, NSString **error) {
  NSData *data = ReadProtected(anchor, path, owner, error);
  if (!data || data.length > MessageLimit) { Fail(error, @"missing or oversized protected JSON"); return nil; }
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if (![value isKindOfClass:NSDictionary.class]) { Fail(error, @"invalid protected JSON"); return nil; }
  return value;
}
static NSString *Executable(void) {
  char buffer[PATH_MAX]; uint32_t size = sizeof(buffer);
  if (_NSGetExecutablePath(buffer, &size)) return nil;
  char resolved[PATH_MAX];
  if (!realpath(buffer, resolved)) return nil;
  return [NSString stringWithUTF8String:resolved];
}
static BOOL Exists(NSString *path) { struct stat s; return lstat(path.fileSystemRepresentation, &s) == 0 || errno != ENOENT; }
static BOOL EnsureDirectory(NSString *anchor, NSString *path, uid_t owner, mode_t mode, NSString **error) {
  if (Exists(path)) return SafeChain(anchor, path, owner, YES, error);
  NSString *parent = path.stringByDeletingLastPathComponent;
  if (!EnsureDirectory(anchor, parent, owner, 0755, error)) return NO;
  if (mkdir(path.fileSystemRepresentation, mode) || chmod(path.fileSystemRepresentation, mode)) return Fail(error, @"cannot create protected directory");
  return SafeChain(anchor, path, owner, YES, error);
}
static BOOL WriteNew(NSString *path, NSData *bytes, mode_t mode, NSString **error) {
  int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
  if (fd < 0) return Fail(error, @"destination exists or cannot be created");
  NSUInteger offset = 0;
  while (offset < bytes.length) {
    ssize_t count = write(fd, (const char *)bytes.bytes + offset, bytes.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (NSUInteger)count;
  }
  BOOL ok = offset == bytes.length && !fchmod(fd, mode) && !fsync(fd);
  close(fd);
  return ok || Fail(error, @"write incomplete; preserve transaction for recovery");
}
static NSData *JSONData(NSDictionary *value) { return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL]; }
static NSDictionary *ErrorResponse(NSString *error) { return @{@"version":@1, @"ok":@NO, @"error":error ?: @"operation refused"}; }
#import "tun-config.m"

static NSString *ParseRequest(NSData *data, NSString **error) {
  if (!data.length || data.length > MessageLimit) { Fail(error, @"request exceeds 64KiB or is empty"); return nil; }
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  // Exact finite grammar rejects duplicate/extra keys, escaped keys, booleans and fractional versions.
  NSString *pattern = @"\\A\\s*\\{\\s*(?:\"version\"\\s*:\\s*1\\s*,\\s*\"operation\"\\s*:\\s*\"(?:status|recover|start|stop)\"|\"operation\"\\s*:\\s*\"(?:status|recover|start|stop)\"\\s*,\\s*\"version\"\\s*:\\s*1)\\s*\\}\\s*\\z";
  if (!Match(text, pattern)) { Fail(error, @"invalid version-1 request"); return nil; }
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL][@"operation"];
}

static BOOL PeerCode(int peer, SecCodeRef *code, NSString **error) {
  audit_token_t token; socklen_t size = sizeof(token);
  if (getsockopt(peer, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token) || audit_token_to_pid(token) <= 0) return Fail(error, @"kernel peer identity unavailable");
  NSData *data = [NSData dataWithBytes:&token length:sizeof(token)];
  NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit:data};
  if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, 0, code) != errSecSuccess ||
      SecCodeCheckValidity(*code, kSecCSStrictValidate, NULL) != errSecSuccess) {
    if (*code) { CFRelease(*code); *code = NULL; }
    return Fail(error, @"dynamic peer code is not valid");
  }
  return YES;
}
static BOOL ProtectBundle(NSString *bundle, NSString **error) {
  if (!SafeChain(@"", bundle, 0, YES, error)) return NO;
  NSDirectoryEnumerator *entries = [[NSFileManager defaultManager] enumeratorAtPath:bundle];
  for (NSString *entry in entries) {
    NSString *path = [bundle stringByAppendingPathComponent:entry];
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) || !SafeNode(path, 0, S_ISDIR(info.st_mode), error)) return NO;
  }
  return YES;
}
static BOOL Authorize(int peer, NSString **error) {
  SecCodeRef code = NULL;
  if (!PeerCode(peer, &code, error)) return NO;
  CFDictionaryRef raw = NULL;
  OSStatus copied = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
  if (copied != errSecSuccess) { CFRelease(code); return Fail(error, @"cannot inspect peer signature"); }
  NSDictionary *info = CFBridgingRelease(raw);
  NSNumber *flags = info[(__bridge NSString *)kSecCodeInfoFlags];
  NSDictionary *entitlements = info[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
  BOOL hardened = (flags.unsignedIntValue & 0x10000) != 0;
  if (!hardened || [entitlements[@"com.apple.security.get-task-allow"] boolValue] ||
      [entitlements[@"com.apple.security.cs.allow-dyld-environment-variables"] boolValue] ||
      [entitlements[@"com.apple.security.cs.disable-library-validation"] boolValue]) {
    CFRelease(code); return Fail(error, @"client hardening is insufficient");
  }
  NSDictionary *pin = ReadJSON(@"", [State stringByAppendingPathComponent:@"client.json"], 0, error);
  NSData *identity = info[(__bridge NSString *)kSecCodeInfoUnique];
  NSURL *main = info[(__bridge NSString *)kSecCodeInfoMainExecutable];
  NSString *bundle = @"/Applications/Clash Kuro.app";
  NSString *expected = [bundle stringByAppendingPathComponent:@"Contents/MacOS/Clash Kuro"];
  BOOL pinned = Keys(pin, @[@"format", @"cdhash"]) && [pin[@"format"] isEqual:@1] && [Hex(identity ?: [NSData data]) isEqual:pin[@"cdhash"]] && [main.path isEqual:expected];
  if (!pinned || !ProtectBundle(bundle, error)) { CFRelease(code); return Fail(error, @"client resources or exact approved identity are unavailable"); }
  SecStaticCodeRef staticCode = NULL;
  OSStatus valid = SecCodeCopyStaticCode(code, 0, &staticCode);
  if (valid == errSecSuccess) valid = SecStaticCodeCheckValidity(staticCode, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, NULL);
  if (staticCode) CFRelease(staticCode);
  CFRelease(code);
  if (valid != errSecSuccess) return Fail(error, @"full client code seal is invalid");
  // No runtime switch bypasses this gate: Electron launch/injection boundary is not yet proven.
  return Fail(error, @"complete Electron startup and injection attestation is not enabled");
}

#import "tun-peer.m"
#import "tun-session.m"
#import "tun-network.m"

static BOOL HasOwnershipFootprint(NSString *prefix) {
  for (NSString *name in @[@"owner.json", @"network.json", @"network-dns.json"]) if (Exists(At(prefix, [State stringByAppendingPathComponent:name]))) return YES;
  return NO;
}
static NSDictionary *Status(NSString *prefix, uid_t owner) {
  NSString *error = nil;
  NSDictionary *record = ReadJSON(prefix, At(prefix, [State stringByAppendingPathComponent:@"installed.json"]), owner, &error);
  BOOL off = Keys(record, @[@"format", @"release", @"helperSHA256", @"neverStarted"]) && [record[@"format"] isEqual:@1] && [record[@"neverStarted"] isEqual:@YES] &&
    Match(record[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") && !HasOwnershipFootprint(prefix);
  if (off) {
    NSString *helperPath = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:[record[@"release"] stringByAppendingPathComponent:@"helper"]]];
    NSData *helper = ReadProtected(prefix, helperPath, owner, &error);
    off = helper && [Hash(helper) isEqual:record[@"helperSHA256"]];
#ifndef KURO_TESTING
    off = off && [helperPath isEqual:Executable()];
#endif
  }
  return @{@"version":@1, @"ok":@YES, @"status":@{@"availability":@"blocked", @"state":off ? @"off" : @"unknown", @"error":off ? @"root Core configuration and client attestation are not enabled" : @"owned process/network cleanup cannot be proven"}};
}
static NSDictionary *ProcessRequest(NSData *data, int peer, NSString *prefix, uid_t owner) {
  NSString *error = nil;
  id request = KuroDecodeJSON(data, OpenMessageLimit, &error);
  if ([request isKindOfClass:NSDictionary.class] && KuroNumber(request[@"version"], 2, 2)) {
    NSDictionary *(^refused)(NSString *) = ^NSDictionary *(NSString *message) { return @{@"version":@2,@"ok":@NO,@"error":message ?: @"operation refused"}; };
    if (!Keys(request, @[@"version", @"operation", @"config"]) || ![request[@"operation"] isEqual:@"open"] || ![request[@"config"] isKindOfClass:NSDictionary.class]) return refused(@"invalid version-2 open request");
    if (!Authorize(peer, &error)) return refused(error);
    if (!KuroTunRuntimeJSON([NSJSONSerialization dataWithJSONObject:request[@"config"] options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:NULL], &error)) return refused(error);
    if (!KuroNetworkRoutesReady(&error) || !KuroNetworkCoreDNSReady(&error)) return refused(error);
    return refused(@"owned Core launch, complete caller attestation and network prerequisites are not enabled; start refused");
  }
  NSString *operation = ParseRequest(data, &error);
  if (!operation) return ErrorResponse(error);
  if ([operation isEqual:@"status"]) return Status(prefix, owner);
  if (!Authorize(peer, &error)) return ErrorResponse(error);
  if ([operation isEqual:@"start"]) return ErrorResponse(@"V1 start unsupported; authenticated V2 prerequisites incomplete");
  NSDictionary *status = Status(prefix, owner);
  if (![status[@"status"][@"state"] isEqual:@"off"]) return ErrorResponse(@"owned process/network cleanup is not implemented; recovery refused");
  return status;
}

static int Launchctl(NSArray *arguments) {
  pid_t child;
  NSMutableArray *strings = [NSMutableArray arrayWithObject:@"/bin/launchctl"];
  [strings addObjectsFromArray:arguments];
  char *argv[strings.count + 1];
  for (NSUInteger i = 0; i < strings.count; i++) argv[i] = (char *)[strings[i] UTF8String];
  argv[strings.count] = NULL;
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  int result = posix_spawn(&child, "/bin/launchctl", &actions, NULL, argv, environment);
  posix_spawn_file_actions_destroy(&actions);
  if (result) return -1;
  for (int i = 0; i < 100; i++) {
    int status;
    pid_t done = waitpid(child, &status, WNOHANG);
    if (done == child) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (done < 0 && errno != EINTR) return -1;
    struct timespec pause = {0, 50000000}; nanosleep(&pause, NULL);
  }
  kill(child, SIGKILL); waitpid(child, NULL, 0);
  return -1;
}
static BOOL StopService(BOOL system, NSString **error) {
  if (!system) return YES;
  int present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
  if (present == 3 || present == 113) return YES;
  if (present != 0 || Launchctl(@[@"bootout", @"system/dev.kuro.tun"]) != 0) return Fail(error, @"cannot prove service stopped; installation preserved");
  present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
  return (present == 3 || present == 113) || Fail(error, @"service absence not confirmed");
}
static BOOL PreflightInstall(NSString *prefix, uid_t owner, BOOL system, NSString **error) {
  for (NSString *target in @[Tools, State, SocketDirectory, Plist, Recovery, RecoveryRecord]) {
    NSString *path = At(prefix, target);
    if (Exists(path)) return Fail(error, @"existing or partial helper install preserved; fresh install refused");
    NSString *current = prefix.length ? prefix : @"/";
    if (!SafeNode(current, owner, YES, error)) return NO;
    for (NSString *component in target.pathComponents) {
      if ([component isEqual:@"/"]) continue;
      current = [current stringByAppendingPathComponent:component];
      if (!Exists(current)) break;
      if (!SafeNode(current, owner, YES, error)) return NO;
    }
  }
  if (system) {
    int present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
    if (present != 3 && present != 113) return Fail(error, @"service absence not proven; install refused");
  }
  return YES;
}
static BOOL ValidManifest(NSDictionary *manifest, NSString **error) {
  if (!Keys(manifest, @[@"format", @"label", @"release", @"target", @"protocol", @"activationAllowed", @"core", @"helper"]) ||
      ![manifest[@"format"] isEqual:@1] || ![manifest[@"protocol"] isEqual:@1] || ![manifest[@"label"] isEqual:Label] || ![manifest[@"activationAllowed"] isEqual:@NO] ||
      !Match(manifest[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") ||
      !Keys(manifest[@"core"], @[@"file", @"version", @"sha256", @"archiveSha256"]) || !Keys(manifest[@"helper"], @[@"file", @"version", @"sha256"]) ||
      ![manifest[@"core"][@"file"] isEqual:@"mihomo"] || ![manifest[@"helper"][@"file"] isEqual:@"helper"] ||
      !Match(manifest[@"core"][@"sha256"], @"\\A[0-9a-f]{64}\\z") || !Match(manifest[@"helper"][@"sha256"], @"\\A[0-9a-f]{64}\\z")) return Fail(error, @"invalid fixed payload manifest");
#if defined(__arm64__)
  NSString *target = @"darwin-arm64";
#else
  NSString *target = @"darwin-x64";
#endif
  return [manifest[@"target"] isEqual:target] || Fail(error, @"payload architecture does not match installer");
}
static BOOL FixedPlist(NSData *data, NSString *release, NSString **error) {
  NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
  NSString *program = [[Tools stringByAppendingPathComponent:@"versions"] stringByAppendingPathComponent:[release stringByAppendingPathComponent:@"helper"]];
  return (Keys(plist, @[@"Label", @"ProgramArguments", @"Disabled", @"RunAtLoad", @"KeepAlive", @"AbandonProcessGroup"]) && [plist[@"Label"] isEqual:Label] &&
    [plist[@"ProgramArguments"] isEqual:@[program, @"--serve"]] && [plist[@"Disabled"] isEqual:@YES] && [plist[@"RunAtLoad"] isEqual:@NO] && [plist[@"KeepAlive"] isEqual:@NO] && [plist[@"AbandonProcessGroup"] isEqual:@NO]) || Fail(error, @"plist must be fixed and disabled");
}
static BOOL ProveNeverStarted(NSString *prefix, uid_t owner, NSDictionary **record, NSString **error) {
  *record = ReadJSON(prefix, At(prefix, [State stringByAppendingPathComponent:@"installed.json"]), owner, error);
  if (!Keys(*record, @[@"format", @"release", @"helperSHA256", @"neverStarted"]) || ![(*record)[@"format"] isEqual:@1] || ![(*record)[@"neverStarted"] isEqual:@YES] ||
      !Match((*record)[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") || HasOwnershipFootprint(prefix)) return Fail(error, @"no proven off ownership record; cleanup refused");
  return YES;
}
static BOOL MachExecutable(NSData *data) {
  uint32_t header[8];
  if (data.length < sizeof(header)) return NO;
  memcpy(header, data.bytes, sizeof(header));
#if defined(__arm64__)
  uint32_t cpu = 0x0100000c;
#else
  uint32_t cpu = 0x01000007;
#endif
  return header[0] == 0xfeedfacf && header[1] == cpu && header[3] == 2;
}
static int ServiceLock(NSString *prefix, uid_t owner, NSString **error) {
  NSString *directory = At(prefix, SocketDirectory);
  if (!EnsureDirectory(prefix, directory, owner, 0755, error)) return -1;
  NSString *path = [directory stringByAppendingPathComponent:@"service.lock"];
  int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat info;
  if (fd < 0 || fstat(fd, &info) || !SafeMetadata(info, owner, NO) || (info.st_mode & 0777) != 0600 ||
      !SafeChain(prefix, path, owner, NO, error) || flock(fd, LOCK_EX | LOCK_NB)) {
    if (fd >= 0) close(fd);
    Fail(error, @"service lock unavailable; active or unknown helper preserved");
    return -1;
  }
  return fd;
}
static BOOL Install(NSString *prefix, uid_t owner, BOOL system, NSString **error) {
  NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
  NSDictionary *manifest = ReadJSON(prefix, [inbox stringByAppendingPathComponent:@"manifest.json"], owner, error);
  if (!ValidManifest(manifest, error)) return NO;
  NSMutableDictionary *files = [NSMutableDictionary dictionary];
  for (NSString *name in @[@"helper", @"mihomo", @"manifest.json", @"dev.kuro.tun.plist"]) {
    NSData *bytes = ReadProtected(prefix, [inbox stringByAppendingPathComponent:name], owner, error);
    if (!bytes) return NO;
    files[name] = bytes;
  }
  if (!MachExecutable(files[@"helper"]) || !MachExecutable(files[@"mihomo"])) return Fail(error, @"payload must contain matching thin Mach-O executables");
  if (![Hash(files[@"helper"]) isEqual:manifest[@"helper"][@"sha256"]] || ![Hash(files[@"mihomo"]) isEqual:manifest[@"core"][@"sha256"]] || !FixedPlist(files[@"dev.kuro.tun.plist"], manifest[@"release"], error)) return Fail(error, @"payload digest or fixed plist mismatch");
  if (system) {
    NSString *installer = [Tools stringByAppendingPathComponent:@"installer"];
    NSData *selfBytes = ReadProtected(prefix, installer, owner, error);
    NSData *recovery = ReadProtected(prefix, At(prefix, Recovery), owner, error);
    if (![Executable() isEqual:installer] || !selfBytes || !recovery || ![Hash(recovery) isEqual:manifest[@"helper"][@"sha256"]] || ![Hash(selfBytes) isEqual:manifest[@"helper"][@"sha256"]]) return Fail(error, @"installer must be the approved protected helper executable");
  }
  NSString *statePath = At(prefix, [State stringByAppendingPathComponent:@"installed.json"]);
  // No unknown upgrade/partial state is overwritten. First install only until ownership migration is implemented.
  if (Exists(statePath) || Exists(At(prefix, Plist)) || Exists(At(prefix, [Tools stringByAppendingPathComponent:@"versions"]))) return Fail(error, @"existing or partial install requires recovery; upgrade refused");
  if (system) {
    int service = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
    if (service != 3 && service != 113) return Fail(error, @"existing or unknown service; fresh installation refused");
  }
  int serviceLock = ServiceLock(prefix, owner, error);
  if (serviceLock < 0) return NO;
  @try {
  NSString *version = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:manifest[@"release"]]];
  if (!EnsureDirectory(prefix, At(prefix, State), owner, 0700, error) || !EnsureDirectory(prefix, version, owner, 0755, error) || !EnsureDirectory(prefix, At(prefix, @"/Library/LaunchDaemons"), owner, 0755, error)) return NO;
  NSDictionary *transaction = @{@"format":@1, @"release":manifest[@"release"], @"stage":@"copying"};
  NSString *transactionPath = At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]);
  if (!WriteNew(transactionPath, JSONData(transaction), 0600, error)) return NO;
  for (NSString *name in @[@"helper", @"mihomo", @"manifest.json"]) {
    mode_t mode = [name isEqual:@"manifest.json"] ? 0600 : 0755;
    if (!WriteNew([version stringByAppendingPathComponent:name], files[name], mode, error)) return NO;
  }
  if (!WriteNew(At(prefix, Plist), files[@"dev.kuro.tun.plist"], 0644, error)) return NO;
  NSDictionary *record = @{@"format":@1, @"release":manifest[@"release"], @"helperSHA256":manifest[@"helper"][@"sha256"], @"neverStarted":@YES};
  if (!WriteNew(statePath, JSONData(record), 0600, error)) return NO;
  // Installation never bootstraps a service or changes any network state.
  if (unlink(transactionPath.fileSystemRepresentation)) return Fail(error, @"installed disabled, but transaction cleanup failed");
  return YES;
  } @finally { close(serviceLock); }
}
static BOOL OnlyNames(NSString *prefix, NSString *path, uid_t owner, NSArray *allowed, NSString **error) {
  if (!Exists(path)) return YES;
  if (!SafeChain(prefix, path, owner, YES, error)) return NO;
  NSError *failure = nil;
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&failure];
  if (!names || failure) return Fail(error, @"cannot enumerate owned directory");
  for (NSString *name in names) if (![allowed containsObject:name]) return Fail(error, @"unknown files preserved; uninstall refused");
  return YES;
}
static BOOL RemoveApproved(NSString *prefix, NSString *path, uid_t owner, NSString *digest, NSString **error) {
  if (!Exists(path)) return YES;
  NSData *bytes = ReadProtected(prefix, path, owner, error);
  if (!bytes || ![Hash(bytes) isEqual:digest]) return Fail(error, @"changed installed file preserved; uninstall refused");
  return !unlink(path.fileSystemRepresentation) || Fail(error, @"file removal failed; retry recorded uninstall");
}
static BOOL RemoveDirectory(NSString *path, NSString **error) {
  return !rmdir(path.fileSystemRepresentation) || errno == ENOENT || Fail(error, @"directory not empty or removal failed; preserved");
}
static BOOL FinalizeRecovery(NSString *prefix, uid_t owner, BOOL system, NSString *entry, NSString **error) {
  if (![entry isEqual:At(prefix, Recovery)] || Exists(At(prefix, RecoveryRecord))) return Fail(error, @"no approved uninstall record");
  for (NSString *path in @[Tools, State, SocketDirectory, Plist]) if (Exists(At(prefix, path))) return Fail(error, @"uninstall is not complete; recovery entry retained");
  NSData *bytes = ReadProtected(prefix, At(prefix, Recovery), owner, error);
  if (!bytes || !MachExecutable(bytes)) return Fail(error, @"unprotected recovery executable");
  if (system) {
    SecCodeRef self = NULL; SecStaticCodeRef disk = NULL;
    NSURL *url = [NSURL fileURLWithPath:entry];
    BOOL valid = SecCodeCopySelf(0, &self) == errSecSuccess && SecCodeCheckValidity(self, kSecCSStrictValidate, NULL) == errSecSuccess &&
      SecStaticCodeCreateWithPath((__bridge CFURLRef)url, 0, &disk) == errSecSuccess && SecStaticCodeCheckValidity(disk, kSecCSStrictValidate, NULL) == errSecSuccess;
    CFDictionaryRef liveInfo = NULL, diskInfo = NULL;
    if (valid) valid = SecCodeCopySigningInformation(self, kSecCSSigningInformation, &liveInfo) == errSecSuccess && SecCodeCopySigningInformation(disk, kSecCSSigningInformation, &diskInfo) == errSecSuccess;
    if (valid) {
      CFTypeRef liveHash = CFDictionaryGetValue(liveInfo, kSecCodeInfoUnique), diskHash = CFDictionaryGetValue(diskInfo, kSecCodeInfoUnique);
      valid = liveHash && diskHash && CFEqual(liveHash, diskHash);
    }
    if (liveInfo) CFRelease(liveInfo); if (diskInfo) CFRelease(diskInfo); if (self) CFRelease(self); if (disk) CFRelease(disk);
    if (!valid) return Fail(error, @"recovery code identity invalid");
  }
  return !unlink(At(prefix, Recovery).fileSystemRepresentation) || Fail(error, @"final recovery removal failed; rerun fixed recovery CLI");
}
static BOOL Uninstall(NSString *prefix, uid_t owner, BOOL system, NSString *entry, NSString **error) {
  NSString *approvalPath = At(prefix, RecoveryRecord);
  if (!Exists(approvalPath) && !Exists(At(prefix, Tools)) && !Exists(At(prefix, State))) return FinalizeRecovery(prefix, owner, system, entry, error);
  NSString *statePath = At(prefix, [State stringByAppendingPathComponent:@"installed.json"]);
  NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
  NSDictionary *approval = nil;
  if (Exists(approvalPath)) {
    approval = ReadJSON(prefix, approvalPath, owner, error);
    if (!Keys(approval, @[@"format", @"release", @"helper", @"core", @"manifest", @"plist", @"neverStarted"]) ||
        ![approval[@"format"] isEqual:@1] || ![approval[@"neverStarted"] isEqual:@YES]) return Fail(error, @"invalid uninstall recovery record");
    for (NSString *key in @[@"helper", @"core", @"manifest", @"plist"]) if (!Match(approval[key], @"\\A[0-9a-f]{64}\\z")) return Fail(error, @"invalid uninstall digest");
  } else {
    NSDictionary *record = nil;
    if (!ProveNeverStarted(prefix, owner, &record, error) || Exists(At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]))) return Fail(error, @"unknown/partial installation; uninstall refused");
    NSString *version = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:record[@"release"]]];
    NSData *manifestBytes = ReadProtected(prefix, [version stringByAppendingPathComponent:@"manifest.json"], owner, error);
    NSDictionary *manifest = manifestBytes ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:NULL] : nil;
    if (!ValidManifest(manifest, error) || ![manifest[@"release"] isEqual:record[@"release"]] || ![manifest[@"helper"][@"sha256"] isEqual:record[@"helperSHA256"]]) return Fail(error, @"installed manifest does not match off record");
    for (NSString *name in @[@"helper", @"mihomo"]) {
      NSData *bytes = ReadProtected(prefix, [version stringByAppendingPathComponent:name], owner, error);
      NSDictionary *item = manifest[[name isEqual:@"helper"] ? @"helper" : @"core"];
      if (!bytes || ![Hash(bytes) isEqual:item[@"sha256"]]) return Fail(error, @"installed bytes changed; uninstall refused");
    }
    NSData *plist = ReadProtected(prefix, At(prefix, Plist), owner, error);
    if (!FixedPlist(plist, record[@"release"], error)) return NO;
    approval = @{@"format":@1, @"release":record[@"release"], @"helper":manifest[@"helper"][@"sha256"], @"core":manifest[@"core"][@"sha256"], @"manifest":Hash(manifestBytes), @"plist":Hash(plist), @"neverStarted":@YES};
    if (!WriteNew(approvalPath, JSONData(approval), 0600, error)) return NO;
  }
  if (!Match(approval[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") || HasOwnershipFootprint(prefix) || Exists(At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]))) return Fail(error, @"owned cleanup is unknown; uninstall preserved");
  NSString *versions = [At(prefix, Tools) stringByAppendingPathComponent:@"versions"];
  NSString *version = [versions stringByAppendingPathComponent:approval[@"release"]];
  if (!OnlyNames(prefix, At(prefix, Tools), owner, @[@"installer", @"versions"], error) ||
      !OnlyNames(prefix, versions, owner, @[approval[@"release"]], error) ||
      !OnlyNames(prefix, version, owner, @[@"helper", @"mihomo", @"manifest.json"], error) ||
      !OnlyNames(prefix, At(prefix, State), owner, @[@"installed.json", @"Inbox"], error) ||
      !OnlyNames(prefix, inbox, owner, @[@"helper", @"mihomo", @"manifest.json", @"dev.kuro.tun.plist"], error) ||
      !OnlyNames(prefix, At(prefix, SocketDirectory), owner, @[@"service.lock", @"control.sock"], error) || !StopService(system, error)) return NO;
  NSData *recovery = ReadProtected(prefix, At(prefix, Recovery), owner, error);
  if (!recovery || ![Hash(recovery) isEqual:approval[@"helper"]]) return Fail(error, @"exact recovery executable unavailable; uninstall preserved");
  int serviceLock = ServiceLock(prefix, owner, error);
  if (serviceLock < 0) return NO;
  @try {
    for (NSString *directory in @[version, inbox]) {
      for (NSArray *item in @[@[@"helper", @"helper"], @[@"mihomo", @"core"], @[@"manifest.json", @"manifest"]])
        if (!RemoveApproved(prefix, [directory stringByAppendingPathComponent:item[0]], owner, approval[item[1]], error)) return NO;
    }
    if (!RemoveApproved(prefix, [inbox stringByAppendingPathComponent:@"dev.kuro.tun.plist"], owner, approval[@"plist"], error) ||
        !RemoveApproved(prefix, At(prefix, Plist), owner, approval[@"plist"], error) ||
        !RemoveDirectory(version, error) || !RemoveDirectory(versions, error) || !RemoveDirectory(inbox, error)) return NO;
    NSString *socket = [At(prefix, SocketDirectory) stringByAppendingPathComponent:@"control.sock"];
    struct stat info;
    if (Exists(socket) && (lstat(socket.fileSystemRepresentation, &info) || !S_ISSOCK(info.st_mode) || info.st_uid != owner || unlink(socket.fileSystemRepresentation))) return Fail(error, @"unknown socket preserved");
    for (NSString *lock in @[[At(prefix, SocketDirectory) stringByAppendingPathComponent:@"service.lock"]]) {
      if (Exists(lock) && (!SafeChain(prefix, lock, owner, NO, error) || lstat(lock.fileSystemRepresentation, &info) || info.st_size != 0 || unlink(lock.fileSystemRepresentation))) return Fail(error, @"unknown lock preserved");
    }
    if (!RemoveDirectory(At(prefix, SocketDirectory), error) || !RemoveApproved(prefix, [At(prefix, Tools) stringByAppendingPathComponent:@"installer"], owner, approval[@"helper"], error) || !RemoveDirectory(At(prefix, Tools), error)) return NO;
    if (Exists(statePath) && (!ReadProtected(prefix, statePath, owner, error) || unlink(statePath.fileSystemRepresentation))) return Fail(error, @"off record removal failed; approval retained");
    if (!RemoveDirectory(At(prefix, State), error)) return Fail(error, @"final state cleanup failed; recovery entry retained");
    if (unlink(approvalPath.fileSystemRepresentation)) return Fail(error, @"final approval cleanup failed; recovery entry retained");
    return RemoveApproved(prefix, At(prefix, Recovery), owner, approval[@"helper"], error);
  } @finally { close(serviceLock); }
}

static void StopSignal(int signalNumber) { (void)signalNumber; stopping = 1; }
static int Serve(void) {
  NSString *error = nil;
  if (!EnsureDirectory(@"", SocketDirectory, 0, 0755, &error)) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }
  NSString *lockPath = [SocketDirectory stringByAppendingPathComponent:@"service.lock"];
  int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat info;
  if (lock < 0 || fstat(lock, &info) || !SafeMetadata(info, 0, NO) || flock(lock, LOCK_EX | LOCK_NB)) return 1;
  NSString *realSocket = [SocketDirectory stringByAppendingPathComponent:@"control.sock"];
  if (Exists(realSocket)) {
    if (lstat(realSocket.fileSystemRepresentation, &info) || !S_ISSOCK(info.st_mode) || info.st_uid != 0 || unlink(realSocket.fileSystemRepresentation)) return 1;
  }
  int listener = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  strlcpy(address.sun_path, SocketPath.UTF8String, sizeof(address.sun_path));
  if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(realSocket.fileSystemRepresentation, 0666) || listen(listener, 8)) return 1;
  struct stat ownedSocket;
  if (lstat(realSocket.fileSystemRepresentation, &ownedSocket)) return 1;
  signal(SIGTERM, StopSignal); signal(SIGINT, StopSignal); signal(SIGPIPE, SIG_IGN);
  while (!stopping) {
    struct pollfd pending = {.fd = listener, .events = POLLIN};
    if (poll(&pending, 1, 500) <= 0) continue;
    int peer = accept(listener, NULL, NULL);
    if (peer < 0) continue;
    @autoreleasepool {
      NSMutableData *request = [NSMutableData data];
      BOOL complete = NO; BOOL invalid = NO;
      // Absolute bounded request lifetime, even when a client slowly trickles bytes.
      struct timespec began; clock_gettime(CLOCK_MONOTONIC, &began);
      while (!stopping && request.length <= OpenMessageLimit) {
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - began.tv_sec) * 1000 + (now.tv_nsec - began.tv_nsec) / 1000000;
        struct pollfd ready = {.fd = peer, .events = POLLIN};
        if (elapsed >= 2000 || poll(&ready, 1, (int)(2000 - elapsed)) <= 0) break;
        char bytes[4096]; ssize_t count = recv(peer, bytes, sizeof(bytes), 0);
        if (count <= 0) break;
        char *newline = memchr(bytes, '\n', (size_t)count);
        [request appendBytes:bytes length:(NSUInteger)count];
        if (newline) { complete = YES; invalid = newline != bytes + count - 1; break; }
      }
      NSDictionary *response = complete && !invalid ? ProcessRequest(request, peer, @"", 0) : ErrorResponse(@"request must be one newline-terminated JSON within its version byte limit and 2 seconds");
      NSMutableData *encoded = [JSONData(response) mutableCopy]; [encoded appendBytes:"\n" length:1];
      struct timeval timeout = {1, 0}; setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
      (void)send(peer, encoded.bytes, encoded.length, 0);
      close(peer);
    }
  }
  close(listener);
  if (!lstat(realSocket.fileSystemRepresentation, &info) && info.st_ino == ownedSocket.st_ino && info.st_dev == ownedSocket.st_dev) unlink(realSocket.fileSystemRepresentation);
  close(lock);
  return 0;
}
#ifndef KURO_TESTING
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (geteuid() != 0 || argc != 2) { fprintf(stderr, "root-only fixed CLI: --serve | --preflight-install | --install | --uninstall\n"); return 1; }
    if (!strcmp(argv[1], "--serve")) return Serve();
    if (strcmp(argv[1], "--install") && strcmp(argv[1], "--uninstall") && strcmp(argv[1], "--preflight-install")) return 1;
    NSString *error = nil;
    NSString *entry = Executable();
    if (!strcmp(argv[1], "--preflight-install")) {
      BOOL ok = PreflightInstall(@"", 0, YES, &error);
      if (!ok) fprintf(stderr, "%s\n", error.UTF8String);
      return ok ? 0 : 1;
    }
    BOOL installing = !strcmp(argv[1], "--install");
    if (![entry isEqual:[Tools stringByAppendingPathComponent:@"installer"]] && (installing || ![entry isEqual:Recovery])) { fprintf(stderr, "fixed protected installer/recovery path required\n"); return 1; }
    if (!ReadProtected(@"", entry, 0, &error)) return 1;
    NSString *parent = @"/Library/PrivilegedHelperTools";
    if (!SafeChain(@"", parent, 0, YES, &error)) return 1;
    int lock = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) return 1;
    BOOL ok = installing ? Install(@"", 0, YES, &error) : Uninstall(@"", 0, YES, entry, &error);
    close(lock);
    if (!ok) fprintf(stderr, "%s\n", (error ?: @"operation refused; installation preserved").UTF8String);
    return ok ? 0 : 1;
  }
}
#endif
