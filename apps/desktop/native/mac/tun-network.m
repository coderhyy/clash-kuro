// Internal DNS ownership primitive. Not an RPC or permission to start TUN:
// route ownership and Core DNS-readiness gates must succeed at its caller.
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <pthread.h>

@protocol KuroDNSStore <NSObject>
- (NSDictionary *)dnsRecords:(NSString **)error;
// nil with no error means this exact key is absent; nil with error means unknown.
- (id)valueForDNSKey:(NSString *)key error:(NSString **)error;
- (BOOL)addTemporaryDNSValue:(NSDictionary *)value key:(NSString *)key error:(NSString **)error;
- (BOOL)removeDNSKey:(NSString *)key error:(NSString **)error;
@end

@interface KuroDarwinDNSStore : NSObject <KuroDNSStore> { SCDynamicStoreRef _store; }
- (instancetype)initWithError:(NSString **)error;
@end
@implementation KuroDarwinDNSStore
- (instancetype)initWithError:(NSString **)error {
  if (!(self = [super init])) return nil;
  if (geteuid() != 0) { Fail(error, @"production DNS store requires the authenticated root helper"); return nil; }
  _store = SCDynamicStoreCreate(NULL, CFSTR("Clash Kuro owned DNS"), NULL, NULL);
  if (!_store) { Fail(error, @"SCDynamicStore connection unavailable"); return nil; }
  return self;
}
- (void)dealloc { if (_store) CFRelease(_store); }
- (NSDictionary *)dnsRecords:(NSString **)error {
  NSArray *patterns = @[@"^(State|Setup):/Network/.*/DNS$"];
  CFDictionaryRef values = SCDynamicStoreCopyMultiple(_store, NULL, (__bridge CFArrayRef)patterns);
  if (!values) { Fail(error, @"DNS records could not be observed"); return nil; }
  return CFBridgingRelease(values);
}
- (id)valueForDNSKey:(NSString *)key error:(NSString **)error {
  CFPropertyListRef value = SCDynamicStoreCopyValue(_store, (__bridge CFStringRef)key);
  if (value) return CFBridgingRelease(value);
  if (SCError() != kSCStatusNoKey) Fail(error, @"owned DNS key readback failed; state unknown");
  return nil;
}
- (BOOL)addTemporaryDNSValue:(NSDictionary *)value key:(NSString *)key error:(NSString **)error {
  return SCDynamicStoreAddTemporaryValue(_store, (__bridge CFStringRef)key, (__bridge CFPropertyListRef)value)
    || Fail(error, @"temporary DNS insertion failed; inspect the prepared journal");
}
- (BOOL)removeDNSKey:(NSString *)key error:(NSString **)error {
  return SCDynamicStoreRemoveValue(_store, (__bridge CFStringRef)key)
    || Fail(error, @"owned DNS key removal failed; recovery remains required");
}
@end

static NSString *const KuroDNSPrefix = @"State:/Network/Service/dev.kuro.tun.";
static NSString *const KuroDNSJournal = @"network-dns.json";
static NSDictionary *KuroDNSValue(void) {
  // Only the fixed internal dual-stack resolver. No new upstream provider or
  // broad port-53 hijack is selected here. Reachability is a separate gate.
  return @{ @"ServerAddresses": @[@"198.18.0.2", @"fdfe:dcba:9876::2"],
    @"SupplementalMatchDomains": @[@""], @"SupplementalMatchOrders": @[@1] };
}
static NSString *KuroDNSKey(NSString *session) {
  if (![session isKindOfClass:NSString.class]) return nil;
  NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:session];
  if (!identifier || ![identifier.UUIDString isEqual:session]) return nil;
  return [[KuroDNSPrefix stringByAppendingString:session] stringByAppendingString:@"/DNS"];
}
static BOOL KuroDNSIP(NSString *address) {
  if (![address isKindOfClass:NSString.class] || address.length > 45 || [address rangeOfString:@"%"].location != NSNotFound) return NO;
  struct in_addr v4; struct in6_addr v6;
  return inet_pton(AF_INET, address.UTF8String, &v4) == 1 || inet_pton(AF_INET6, address.UTF8String, &v6) == 1;
}
static NSDictionary *KuroDNSPreflight(NSDictionary *records, NSString **error) {
  if (![records isKindOfClass:NSDictionary.class] || !records.count || records.count > 256) { Fail(error, @"DNS preflight lacks a bounded default-resolver snapshot"); return nil; }
  for (NSString *key in records) {
    if (![key isKindOfClass:NSString.class] || [key hasPrefix:KuroDNSPrefix] ||
      !Match(key, @"\\A(State|Setup):/Network/(Global|Service/[^/]+)/DNS\\z")) { Fail(error, @"DNS preflight found retained ownership or unsupported scoped/interface DNS"); return nil; }
    NSDictionary *value = records[key];
    if (![value isKindOfClass:NSDictionary.class]) { Fail(error, @"DNS preflight record is not a mapping"); return nil; }
    for (NSString *field in value) {
      if (![@[@"ServerAddresses", @"ServerPort", @"SearchOrder", @"SearchDomains", @"DomainName"] containsObject:field]) { Fail(error, @"DNS preflight cannot preserve supplemental/scoped DNS or an unknown resolver field"); return nil; }
    }
    if ((value[@"SearchDomains"] && (![value[@"SearchDomains"] isKindOfClass:NSArray.class] || [value[@"SearchDomains"] count])) ||
      (value[@"DomainName"] && ![value[@"DomainName"] isEqual:@""])) { Fail(error, @"DNS preflight cannot prove LAN/search-domain preservation; refusing DNS takeover"); return nil; }
    NSArray *servers = value[@"ServerAddresses"];
    if (![servers isKindOfClass:NSArray.class] || !servers.count || servers.count > 16) { Fail(error, @"DNS preflight has no explicit bounded resolver addresses"); return nil; }
    for (NSString *server in servers) if (!KuroDNSIP(server)) { Fail(error, @"DNS preflight contains an unsupported resolver address"); return nil; }
    if ((value[@"ServerPort"] && ![value[@"ServerPort"] isEqual:@53]) ||
      (value[@"SearchOrder"] && !KuroNumber(value[@"SearchOrder"], 0, UINT32_MAX))) { Fail(error, @"DNS preflight contains unsupported resolver port/order"); return nil; }
  }
  NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:records format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  if (!bytes || bytes.length > MessageLimit) { Fail(error, @"DNS preflight snapshot is oversized or invalid"); return nil; }
  // A stable immutable snapshot, independent of a mutable test/adapter backend.
  return [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL];
}

@interface KuroOwnedDNS : NSObject {
  id<KuroDNSStore> _backend;
  NSString *_directory;
  uid_t _owner;
  pthread_t _thread;
  BOOL _dnsOff;
}
@property(nonatomic, readonly) BOOL dnsOff;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroDNSStore>)backend;
// Only writes our temporary key. It does not prove usable DNS or full TUN on.
- (BOOL)installForSession:(NSString *)session error:(NSString **)error;
// Only proves this component's recorded key was removed/absent; never Core or routes off.
- (BOOL)recoverDNS:(NSString **)error;
@end
@implementation KuroOwnedDNS
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroDNSStore>)backend {
  if ((self = [super init])) { _directory = [directory copy]; _owner = owner; _backend = backend; _thread = pthread_self(); }
  return self;
}
- (BOOL)dnsOff { return _dnsOff; }
- (BOOL)onThread:(NSString **)error {
  return (_backend && pthread_equal(_thread, pthread_self())) || Fail(error, @"DNS ownership operations require their owning serial thread/backend");
}
- (BOOL)syncDirectory:(NSString **)error {
  int descriptor = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  BOOL ok = descriptor >= 0 && !fsync(descriptor); if (descriptor >= 0) close(descriptor);
  return ok || Fail(error, @"DNS journal directory could not be synchronized");
}
- (BOOL)installForSession:(NSString *)session error:(NSString **)error {
  if (![self onThread:error]) return NO;
  _dnsOff = NO;
  NSString *key = KuroDNSKey(session), *path = [_directory stringByAppendingPathComponent:KuroDNSJournal];
  if (!key || !SafeChain(_directory, _directory, _owner, YES, error) || Exists(path)) return Fail(error, @"DNS install requires a canonical session and protected clean journal directory");
  NSString *failure = nil;
  NSDictionary *baseline = KuroDNSPreflight([_backend dnsRecords:&failure], &failure);
  if (!baseline) return Fail(error, failure ?: @"DNS preflight failed");
  id before = [_backend valueForDNSKey:key error:&failure];
  if (failure || before) return Fail(error, @"DNS target key is occupied or cannot be observed; no existing value will be replaced");
  NSDictionary *record = @{ @"format": @1, @"kind": @"dns-temporary-v1", @"session": session, @"key": key,
    @"before": NSNull.null, @"after": KuroDNSValue(), @"baseline": baseline };
  NSData *bytes = JSONData(record);
  if (!bytes || bytes.length > MessageLimit) return Fail(error, @"DNS ownership journal exceeds the bounded format");
  if (!WriteNew(path, bytes, 0600, error) || ![self syncDirectory:error]) return NO;
  // The prepared record survives every subsequent failure, including a backend
  // that reports failure after the insertion actually landed.
  NSDictionary *current = [_backend dnsRecords:&failure];
  if (failure || ![current isEqual:baseline]) return Fail(error, @"DNS changed after preflight; prepared journal retained without writing DNS");
  if (![_backend addTemporaryDNSValue:KuroDNSValue() key:key error:error]) return NO;
  failure = nil;
  id observed = [_backend valueForDNSKey:key error:&failure];
  if (failure || ![observed isEqual:KuroDNSValue()]) return Fail(error, @"temporary DNS write was not independently confirmed; journal retained");
  return YES;
}
- (BOOL)recoverDNS:(NSString **)error {
  if (![self onThread:error]) return NO;
  _dnsOff = NO;
  if (!SafeChain(_directory, _directory, _owner, YES, error)) return NO;
  NSString *path = [_directory stringByAppendingPathComponent:KuroDNSJournal];
  NSString *failure = nil;
  NSDictionary *records = [_backend dnsRecords:&failure];
  if (failure || ![records isKindOfClass:NSDictionary.class]) return Fail(error, @"DNS recovery cannot observe retained keys");
  if (!Exists(path)) {
    for (NSString *key in records) if (![key isKindOfClass:NSString.class] || [key hasPrefix:KuroDNSPrefix]) return Fail(error, @"retained DNS key has no ownership journal; refusing deletion");
    _dnsOff = YES; return YES;
  }
  struct stat metadata;
  if (lstat(path.fileSystemRepresentation, &metadata) || metadata.st_size < 0 || metadata.st_size > (off_t)MessageLimit) return Fail(error, @"DNS journal is unavailable or exceeds the bounded format");
  NSData *bytes = ReadProtected(_directory, path, _owner, error);
  NSDictionary *record = bytes ? KuroDecodeJSON(bytes, MessageLimit, error) : nil;
  if (!Keys(record, @[@"format", @"kind", @"session", @"key", @"before", @"after", @"baseline"]) || !KuroNumber(record[@"format"], 1, 1) ||
    ![record[@"kind"] isEqual:@"dns-temporary-v1"] || ![record[@"key"] isEqual:KuroDNSKey(record[@"session"])] ||
    record[@"before"] != NSNull.null || ![record[@"after"] isEqual:KuroDNSValue()] || !KuroDNSPreflight(record[@"baseline"], error)) return Fail(error, @"DNS recovery journal is incomplete or not this fixed operation");
  for (NSString *key in records) if (![key isKindOfClass:NSString.class] || ([key hasPrefix:KuroDNSPrefix] && ![key isEqual:record[@"key"]])) return Fail(error, @"multiple/unrecorded DNS owners require manual recovery");
  id observed = [_backend valueForDNSKey:record[@"key"] error:&failure];
  if (failure) return Fail(error, @"DNS recovery readback failed; ownership unknown");
  if (observed) {
    // SCDynamicStore has no public conditional remove/CAS. This is a unique
    // root-owned UUID key on one serial writer; changed values are never removed.
    if (![observed isEqual:record[@"after"]]) return Fail(error, @"DNS target changed; preserving third-party value and ownership journal");
    if (![_backend removeDNSKey:record[@"key"] error:error]) return NO;
    failure = nil;
    if ([_backend valueForDNSKey:record[@"key"] error:&failure] || failure) return Fail(error, @"DNS key removal was not confirmed; journal retained");
  }
  // Re-read protected bytes before deleting only our journal. A missing
  // temporary key after helper death does not imply routes or Core have stopped.
  NSData *unchanged = ReadProtected(_directory, path, _owner, error);
  if (![unchanged isEqual:bytes] || unlink(path.fileSystemRepresentation) || ![self syncDirectory:error]) return Fail(error, @"DNS journal removal was not safely completed");
  _dnsOff = YES;
  return YES;
}
@end

static BOOL KuroNetworkRoutesReady(NSString **error) {
  return Fail(error, @"route preparation blocked: exact live utun owner and journal/readback are not implemented");
}
static BOOL KuroNetworkCoreDNSReady(NSString **error) {
  return Fail(error, @"DNS activation blocked: fixed internal resolver reachability and scoped/LAN preservation are not proven");
}
