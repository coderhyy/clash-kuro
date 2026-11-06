// Internal DNS ownership primitive. Not an RPC or permission to start TUN:
// route ownership and Core DNS-readiness gates must succeed at its caller.
#import <SystemConfiguration/SystemConfiguration.h>
#import "tun-routes.m"
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
      !Match(key, @"\\A(State|Setup):/Network/(Global|Service/[^/]+|Interface/[a-zA-Z][a-zA-Z0-9]{0,14})/DNS\\z")) { Fail(error,@"DNS preflight found retained ownership or unsupported resolver key"); return nil; }
    NSDictionary *value=records[key];
    if (![value isKindOfClass:NSDictionary.class]) { Fail(error,@"DNS record is not a mapping"); return nil; }
    for (NSString *field in value) if (![@[@"ServerAddresses",@"ServerPort",@"SearchOrder",@"SearchDomains",@"DomainName",@"SupplementalMatchDomains",@"SupplementalMatchOrders",@"SupplementalMatchDomainsNoSearch",@"InterfaceIndex",@"__CONFIGURATION_ID__",@"__ORDER__",@"__IF_INDEX__",@"__FLAGS__"]containsObject:field]) {
      Fail(error,[NSString stringWithFormat:@"unsupported DNS resolver field %@; preserving existing configuration",field]); return nil;
    }
    // configd's State Global default-resolver metadata is retained verbatim.
    // __IF_INDEX__ selects the resolver interface; the coordinator consumes it.
    // Only the observed default shape/query flags are supported, not scoped,
    // service-specific or supplemental private configurations.
    NSArray *metadata=@[@"__CONFIGURATION_ID__",@"__ORDER__",@"__IF_INDEX__",@"__FLAGS__"];
    BOOL hasMetadata=NO; for(NSString *field in metadata)if(value[field])hasMetadata=YES;
    if(hasMetadata) {
      if(![key isEqual:@"State:/Network/Global/DNS"] ||
        !Match(value[@"__CONFIGURATION_ID__"],@"\\ADefault: [0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12} 0\\z") ||
        !KuroNumber(value[@"__ORDER__"],0,INT32_MAX) || !KuroNumber(value[@"__IF_INDEX__"],1,UINT16_MAX) ||
        !KuroNumber(value[@"__FLAGS__"],0,UINT32_MAX) || ([value[@"__FLAGS__"]unsignedIntValue]&~(uint32_t)0x0006) ||
        (value[@"InterfaceIndex"] && ![value[@"InterfaceIndex"]isEqual:value[@"__IF_INDEX__"]])) {
        Fail(error,@"unsupported Global default DNS metadata or conflicting interface; preserving existing resolver");return nil;
      }
    }
    NSArray *servers=value[@"ServerAddresses"];
    if (![servers isKindOfClass:NSArray.class] || !servers.count || servers.count>16) { Fail(error,@"DNS record lacks bounded explicit servers"); return nil; }
    for (NSString *server in servers) if (!KuroDNSIP(server)) { Fail(error,@"DNS server address is unsupported (including scoped literals)"); return nil; }
    if ((value[@"ServerPort"] && ![value[@"ServerPort"]isEqual:@53]) || (value[@"SearchOrder"] && !KuroNumber(value[@"SearchOrder"],0,UINT32_MAX)) ||
      (value[@"InterfaceIndex"] && !KuroNumber(value[@"InterfaceIndex"],1,UINT16_MAX)) ||
      (value[@"SupplementalMatchDomainsNoSearch"] && !KuroNumber(value[@"SupplementalMatchDomainsNoSearch"],0,1))) { Fail(error,@"unsupported DNS port/order/interface metadata"); return nil; }
    for (NSString *field in @[@"SearchDomains",@"SupplementalMatchDomains"]) if (value[field]) {
      NSArray *domains=value[field];
      if (![domains isKindOfClass:NSArray.class] || domains.count>64) { Fail(error,@"DNS domain list exceeds bounds"); return nil; }
      for (NSString *domain in domains) if (![domain isKindOfClass:NSString.class] || domain.length>253 || !Match(domain,@"\\A[a-zA-Z0-9_-]+(?:\\.[a-zA-Z0-9_-]+)*\\.?\\z")) { Fail(error,@"unsupported or competing catch-all DNS domain; preserving original resolver"); return nil; }
    }
    if (value[@"DomainName"] && (![value[@"DomainName"]isKindOfClass:NSString.class] || ([value[@"DomainName"]length] && !Match(value[@"DomainName"],@"\\A[a-zA-Z0-9_-]+(?:\\.[a-zA-Z0-9_-]+)*\\.?\\z")))) { Fail(error,@"unsupported DNS search domain"); return nil; }
    if (value[@"SupplementalMatchOrders"]) {
      NSArray *orders=value[@"SupplementalMatchOrders"],*domains=value[@"SupplementalMatchDomains"];
      if (![orders isKindOfClass:NSArray.class] || !domains || orders.count!=domains.count) { Fail(error,@"split DNS domain/order mismatch"); return nil; }
      for (id order in orders) if (!KuroNumber(order,0,UINT32_MAX)) { Fail(error,@"invalid split DNS order"); return nil; }
    }
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
#ifdef KURO_TESTING
// Isolated journal primitive tests; production activation requires route/probe admission.
- (BOOL)installForSession:(NSString *)session error:(NSString **)error;
#endif
// Production caller supplies held-session route authority and an actual internal
// DNS probe, never booleans/config fields received from the App.
- (BOOL)installForSession:(NSString *)session routes:(KuroOwnedRoutes *)routes interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership dnsReady:(BOOL (^)(NSString **))dnsReady error:(NSString **)error;
// Only proves this component's recorded key was removed/absent; never Core or routes off.
- (BOOL)recoverDNS:(NSString **)error;
- (BOOL)recoverDNSAbsence:(NSString **)error;
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
- (BOOL)installForSession:(NSString *)session routes:(KuroOwnedRoutes *)routes interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership dnsReady:(BOOL (^)(NSString **))dnsReady error:(NSString **)error {
  _dnsOff=NO;
  BOOL (^admission)(NSString **)=^BOOL(NSString **failure) {
    return routes && [routes confirmInstalledSession:session interface:association ownership:ownership error:failure];
  };
  if (![self onThread:error] || !dnsReady || !admission(error) || !dnsReady(error) || !admission(error)) return Fail(error,@"DNS activation requires current route receipts and a successful internal resolver probe");
  return [self installPreparedSession:session admission:admission error:error];
}
#ifdef KURO_TESTING
- (BOOL)installForSession:(NSString *)session error:(NSString **)error {
  return [self installPreparedSession:session admission:^BOOL(NSString **failure) { (void)failure; return YES; } error:error];
}
#endif
- (BOOL)protectedDirectory:(NSString **)error {
  NSString *anchor=@"";
#ifdef KURO_TESTING
  anchor=_directory;
#endif
  return SafeChain(anchor,_directory,_owner,YES,error);
}
- (BOOL)installPreparedSession:(NSString *)session admission:(BOOL (^)(NSString **))admission error:(NSString **)error {
  if (![self onThread:error] || !admission || !admission(error)) return NO;
  _dnsOff = NO;
  NSString *key = KuroDNSKey(session), *path = [_directory stringByAppendingPathComponent:KuroDNSJournal];
  if (!key || ![self protectedDirectory:error] || Exists(path)) return Fail(error, @"DNS install requires a canonical session and protected clean journal directory");
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
  if (!admission(error) || ![_backend addTemporaryDNSValue:KuroDNSValue() key:key error:error]) return NO;
  failure = nil;
  id observed = [_backend valueForDNSKey:key error:&failure];
  if (failure || ![observed isEqual:KuroDNSValue()] || !admission(error)) return Fail(error, @"temporary DNS write was not independently confirmed; journal retained");
  return YES;
}
- (BOOL)recoverDNS:(NSString **)error { return [self recoverDNSAllowRemoval:YES error:error]; }
- (BOOL)recoverDNSAbsence:(NSString **)error { return [self recoverDNSAllowRemoval:NO error:error]; }
- (BOOL)recoverDNSAllowRemoval:(BOOL)allowRemoval error:(NSString **)error {
  if (![self onThread:error]) return NO;
  _dnsOff = NO;
  if (![self protectedDirectory:error]) return NO;
  NSString *path = [_directory stringByAppendingPathComponent:KuroDNSJournal];
  NSString *failure = nil;
  NSDictionary *records = [_backend dnsRecords:&failure];
  if (failure || ![records isKindOfClass:NSDictionary.class]) return Fail(error, @"DNS recovery cannot observe retained keys");
  if (!Exists(path)) {
    for (NSString *key in records) if (![key isKindOfClass:NSString.class] || [key hasPrefix:KuroDNSPrefix]) return Fail(error, @"retained DNS key has no ownership journal; refusing deletion");
    if(![self syncDirectory:error])return NO;
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
    if (!allowRemoval) return Fail(error,@"DNS key remains after helper restart; preserving key and receipt without write authority");
    // SCDynamicStore has no public conditional remove/CAS. This is a unique
    // helper-generated UUID key on one serial session; observed changed values are preserved.
    if (![observed isEqual:record[@"after"]]) return Fail(error, @"DNS target changed; preserving third-party value and ownership journal");
    // Revalidate both authorities immediately before the non-CAS store removal.
    // The protected journal/unique UUID do not authorize removing changed values.
    if(![ReadProtected(_directory,path,_owner,error)isEqual:bytes])return Fail(error,@"DNS journal changed before removal; preserve key and receipt");
    NSDictionary *latest=[_backend dnsRecords:&failure];
    if(failure || ![latest isKindOfClass:NSDictionary.class])return Fail(error,@"DNS removal cannot reobserve retained keys");
    for(NSString *key in latest)if(![key isKindOfClass:NSString.class] || ([key hasPrefix:KuroDNSPrefix] && ![key isEqual:record[@"key"]]))return Fail(error,@"additional DNS owner appeared before removal; preserve keys");
    failure=nil;id current=[_backend valueForDNSKey:record[@"key"] error:&failure];
    if(failure || ![current isEqual:record[@"after"]])return Fail(error,@"DNS target changed before removal; preserve key and receipt");
    if(![ReadProtected(_directory,path,_owner,error)isEqual:bytes])return Fail(error,@"DNS journal changed before removal; preserve key and receipt");
    if (![_backend removeDNSKey:record[@"key"] error:error]) return NO;
    failure = nil;
    if ([_backend valueForDNSKey:record[@"key"] error:&failure] || failure) return Fail(error, @"DNS key removal was not confirmed; journal retained");
  }
  // Re-read protected bytes before deleting only our journal. A missing
  // temporary key after helper death does not imply routes or Core have stopped.
  failure=nil;
  if ([_backend valueForDNSKey:record[@"key"] error:&failure] || failure) return Fail(error,@"DNS key reappeared before absence receipt retirement");
  NSData *unchanged = ReadProtected(_directory, path, _owner, error);
  if (![unchanged isEqual:bytes] || unlink(path.fileSystemRepresentation) || ![self syncDirectory:error]) return Fail(error, @"DNS journal removal was not safely completed");
  _dnsOff = YES;
  return YES;
}
@end

static BOOL KuroNetworkRoutesReady(NSString **error) {
  return Fail(error, @"route preparation blocked: exact live utun owner/kernel route semantics have not passed controlled acceptance");
}
static BOOL KuroNetworkCoreDNSReady(NSString **error) {
  return Fail(error, @"DNS activation blocked: fixed internal resolver reachability and scoped/LAN preservation are not proven");
}
