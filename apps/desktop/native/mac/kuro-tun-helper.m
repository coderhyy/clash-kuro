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
static NSString *const SocketDirectory = @"/Library/PrivilegedHelperTools/dev.kuro.tun-run";
// Detection only: never connect to, migrate or remove a legacy endpoint.
static NSString *const LegacySocketDirectory = @"/private/var/run/dev.kuro.tun";
static NSString *const Plist = @"/Library/LaunchDaemons/dev.kuro.tun.plist";
static const NSUInteger MessageLimit = 65536;
static const NSUInteger OpenMessageLimit = 66000;
static volatile sig_atomic_t stopping = 0;

static BOOL Fail(NSString **error, NSString *message) { if (error) *error = message; return NO; }
static NSString *At(NSString *prefix, NSString *path) { return [prefix stringByAppendingString:path]; }
static BOOL KuroUnixSocketAddress(NSString *path,struct sockaddr_un *address,NSString **error) {
  const char *bytes=path.fileSystemRepresentation;
  NSUInteger length=[path lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if(!path.isAbsolutePath || !bytes || strlen(bytes)!=length)return Fail(error,[NSString stringWithFormat:@"invalid fixed Unix socket path: %@",path]);
  if(length>=sizeof(address->sun_path))return Fail(error,[NSString stringWithFormat:@"Unix socket path exceeds sun_path capacity (%lu >= %lu): %@",(unsigned long)length,(unsigned long)sizeof(address->sun_path),path]);
  memset(address,0,sizeof(*address));address->sun_family=AF_UNIX;address->sun_len=sizeof(*address);
  strlcpy(address->sun_path,bytes,sizeof(address->sun_path));return YES;
}
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
static BOOL SafeNodeMetadata(NSString *path,struct stat info,uid_t owner,BOOL directory,NSString **error) {
  if(SafeMetadata(info,owner,directory))return YES;
  NSString *reason;
  if(S_ISLNK(info.st_mode))reason=@"symlink is not allowed";
  else if(info.st_uid!=owner)reason=[NSString stringWithFormat:@"owner uid %u differs from required uid %u",info.st_uid,owner];
  else if(info.st_mode&06022)reason=[NSString stringWithFormat:@"mode %04o contains set-ID or group/other-write bits",(unsigned)(info.st_mode&07777)];
  else if(directory)reason=@"expected a directory";
  else if(!S_ISREG(info.st_mode))reason=@"expected a regular file";
  else reason=[NSString stringWithFormat:@"regular file link count %llu differs from 1",(unsigned long long)info.st_nlink];
  return Fail(error,[NSString stringWithFormat:@"unprotected path %@: %@",path,reason]);
}
static BOOL SafeNode(NSString *path, uid_t owner, BOOL directory, NSString **error) {
  struct stat info;
  if(lstat(path.fileSystemRepresentation,&info))return Fail(error,[NSString stringWithFormat:@"cannot inspect protected path %@: %s",path,strerror(errno)]);
  if(!SafeNodeMetadata(path,info,owner,directory,error))return NO;
  acl_t acl = acl_get_file(path.fileSystemRepresentation, ACL_TYPE_EXTENDED);
  if (!acl) {
    struct attrlist attributes = {.bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_EXTENDED_SECURITY};
    struct { uint32_t length; attrreference_t security; char data[65536]; } result = {0};
    if (!getattrlist(path.fileSystemRepresentation, &attributes, &result, sizeof(result), FSOPT_NOFOLLOW) && result.length >= sizeof(uint32_t) + sizeof(attrreference_t) && result.security.attr_length == 0) return YES;
    return Fail(error, [NSString stringWithFormat:@"unable to verify extended ACL for path %@",path]);
  }
  acl_entry_t entry;
  BOOL validACL = acl_valid(acl) == 0;
  errno = 0;
  int entries = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
  BOOL emptyACL = entries == -1 && errno == EINVAL;
  acl_free(acl);
  if (!validACL || !emptyACL) return Fail(error, [NSString stringWithFormat:@"extended ACL is not approved for path %@",path]);
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
// Public endpoints require search permission for ordinary clients on every
// existing ancestor. The private test anchor itself is intentionally excluded.
static BOOL SocketAncestorsProtected(NSString *prefix,uid_t owner,BOOL complete,NSString **error) {
  NSString *current=prefix.length?prefix:@"/";
  if(!SafeNode(current,owner,YES,error))return NO;
  if(!prefix.length) {
    struct stat root;
    if(lstat("/",&root)||!(root.st_mode&S_IXOTH))return Fail(error,@"public socket ancestor / is not searchable by ordinary clients");
  }
  for(NSString *component in SocketDirectory.pathComponents) {
    if([component isEqual:@"/"])continue;
    current=[current stringByAppendingPathComponent:component];
    if(!Exists(current))return !complete||Fail(error,[NSString stringWithFormat:@"public socket directory is missing: %@",current]);
    if(!SafeNode(current,owner,YES,error))return NO;
    struct stat info;
    if(lstat(current.fileSystemRepresentation,&info))return Fail(error,[NSString stringWithFormat:@"cannot inspect public socket ancestor %@: %s",current,strerror(errno)]);
    if(!(info.st_mode&S_IXOTH))return Fail(error,[NSString stringWithFormat:@"public socket ancestor %@ mode %04o is not searchable by ordinary clients",current,(unsigned)(info.st_mode&07777)]);
  }
  return YES;
}
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
#import "tun-client.m"

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
static BOOL AuthorizeClientAt(int peer, NSString *prefix, uid_t owner, NSString **error) {
  SecCodeRef code = NULL;
  if (!PeerCode(peer, &code, error)) return NO;
  CFDictionaryRef raw = NULL;
  OSStatus copied = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
  if (copied != errSecSuccess) { CFRelease(code); return Fail(error, @"cannot inspect peer signature"); }
  NSDictionary *info = CFBridgingRelease(raw);
  if (!KuroClientHardening(info, error)) {
    CFRelease(code); return Fail(error, @"client hardening is insufficient");
  }
  NSDictionary *pin = ReadJSON(prefix, At(prefix, [State stringByAppendingPathComponent:@"client.json"]), owner, error);
  NSData *identity = info[(__bridge NSString *)kSecCodeInfoUnique];
  NSURL *main = info[(__bridge NSString *)kSecCodeInfoMainExecutable];
  NSString *expected = [At(prefix, ClientBundle) stringByAppendingPathComponent:ClientExecutable];
  BOOL pinned = KuroClientPinValid(pin) && [Hex(identity ?: [NSData data]) isEqual:pin[@"cdhash"]] && [main.path isEqual:expected];
  if (!pinned || ![KuroClientSnapshot(prefix, At(prefix, ClientBundle), owner, error) isEqual:pin]) { CFRelease(code); return Fail(error, @"client resources or exact approved identity are unavailable"); }
  SecStaticCodeRef staticCode = NULL;
  OSStatus valid = SecCodeCopyStaticCode(code, 0, &staticCode);
  if (valid == errSecSuccess) valid = SecStaticCodeCheckValidity(staticCode, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, NULL);
  if (staticCode) CFRelease(staticCode);
  CFRelease(code);
  if (valid != errSecSuccess) return Fail(error, @"full client code seal is invalid");
  return YES;
}
static BOOL AuthorizeClient(int peer, NSString **error) { return AuthorizeClientAt(peer, @"", 0, error); }
static BOOL KuroSessionActivationAt(NSString *prefix,uid_t owner,NSString *executingHelper,NSString **error);
static BOOL Authorize(int peer, NSString **error) {
  if (!AuthorizeClient(peer, error)) return NO;
  return KuroSessionActivationAt(@"",0,Executable(),error);
}

#import "tun-peer.m"
#import "tun-session.m"
#import "tun-network.m"
#import "tun-production-network.m"

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
  return @{@"version":@1, @"ok":@YES, @"status":@{@"availability":@"blocked", @"state":off ? @"off" : @"unknown", @"error":off ? @"authenticated recovery is required before a new TUN session" : @"owned process/network cleanup cannot be proven"}};
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

#import "tun-install.m"
#import "tun-auth.m"

#import "tun-service.m"

static void ServicePeer(KuroTunService *service, int peer) {
  @autoreleasepool {
    NSMutableData *request = [NSMutableData data]; BOOL complete = NO, invalid = NO;
    uint64_t deadline = KuroMonotonicMilliseconds() + 2000;
    while (!stopping && request.length <= OpenMessageLimit) {
      uint64_t now = KuroMonotonicMilliseconds(); if (now >= deadline) break;
      struct pollfd ready = {.fd=peer, .events=POLLIN};
      if (poll(&ready, 1, (int)(deadline - now)) <= 0) break;
      char bytes[4096]; ssize_t count = recv(peer, bytes, sizeof(bytes), MSG_DONTWAIT);
      if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
      if (count <= 0) break;
      char *newline = memchr(bytes, '\n', (size_t)count);
      [request appendBytes:bytes length:(NSUInteger)count];
      if (newline) { complete = YES; invalid = newline != bytes + count - 1; break; }
    }
    NSString *error = nil; NSDictionary *response = nil;
    id decoded = complete && !invalid ? KuroDecodeJSON(request, OpenMessageLimit, &error) : nil;
    if ([decoded isKindOfClass:NSDictionary.class] && KuroNumber(decoded[@"version"], 2, 2)) {
      // This worker owns the entire connection and child; status uses other bounded workers.
      (void)[service serveOpenFrame:request peer:peer error:&error];
    } else {
      NSString *operation = decoded ? ParseRequest(request, &error) : nil;
      if ([operation isEqual:@"status"]) response = @{@"version":@1, @"ok":@YES, @"status":[service statusSnapshot]};
      else if ([operation isEqual:@"recover"] && Authorize(peer, &error)) {
        response=[service recoverNetworkOnly:&error] ? @{@"version":@1,@"ok":@YES,@"status":[service statusSnapshot]} : ErrorResponse(error);
      }
      else if ([operation isEqual:@"stop"] && Authorize(peer, &error)) {
        [service requestStop];
        uint64_t limit = KuroMonotonicMilliseconds() + 3000;
        while (![[service statusSnapshot][@"state"] isEqual:@"off"] && KuroMonotonicMilliseconds() < limit) {
          struct timespec pause = {.tv_nsec=10000000}; nanosleep(&pause, NULL);
        }
        NSDictionary *status = [service statusSnapshot];
        response = [status[@"state"] isEqual:@"off"] ? @{@"version":@1,@"ok":@YES,@"status":status} : ErrorResponse(@"owned stop/cleanup is not confirmed");
      } else response = decoded ? ProcessRequest(request, peer, @"", 0) : ErrorResponse(error ?: @"one bounded newline frame is required within two seconds");
      NSData *bytes = [[JSONData(response) mutableCopy] copy];
      NSMutableData *line = [bytes mutableCopy]; [line appendBytes:"\n" length:1];
      (void)send(peer, line.bytes, line.length, MSG_DONTWAIT | MSG_NOSIGNAL);
    }
    close(peer);
  }
}
static KuroTunService *ProductionService(void) {
  KuroTunServiceHooks *hooks = [KuroTunServiceHooks new];
  __block KuroProductionNetwork *network=nil;
  __block KuroPeerIdentity *identity = nil;
  hooks.authorize = ^BOOL(int peer, NSString *digest, NSString **error) {
    if (!Match(digest, @"\\A[0-9a-f]{64}\\z") || !Authorize(peer, error)) return NO;
    identity = [KuroPeerIdentity observePeer:peer error:error]; return identity != nil;
  };
  hooks.identityValid = ^BOOL(int peer) { (void)peer; return identity && identity.isLive; };
  hooks.beforeStart=^BOOL(NSString **error) { return KuroRevokeStoppedProof(@"",0,error); };
  hooks.beforeResume = ^BOOL(NSString **error) { return KuroMarkSessionStarted(@"",0,Executable(),error); };
  hooks.preflight = ^BOOL(NSDictionary *config, NSString **error) {
    network=[[KuroProductionNetwork alloc] initWithDirectory:State owner:0];
    return [network preflightConfig:config error:error];
  };
  hooks.prepareNetwork=^BOOL(NSString *session,NSDictionary *binding,NSString **error) { return [network prepareSession:session binding:binding error:error]; };
  hooks.physicalInterface=^NSString *{ return network.runtimeInterfaceName; };
  hooks.readinessHosts=^NSDictionary *{ return KuroProductionRuntimeFields()[@"hosts"]; };
  hooks.ready=^BOOL(pid_t child,NSString *session,NSString **error) { return [network readyChild:child session:session error:error]; };
  hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **error) { return [network applyChild:child session:session error:error]; };
  hooks.recoverNetwork=^BOOL(NSString *session,NSString **error) { return [network recoverSession:session error:error]; };
  hooks.networkRecoveryObservation=^NSDictionary *{ return network.recoveryObservation; };
  hooks.confirmStopped=^BOOL(NSDictionary *process,NSString **error) {
    NSDictionary *proof=[network stoppedEvidenceForSession:process[@"session"] error:error];
    return proof && KuroMarkSessionStopped(@"",0,Executable(),process,proof,error);
  };
  hooks.verifyNetwork=^BOOL(NSString *session,NSString **error) { return [network confirmSession:session error:error]; };
  hooks.recoverResidualNetwork=^BOOL(NSString **error) {
    KuroProductionNetwork *recovery=[[KuroProductionNetwork alloc] initWithDirectory:State owner:0];
    return [recovery recoverSession:nil error:error];
  };
  hooks.recoverOwnedNetwork=^BOOL(NSDictionary *record,KuroSessionHook stillAbsent,NSString **error) {
    KuroProductionNetwork *recovery=[[KuroProductionNetwork alloc]initWithDirectory:State owner:0];
    return [recovery recoverRecordedOwner:record writerAbsent:stillAbsent error:error]!=nil;
  };
  hooks.recoveredNetworkEvidence=^NSDictionary *(NSDictionary *record,NSString **error) {
    KuroProductionNetwork *recovery=[[KuroProductionNetwork alloc]initWithDirectory:State owner:0];
    return [recovery recoverRecordedOwner:record error:error];
  };
  return [[KuroTunService alloc] initWithHooks:hooks];
}
static void StopSignal(int signalNumber) { (void)signalNumber; stopping = 1; }
// Only tests supply a private installation prefix and service; production has no path selection.
static int ServeAt(NSString *prefix,uid_t owner,KuroTunService *service) {
  NSString *error=nil,*realSocket=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"control.sock"]);
  struct sockaddr_un address;
  if(!service || !KuroUnixSocketAddress(realSocket,&address,&error)) {fprintf(stderr,"%s\n",(error?:@"service unavailable").UTF8String);return 1;}
  int lock=ServiceLock(prefix,owner,&error);
  if(lock<0) {fprintf(stderr,"%s\n",error.UTF8String);return 1;}
  int listener=-1,result=1;BOOL bound=NO,drained=YES;struct stat ownedSocket={0};
  dispatch_group_t workers=dispatch_group_create();
  dispatch_semaphore_t slots=dispatch_semaphore_create(8);
  @try {
    do {
      if(!ControlSocketEndpoint(prefix,owner,lock,NULL,YES,&error))break;
      listener=socket(AF_UNIX,SOCK_STREAM,0);
      if(listener<0 || fcntl(listener,F_SETFD,FD_CLOEXEC) || bind(listener,(struct sockaddr *)&address,sizeof(address))) {Fail(&error,@"control socket bind failed");break;}
      if(lstat(realSocket.fileSystemRepresentation,&ownedSocket) || !S_ISSOCK(ownedSocket.st_mode) || ownedSocket.st_uid!=owner || ownedSocket.st_nlink!=1) {Fail(&error,@"bound control socket identity unavailable; preserved");break;}
      bound=YES;
      if(chmod(realSocket.fileSystemRepresentation,0666)) {Fail(&error,@"control socket mode setup failed");break;}
      ownedSocket.st_mode=(ownedSocket.st_mode&~07777)|0666;
      struct stat current;
      if(lstat(realSocket.fileSystemRepresentation,&current) || current.st_dev!=ownedSocket.st_dev || current.st_ino!=ownedSocket.st_ino || current.st_mode!=ownedSocket.st_mode || current.st_uid!=owner || current.st_nlink!=1 || listen(listener,8)) {Fail(&error,@"control socket listen or identity setup failed");break;}
      stopping=0;signal(SIGTERM,StopSignal);signal(SIGINT,StopSignal);signal(SIGPIPE,SIG_IGN);
      result=0;
      while(!stopping) {
        struct pollfd pending={.fd=listener,.events=POLLIN};int ready=poll(&pending,1,500);
        if(ready<0 && errno==EINTR)continue;
        if(ready<0 || (ready>0 && (pending.revents&(POLLERR|POLLHUP|POLLNVAL)))) {Fail(&error,@"control listener failed");result=1;break;}
        if(!ready)continue;
        int peer=accept(listener,NULL,NULL);if(peer<0)continue;
        if(dispatch_semaphore_wait(slots,DISPATCH_TIME_NOW)) {close(peer);continue;}
        dispatch_group_async(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
          ServicePeer(service,peer);dispatch_semaphore_signal(slots);
        });
      }
    } while(NO);
  } @finally {
    if(listener>=0)close(listener);
    [service requestShutdown];
    drained=dispatch_group_wait(workers,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
    if(!drained) {Fail(&error,@"control workers did not drain; service lock retained until process exit");result=1;}
    NSString *cleanupError=nil;
    if(bound && !ControlSocketEndpoint(prefix,owner,lock,&ownedSocket,YES,&cleanupError)) {if(!error)error=cleanupError;result=1;}
    // Unknown workers must never overlap a new helper in this namespace.
    if(drained)close(lock);
  }
  if(result)fprintf(stderr,"%s\n",(error?:@"control service failed").UTF8String);
  return result;
}
static int Serve(void) {return ServeAt(@"",0,ProductionService());}

#if !defined(KURO_TESTING) && !defined(KURO_CORE_EXPERIMENT)
int main(int argc, const char **argv) {
  @autoreleasepool {
    if (geteuid() != 0 || argc != 2) { fprintf(stderr, "root-only fixed CLI: --serve | --preflight-install | --install | --uninstall\n"); return 1; }
    if (!strcmp(argv[1], "--begin-client-upgrade") || !strcmp(argv[1], "--complete-client-upgrade")) {
      NSString *error=nil,*scripts=Executable().stringByDeletingLastPathComponent;
      BOOL ok=!strcmp(argv[1], "--begin-client-upgrade")?BeginClientUpgradeFromScripts(@"",0,YES,scripts,&error):CompleteClientUpgradeFromScripts(@"",0,YES,scripts,&error);
      if(!ok)fprintf(stderr,"%s\n",(error?:@"upgrade refused").UTF8String);return ok?0:1;
    }
    if (!strcmp(argv[1], "--recover-client-upgrade")) {NSString *error=nil;BOOL ok=RecoverClientUpgrade(@"",0,YES,Executable(),&error);if(!ok)fprintf(stderr,"%s\n",(error?:@"upgrade recovery refused").UTF8String);return ok?0:1;}
    if (!strcmp(argv[1], "--serve")) return Serve();
    if (!strcmp(argv[1], "--serve-auth")) return ServeAuth();
    if (!strcmp(argv[1], "--begin-client-install")) {
      NSString *error=nil;
      BOOL ok=BeginClientInstall(@"",0,YES,&error);
      if(!ok)fprintf(stderr,"%s\n",(error ?: @"fresh installation approval failed").UTF8String);
      return ok ? 0 : 1;
    }
    if (strcmp(argv[1], "--install") && strcmp(argv[1], "--uninstall") && strcmp(argv[1], "--preflight-install") && strcmp(argv[1], "--preflight-client-install")) return 1;
    NSString *error = nil;
    NSString *entry = Executable();
    if (!strcmp(argv[1], "--preflight-client-install")) {
      // Installer must not overwrite an existing App before its pin can be checked.
      NSString *parent = ClientBundle.stringByDeletingLastPathComponent;
      BOOL ok = !Exists(parent);
      NSString *ancestor = parent.stringByDeletingLastPathComponent;
      while (ok && !Exists(ancestor)) ancestor = ancestor.stringByDeletingLastPathComponent;
      ok = ok && SafeChain(@"", ancestor, 0, YES, &error);
      if (!ok) fprintf(stderr, "existing or unprotected client installation preserved\n");
      return ok ? 0 : 1;
    }
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
    else if(!installing)puts("Helper/App uninstall complete; diagnostic evidence, if any, is retained at /Library/Application Support/Clash Kuro/TunDiagnostics and was not deleted.");
    return ok ? 0 : 1;
  }
}
#endif
