// Core owns all route mutations. This module observes a fixed plan and can
// retire an observation only after its recorded keys are independently absent.
#import "tun-interface.m"
#include <arpa/inet.h>
#include <net/route.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <sys/sysctl.h>
#include <pthread.h>
static const NSUInteger KuroRouteLimit=16,KuroRouteDumpLimit=1024*1024;
static NSString *const KuroRouteJournal=@"network.json";
static NSUInteger KuroRouteAligned(NSUInteger length) { return length ? (length + 3) & ~(NSUInteger)3 : 4; }
static NSData *KuroRouteIP(id text, int family) {
  if (![text isKindOfClass:NSString.class] || [text containsString:@"%"] || (family != 4 && family != 6)) return nil;
  unsigned char bytes[16] = {0};
  if (inet_pton(family == 4 ? AF_INET : AF_INET6, [text UTF8String], bytes) != 1) return nil;
  char canonical[INET6_ADDRSTRLEN] = {0};
  if (!inet_ntop(family == 4 ? AF_INET : AF_INET6, bytes, canonical, sizeof(canonical)) || ![text isEqual:@(canonical)]) return nil;
  return [NSData dataWithBytes:bytes length:family == 4 ? 4 : 16];
}
static BOOL KuroLegacyRouteEntry(id entry) {
  if (!Keys(entry, @[@"family", @"destination", @"prefix", @"gateway", @"interfaceIndex", @"interfaceName"]) ||
    !KuroNumber(entry[@"family"], 4, 6) || ![@[@4,@6] containsObject:entry[@"family"]] ||
    !KuroNumber(entry[@"prefix"], 1, [entry[@"family"] intValue] == 4 ? 32 : 128) ||
    !KuroNumber(entry[@"interfaceIndex"], 1, UINT16_MAX) || !Match(entry[@"interfaceName"], @"\\Autun(?:0|[1-9][0-9]{0,8})\\z")) return NO;
  int family = [entry[@"family"] intValue], prefix = [entry[@"prefix"] intValue];
  NSData *address = KuroRouteIP(entry[@"destination"], family);
  if (!address) return NO;
  const unsigned char *bytes = address.bytes;
  for (NSUInteger bit = (NSUInteger)prefix; bit < address.length * 8; bit++) if (bytes[bit / 8] & (0x80 >> (bit % 8))) return NO;
  if ([entry[@"gateway"] isEqual:@"link"]) return YES;
  NSData *gateway = KuroRouteIP(entry[@"gateway"], family);
  if (!gateway) return NO;
  const unsigned char *g = gateway.bytes; BOOL zero = YES;
  for (NSUInteger i = 0; i < gateway.length; i++) if (g[i]) zero = NO;
  return !zero && (family == 4 ? g[0] != 0 && g[0] < 224 : g[0] != 255 && !(g[0] == 0xfe && (g[1] & 0xc0) == 0x80));
}
static NSDictionary *KuroRouteAssociation(KuroCoreInterface value) {
  if (value.process.pid <= 0 || !value.process.startSeconds || value.process.startMicros >= 1000000 || value.descriptor < 0 ||
    !value.controlID || !value.controlUnit || !value.socketHandle || !value.pcbHandle || !value.interfaceIndex || value.interfaceIndex > UINT16_MAX ||
    !memchr(value.interfaceName, 0, sizeof(value.interfaceName))) return nil;
  NSString *name = @(value.interfaceName);
  if (![name isEqual:[NSString stringWithFormat:@"utun%u", value.controlUnit - 1]]) return nil;
  return @{@"pid":@(value.process.pid),@"startSeconds":@(value.process.startSeconds),@"startMicros":@(value.process.startMicros),
    @"descriptor":@(value.descriptor),@"controlID":@(value.controlID),@"controlUnit":@(value.controlUnit),
    @"socketHandle":[NSString stringWithFormat:@"%llu", (unsigned long long)value.socketHandle],@"pcbHandle":[NSString stringWithFormat:@"%llu", (unsigned long long)value.pcbHandle],
    @"interfaceIndex":@(value.interfaceIndex),@"interfaceName":name};
}
// This callback must use current authority (held child/session), never just a PID
// read back from the journal. Unknown/restart-only observations cannot authorize writes.
typedef NS_ENUM(NSUInteger, KuroRouteOwnerState) { KuroRouteOwnerUnknown, KuroRouteOwnerLive, KuroRouteOwnerExitedInterfaceGone };
typedef KuroRouteOwnerState (^KuroRouteOwnership)(KuroCoreInterface expected, NSString **error);

static NSString *KuroRouteAddress(NSData *address, int family, BOOL mask) {
  NSUInteger offset = family == 4 ? offsetof(struct sockaddr_in,sin_addr) : offsetof(struct sockaddr_in6,sin6_addr), length = family == 4 ? 4 : 16;
  NSUInteger full=family==4?sizeof(struct sockaddr_in):sizeof(struct sockaddr_in6);
  if ((!mask && address.length!=full) || address.length>full) return nil;
  // Kernel netmasks are radix byte masks, not sockaddr address families.
  // Darwin may fill sa_family/port bytes with 0xff; destination selects family.
  if (!mask && family==6) {
    struct sockaddr_in6 raw={0}; memcpy(&raw,address.bytes,address.length);
    if (raw.sin6_scope_id || raw.sin6_flowinfo || raw.sin6_port) return nil;
  }
  if (!mask && family==4) { struct sockaddr_in raw={0}; memcpy(&raw,address.bytes,address.length); if (raw.sin_port) return nil; }
  unsigned char bytes[16] = {0};
  if (address.length > offset) memcpy(bytes,(const char *)address.bytes+offset,MIN(length,address.length-offset));
  char result[INET6_ADDRSTRLEN] = {0};
  return inet_ntop(family == 4 ? AF_INET : AF_INET6,bytes,result,sizeof(result)) ? @(result) : nil;
}
// Scope is read-only baseline metadata, never admitted in a desired write.
// Darwin may embed the zone in link-local bytes (KAME) or sin6_scope_id.
static NSString *KuroRouteObservedAddress(NSData *data, int family, unsigned int index) {
  if (family!=6 || data.length!=sizeof(struct sockaddr_in6)) return KuroRouteAddress(data,family,NO);
  struct sockaddr_in6 value={0}; memcpy(&value,data.bytes,sizeof(value));
  if (value.sin6_port || value.sin6_flowinfo) return nil;
  unsigned char *bytes=value.sin6_addr.s6_addr; BOOL scoped=IN6_IS_ADDR_LINKLOCAL(&value.sin6_addr) || (bytes[0]==0xff && (bytes[1]&0x0f)<=2);
  uint32_t embedded=scoped?((uint32_t)bytes[2]<<8)|bytes[3]:0;
  if ((value.sin6_scope_id || embedded) && (!scoped || !index || (value.sin6_scope_id && value.sin6_scope_id!=index) || (embedded && embedded!=index))) return nil;
  if (embedded) bytes[2]=bytes[3]=0;
  value.sin6_scope_id=0; NSString *plain=KuroRouteAddress([NSData dataWithBytes:&value length:sizeof(value)],6,NO);
  return plain && scoped?[plain stringByAppendingFormat:@"%%%u",index]:plain;
}
// Pure bounded NET_RT_DUMP/rt_msghdr decoder. No interface or route lookup occurs.
static NSArray<NSDictionary *> *KuroRouteDecodeDump(NSData *dump, NSString **error) {
  if (![dump isKindOfClass:NSData.class] || dump.length > KuroRouteDumpLimit) { Fail(error,@"route dump exceeds bound"); return nil; }
  NSMutableArray *routes=[NSMutableArray array]; NSUInteger offset=0;
  while (offset < dump.length) {
    if (dump.length-offset < sizeof(struct rt_msghdr)) { Fail(error,@"truncated route header"); return nil; }
    struct rt_msghdr header; memcpy(&header,(const char *)dump.bytes+offset,sizeof(header));
    if (header.rtm_version != RTM_VERSION || header.rtm_type != RTM_GET || header.rtm_errno || header.rtm_msglen < sizeof(header) || header.rtm_msglen > dump.length-offset || (header.rtm_addrs & ~((1<<RTAX_MAX)-1))) { Fail(error,@"unsupported route dump message"); return nil; }
    NSUInteger cursor=offset+sizeof(header), end=offset+header.rtm_msglen; NSMutableArray *addresses=[NSMutableArray array];
    for (int bit=0;bit<RTAX_MAX;bit++) {
      if (!(header.rtm_addrs & (1<<bit))) { [addresses addObject:NSNull.null]; continue; }
      if (end-cursor < 2) { Fail(error,@"truncated route sockaddr"); return nil; }
      const unsigned char *sa=(const unsigned char *)dump.bytes+cursor; NSUInteger length=sa[0], aligned=KuroRouteAligned(length);
      if ((length && length < 2) || aligned > end-cursor) { Fail(error,@"invalid route sockaddr length"); return nil; }
      [addresses addObject:[NSData dataWithBytes:sa length:length]]; cursor+=aligned;
    }
    if (cursor != end || routes.count >= 4096) { Fail(error,@"route dump has trailing bytes or too many routes"); return nil; }
    offset=end;
    NSData *destination=addresses[RTAX_DST];
    if (![destination isKindOfClass:NSData.class] || destination.length < 2) { Fail(error,@"route has no destination"); return nil; }
    int af=((const unsigned char *)destination.bytes)[1], family=af==AF_INET?4:af==AF_INET6?6:0;
    if (!family) continue; // Non-IP routes do not share the admitted IPv4/IPv6 keys.
    unsigned int destinationScope=header.rtm_index;
    // A local IPv6 host address keeps its source-interface zone when its route
    // egress is lo0. Preserve that read-only zone; gateways and nonlocal routes
    // still require the route interface. Explicit and KAME zones must agree.
    if (family==6 && destination.length==sizeof(struct sockaddr_in6) &&
        (header.rtm_flags&(RTF_LOCAL|RTF_HOST))==(RTF_LOCAL|RTF_HOST)) {
      struct sockaddr_in6 local={0}; memcpy(&local,destination.bytes,sizeof(local));
      unsigned char *bytes=local.sin6_addr.s6_addr;
      BOOL scoped=IN6_IS_ADDR_LINKLOCAL(&local.sin6_addr) || (bytes[0]==0xff && (bytes[1]&0x0f)<=2);
      unsigned int embedded=scoped?((unsigned int)bytes[2]<<8)|bytes[3]:0;
      if (scoped && (local.sin6_scope_id || embedded)) destinationScope=local.sin6_scope_id?:embedded;
    }
    NSString *address=KuroRouteObservedAddress(destination,family,destinationScope); int prefix=(header.rtm_flags & RTF_HOST)?(family==4?32:128):0;
    id rawMask=addresses[RTAX_NETMASK];
    if ([rawMask isKindOfClass:NSData.class]) {
      NSString *maskText=KuroRouteAddress(rawMask,family,YES); NSData *mask=KuroRouteIP(maskText,family); if (!mask) { Fail(error,@"invalid route mask"); return nil; }
      const unsigned char *bytes=mask.bytes; BOOL zero=NO; prefix=0;
      for (NSUInteger bit=0;bit<mask.length*8;bit++) { BOOL one=(bytes[bit/8] & (0x80>>(bit%8)))!=0; if (zero && one) { Fail(error,@"non-contiguous route mask"); return nil; } if (one) prefix++; else zero=YES; }
    }
    NSData *network=KuroRouteIP([[address componentsSeparatedByString:@"%"]firstObject],family); const unsigned char *networkBytes=network.bytes; BOOL canonical=network!=nil;
    for (NSUInteger bit=(NSUInteger)prefix;canonical && bit<network.length*8;bit++) if (networkBytes[bit/8]&(0x80>>(bit%8))) canonical=NO;
    if (!canonical) { Fail(error,@"invalid or noncanonical route destination"); return nil; }
    NSData *gateway=addresses[RTAX_GATEWAY]; NSString *gatewayText=nil, *name=@"";
    if (![gateway isKindOfClass:NSData.class] || gateway.length < 2) { Fail(error,@"route gateway unavailable"); return nil; }
    int gatewayFamily=((const unsigned char *)gateway.bytes)[1];
    if (gatewayFamily==AF_LINK) {
      if (gateway.length < offsetof(struct sockaddr_dl,sdl_data)) { Fail(error,@"truncated link gateway"); return nil; }
      struct sockaddr_dl link={0}; memcpy(&link,gateway.bytes,MIN(gateway.length,sizeof(link)));
      NSUInteger used=offsetof(struct sockaddr_dl,sdl_data)+link.sdl_nlen+link.sdl_alen+link.sdl_slen;
      if (used>gateway.length) { Fail(error,@"link gateway index/length mismatch"); return nil; }
      // A resolved neighbour address is material, never flatten it to our link gateway.
      gatewayText=link.sdl_index!=header.rtm_index || link.sdl_alen || link.sdl_slen ? [@"link:" stringByAppendingString:Hex(gateway)] : @"link";
    } else if (gatewayFamily==af) gatewayText=KuroRouteObservedAddress(gateway,family,header.rtm_index);
    if (!gatewayText) { Fail(error,@"unsupported route gateway"); return nil; }
    id ifp=addresses[RTAX_IFP];
    if ([ifp isKindOfClass:NSData.class]) {
      NSData *data=ifp; if (data.length < offsetof(struct sockaddr_dl,sdl_data)) { Fail(error,@"truncated interface sockaddr"); return nil; }
      struct sockaddr_dl link={0}; memcpy(&link,data.bytes,MIN(data.length,sizeof(link)));
      if (link.sdl_family != AF_LINK || (link.sdl_index && link.sdl_index != header.rtm_index) || offsetof(struct sockaddr_dl,sdl_data)+link.sdl_nlen+link.sdl_alen+link.sdl_slen > data.length) { Fail(error,@"route interface mismatch"); return nil; }
      name=[[NSString alloc] initWithBytes:(const char *)data.bytes+offsetof(struct sockaddr_dl,sdl_data) length:link.sdl_nlen encoding:NSASCIIStringEncoding];
      if (!name || memchr((const char *)data.bytes+offsetof(struct sockaddr_dl,sdl_data),0,link.sdl_nlen)) { Fail(error,@"invalid route interface name"); return nil; }
    }
    [routes addObject:@{@"family":@(family),@"destination":address,@"prefix":@(prefix),@"gateway":gatewayText,@"interfaceIndex":@(header.rtm_index),@"interfaceName":name,@"flags":@((uint32_t)header.rtm_flags)}];
  }
  return routes;
}
@protocol KuroRouteStore <NSObject>
- (NSArray<NSDictionary *> *)routes:(NSString **)error;
@end
@interface KuroDarwinRouteStore:NSObject <KuroRouteStore>
@end
@implementation KuroDarwinRouteStore
- (NSArray<NSDictionary *> *)routes:(NSString **)error {
  int mib[]={CTL_NET,PF_ROUTE,0,AF_UNSPEC,NET_RT_DUMP,0}; size_t size=0;
  if (geteuid()!=0 || sysctl(mib,6,NULL,&size,NULL,0) || !size || size>KuroRouteDumpLimit) { Fail(error,@"bounded root route snapshot unavailable"); return nil; }
  NSMutableData *data=[NSMutableData dataWithLength:size];
  if (sysctl(mib,6,data.mutableBytes,&size,NULL,0) || size>data.length) { Fail(error,@"route snapshot changed or failed"); return nil; }
  data.length=size; NSArray *decoded=KuroRouteDecodeDump(data,error); if (!decoded) return nil;
  NSMutableArray *result=[NSMutableArray array];
  for (NSDictionary *entry in decoded) {
    unsigned int index=[entry[@"interfaceIndex"] unsignedIntValue]; char name[IF_NAMESIZE]={0};
    if (!index || !if_indextoname(index,name) || if_nametoindex(name)!=index) { Fail(error,@"route interface disappeared during snapshot"); return nil; }
    NSString *actual=@(name); if ([entry[@"interfaceName"] length] && ![entry[@"interfaceName"] isEqual:actual]) { Fail(error,@"route interface name changed"); return nil; }
    NSMutableDictionary *value=[entry mutableCopy]; value[@"interfaceName"]=actual; [result addObject:value];
  }
  return result;
}
@end
// Fixed mihomo v1.19.33 + sing-tun v0.4.28: four explicit /1 ranges;
// BuildAutoRouteRanges also appends the IPv4 address's /30 (not IPv6 /126).
// Darwin addRoute uses own .1/::1 as gateway, UP|STATIC|GATEWAY; XNU adds
// PRCLONING for these non-host, non-multicast ranges. No route writer lives here.
static NSArray<NSDictionary *> *KuroCoreAutoRoutePlan(void) {
  return @[
    @{@"family":@4,@"destination":@"0.0.0.0",@"prefix":@1,@"gateway":@"198.18.0.1"},
    @{@"family":@4,@"destination":@"128.0.0.0",@"prefix":@1,@"gateway":@"198.18.0.1"},
    @{@"family":@4,@"destination":@"198.18.0.0",@"prefix":@30,@"gateway":@"198.18.0.1"},
    @{@"family":@6,@"destination":@"::",@"prefix":@1,@"gateway":@"fdfe:dcba:9876::1"},
    @{@"family":@6,@"destination":@"8000::",@"prefix":@1,@"gateway":@"fdfe:dcba:9876::1"}
  ];
}
static NSArray<NSDictionary *> *KuroCoreAutoRouteCandidate(KuroCoreInterface association) {
  if(!KuroRouteAssociation(association))return nil;
  NSMutableArray *result=[NSMutableArray array];
  for(NSDictionary *entry in KuroCoreAutoRoutePlan()) {
    NSMutableDictionary *route=[entry mutableCopy];route[@"interfaceIndex"]=@(association.interfaceIndex);route[@"interfaceName"]=@(association.interfaceName);[result addObject:route];
  }
  return result;
}
static BOOL KuroRouteKey(NSDictionary *left,NSDictionary *right) {
  return [left[@"family"]isEqual:right[@"family"]] && [left[@"destination"]isEqual:right[@"destination"]] && [left[@"prefix"]isEqual:right[@"prefix"]];
}
// Fixed XNU f6217f89 route.c:402-409,2477-2486: SA_DEFAULT checks
// zero destination (not prefix); NECP tags non-host RTM_ADD with RTF_GLOBAL.
// Of this fixed plan only the lower IPv4/IPv6 /1 entries qualify.
static BOOL KuroCoreAutoRouteAllowsGlobal(NSDictionary *target) {
  return [target[@"prefix"]isEqual:@1] && (([target[@"family"]isEqual:@4]&&[target[@"destination"]isEqual:@"0.0.0.0"]) ||
    ([target[@"family"]isEqual:@6]&&[target[@"destination"]isEqual:@"::"]));
}
static BOOL KuroCoreAutoRouteEqual(NSDictionary *observed,NSDictionary *target) {
  if(!KuroLegacyRouteEntry(target) || !Keys(observed,@[@"family",@"destination",@"prefix",@"gateway",@"interfaceIndex",@"interfaceName",@"flags"]) || !KuroNumber(observed[@"flags"],0,UINT32_MAX))return NO;
  NSMutableDictionary *plan=[target mutableCopy];[plan removeObjectsForKeys:@[@"interfaceIndex",@"interfaceName"]];
  if(![KuroCoreAutoRoutePlan()containsObject:plan])return NO;
  NSMutableDictionary *value=[observed mutableCopy];[value removeObjectForKey:@"flags"];
  unsigned int flags=[observed[@"flags"]unsignedIntValue]&~(RTF_DONE|RTF_IFREF),expected=RTF_UP|RTF_STATIC|RTF_GATEWAY|RTF_PRCLONING;
  return [value isEqual:target] && (flags==expected || (KuroCoreAutoRouteAllowsGlobal(target)&&flags==(expected|RTF_GLOBAL)));
}
// Preserve the offending readback in the existing primary error before cleanup.
// Only this fixed key's route is included, never the full baseline/dump.
static NSString *KuroRouteMismatchDiagnostic(NSDictionary *target,NSDictionary *actual) {
  unsigned int flags=[actual[@"flags"]unsignedIntValue];
  NSDictionary *expected=@{@"route":target,@"flags":@(RTF_UP|RTF_STATIC|RTF_GATEWAY|RTF_PRCLONING),@"allowedAdditionalFlags":@(KuroCoreAutoRouteAllowsGlobal(target)?RTF_GLOBAL:0)};
  NSDictionary *diagnostic=@{@"expected":expected,@"actual":actual,@"normalizedFlags":@(flags&~(RTF_DONE|RTF_IFREF)),@"actualOmitted":@NO};
  NSData *encoded=JSONData(diagnostic);
  if(!encoded || encoded.length>2048) {
    NSData *actualBytes=JSONData(actual);
    diagnostic=@{@"expected":expected,@"actualOmitted":@YES,@"actualSHA256":actualBytes?Hash(actualBytes):(id)NSNull.null,
      @"actualBytes":@(actualBytes.length),@"actualFlags":@(flags),@"normalizedFlags":@(flags&~(RTF_DONE|RTF_IFREF)),@"actualInterfaceIndex":actual[@"interfaceIndex"]};
    encoded=JSONData(diagnostic);
  }
  NSString *summary=encoded&&encoded.length<=2048?[[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding]:@"{\"diagnosticUnavailable\":true}";
  return [@"Core auto-route differs from its fixed gateway/interface/flags; routeObservation=" stringByAppendingString:summary];
}
static BOOL KuroRouteConfirmationFailure(NSString **error,NSString *stage,NSString *reason) {
  NSString *bounded=[reason substringToIndex:MIN(reason.length,(NSUInteger)1024)];
  return Fail(error,[NSString stringWithFormat:@"route confirmation lacks this actor's prepared live Core; stage=%@; reason=%@",stage,bounded]);
}
static BOOL KuroRouteBaseline(NSArray *routes) {
  if(![routes isKindOfClass:NSArray.class] || routes.count>4096)return NO;
  for(NSDictionary *entry in routes)if(!Keys(entry,@[@"family",@"destination",@"prefix",@"gateway",@"interfaceIndex",@"interfaceName",@"flags"]) ||
    !KuroNumber(entry[@"family"],4,6) || ![@[@4,@6]containsObject:entry[@"family"]] || !KuroNumber(entry[@"prefix"],0,[entry[@"family"]intValue]==4?32:128) ||
    !KuroNumber(entry[@"interfaceIndex"],1,UINT16_MAX) || !KuroNumber(entry[@"flags"],0,UINT32_MAX) ||
    ![entry[@"destination"]isKindOfClass:NSString.class] || [entry[@"destination"]length]>128 ||
    ![entry[@"gateway"]isKindOfClass:NSString.class] || [entry[@"gateway"]length]>1024 ||
    !Match(entry[@"interfaceName"],@"\\A[a-zA-Z][a-zA-Z0-9]{0,14}\\z"))return NO;
  return YES;
}
static BOOL KuroRouteBinding(NSDictionary *binding) {
  if(!Keys(binding,@[@"configSHA256",@"runtimeSHA256",@"coreSHA256",@"template",@"process"]))return NO;
  NSDictionary *process=binding[@"process"];
  if(!Keys(binding,@[@"configSHA256",@"runtimeSHA256",@"coreSHA256",@"template",@"process"]) || ![binding[@"template"]isEqual:@"macos-dual-stack-v1"] ||
    !Keys(process,@[@"pid",@"startSeconds",@"startMicros"]) || !KuroNumber(process[@"pid"],1,INT_MAX) || !KuroNumber(process[@"startSeconds"],1,INT64_MAX) || !KuroNumber(process[@"startMicros"],0,999999))return NO;
  for(NSString *key in @[@"configSHA256",@"runtimeSHA256",@"coreSHA256"])if(!Match(binding[key],@"\\A[0-9a-f]{64}\\z"))return NO;
  return YES;
}
static BOOL KuroRouteDecodeAssociation(NSDictionary *a,KuroCoreInterface *association) {
  if(!Keys(a,@[@"pid",@"startSeconds",@"startMicros",@"descriptor",@"controlID",@"controlUnit",@"socketHandle",@"pcbHandle",@"interfaceIndex",@"interfaceName"]) ||
    !KuroNumber(a[@"pid"],1,INT_MAX) || !KuroNumber(a[@"startSeconds"],1,INT64_MAX) || !KuroNumber(a[@"startMicros"],0,999999) ||
    !KuroNumber(a[@"descriptor"],0,INT_MAX) || !KuroNumber(a[@"controlID"],1,UINT32_MAX) || !KuroNumber(a[@"controlUnit"],1,INT_MAX) ||
    !KuroNumber(a[@"interfaceIndex"],1,UINT16_MAX) || !Match(a[@"socketHandle"],@"\\A[1-9][0-9]{0,19}\\z") || !Match(a[@"pcbHandle"],@"\\A[1-9][0-9]{0,19}\\z") ||
    !Match(a[@"interfaceName"],@"\\Autun[0-9]{1,9}\\z"))return NO;
  KuroCoreInterface value={0};value.process=(KuroCoreIdentity){[a[@"pid"]intValue],[a[@"startSeconds"]unsignedLongLongValue],[a[@"startMicros"]unsignedLongLongValue]};
  value.descriptor=[a[@"descriptor"]intValue];value.controlID=[a[@"controlID"]unsignedIntValue];value.controlUnit=[a[@"controlUnit"]unsignedIntValue];
  errno=0;value.socketHandle=strtoull([a[@"socketHandle"]UTF8String],NULL,10);if(errno)return NO;
  value.pcbHandle=strtoull([a[@"pcbHandle"]UTF8String],NULL,10);if(errno)return NO;
  value.interfaceIndex=[a[@"interfaceIndex"]unsignedIntValue];strlcpy(value.interfaceName,[a[@"interfaceName"]UTF8String],sizeof(value.interfaceName));
  if(![KuroRouteAssociation(value)isEqual:a])return NO;if(association)*association=value;return YES;
}
typedef NS_ENUM(NSUInteger,KuroRouteObservationState) {
  KuroRouteObservationInvalid, KuroRouteObservationPending, KuroRouteObservationReady
};
@interface KuroOwnedRoutes:NSObject {
  NSString *_directory;uid_t _owner;id<KuroRouteStore> _backend;pthread_t _thread;BOOL _routesOff;
  NSDictionary *_preparedRecord,*_pendingRetirement;
}
@property(nonatomic,readonly) BOOL routesOff;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroRouteStore>)backend;
- (BOOL)prepareForSession:(NSString *)session binding:(NSDictionary *)binding baselineRoutes:(NSArray *)baselineRoutes baselineDNS:(NSDictionary *)baselineDNS physicalInterface:(NSString *)physical error:(NSString **)error;
- (KuroRouteObservationState)observeReadinessForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)observeForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)confirmObservedSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (NSDictionary *)preparedRecord:(NSString **)error;
- (NSDictionary *)recordForInterface:(KuroCoreInterface)association bytes:(NSData **)bytes error:(NSString **)error;
- (BOOL)recoverRecordedAbsence:(NSString **)error;
@end
@implementation KuroOwnedRoutes
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroRouteStore>)backend {
  if((self=[super init])){_directory=[directory copy];_owner=owner;_backend=backend;_thread=pthread_self();}return self;
}
- (BOOL)routesOff{return _routesOff;}
- (BOOL)prepared:(NSString **)error {
  NSString *anchor=@"";
#ifdef KURO_TESTING
  anchor=_directory;
#endif
  return (_backend && pthread_equal(_thread,pthread_self()) && SafeChain(anchor,_directory,_owner,YES,error)) || Fail(error,@"route observer requires its protected directory and serial thread");
}
- (BOOL)syncDirectory:(NSString **)error {
  int fd=open(_directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);BOOL ok=fd>=0&&!fsync(fd);if(fd>=0)close(fd);
  return ok||Fail(error,@"route observation directory sync failed");
}
- (NSData *)journalBytes:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];struct stat metadata;
  if(lstat(path.fileSystemRepresentation,&metadata)||metadata.st_size<0||metadata.st_size>(off_t)MessageLimit){Fail(error,@"route observation unavailable or oversized");return nil;}
  return ReadProtected(_directory,path,_owner,error);
}
- (BOOL)persist:(NSDictionary *)record replacing:(NSData *)previous error:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];NSData *data=JSONData(record);
  if(!data||data.length>MessageLimit)return Fail(error,@"route observation and baseline exceed 64KiB bound");
  if(!previous)return WriteNew(path,data,0600,error)&&[self syncDirectory:error];
  if(![[self journalBytes:error]isEqual:previous])return Fail(error,@"route observation changed before publish");
  NSString *temporary=[_directory stringByAppendingPathComponent:[@".network-"stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!WriteNew(temporary,data,0600,error))return NO;
  if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)){unlink(temporary.fileSystemRepresentation);return Fail(error,@"route observation publish failed");}
  return [self syncDirectory:error];
}
- (NSDictionary *)validatedRecord:(NSData **)bytes error:(NSString **)error {
  NSData *data=[self journalBytes:error];NSDictionary *record=data?KuroDecodeJSON(data,MessageLimit,error):nil;
  if(![record isKindOfClass:NSDictionary.class]){Fail(error,@"route observation is not a mapping");return nil;}
  NSUUID *uuid=[record[@"session"]isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:record[@"session"]]:nil;
  if(!uuid||![uuid.UUIDString isEqual:record[@"session"]]){Fail(error,@"route observation session is invalid");return nil;}
  if(KuroNumber(record[@"format"],1,1) && [record[@"kind"]isEqual:@"routes-v1"]) {
    KuroCoreInterface association={0};NSArray *routes=record[@"routes"];
    if(!Keys(record,@[@"format",@"kind",@"session",@"interface",@"routes",@"applied"]) || !KuroRouteDecodeAssociation(record[@"interface"],&association) ||
      ![routes isKindOfClass:NSArray.class] || !routes.count || routes.count>KuroRouteLimit || !KuroNumber(record[@"applied"],0,routes.count)){Fail(error,@"invalid legacy route receipt");return nil;}
    NSMutableArray *seen=[NSMutableArray array];
    for(NSDictionary *target in routes){if(!KuroLegacyRouteEntry(target)||![target[@"interfaceIndex"]isEqual:@(association.interfaceIndex)]||![target[@"interfaceName"]isEqual:@(association.interfaceName)]){Fail(error,@"invalid legacy route association");return nil;}for(NSDictionary *prior in seen)if(KuroRouteKey(prior,target)){Fail(error,@"duplicate legacy route key");return nil;}[seen addObject:target];}
  } else {
    if(!Keys(record,@[@"format",@"kind",@"session",@"binding",@"baselineRoutes",@"baselineDNS",@"physicalInterface",@"routes",@"phase",@"interface"]) || !KuroNumber(record[@"format"],2,2) || ![record[@"kind"]isEqual:@"core-auto-route-v1"] ||
      !KuroRouteBinding(record[@"binding"]) || !KuroRouteBaseline(record[@"baselineRoutes"]) || ![record[@"baselineDNS"]isKindOfClass:NSDictionary.class] || !Match(record[@"physicalInterface"],@"\\A[a-zA-Z][a-zA-Z0-9]{0,14}\\z")){Fail(error,@"invalid closed Core route observation");return nil;}
    if([record[@"phase"]isEqual:@"prepared"]) {
      if(record[@"interface"]!=NSNull.null||![record[@"routes"]isEqual:KuroCoreAutoRoutePlan()]){Fail(error,@"prepared route observation is not the fixed unbound plan");return nil;}
    } else if([record[@"phase"]isEqual:@"observed"]) {
      KuroCoreInterface association={0};
      if(!KuroRouteDecodeAssociation(record[@"interface"],&association)||![record[@"routes"]isEqual:KuroCoreAutoRouteCandidate(association)] || ![record[@"binding"][@"process"]isEqual:@{@"pid":@(association.process.pid),@"startSeconds":@(association.process.startSeconds),@"startMicros":@(association.process.startMicros)}]){Fail(error,@"observed routes do not match the fixed Core/process association");return nil;}
    } else {Fail(error,@"unknown route observation phase");return nil;}
    for(NSDictionary *existing in record[@"baselineRoutes"])for(NSDictionary *target in KuroCoreAutoRoutePlan())if(KuroRouteKey(existing,target)){Fail(error,@"prepared baseline conflicts with Core route keys");return nil;}
  }
  if(bytes)*bytes=data;return record;
}
- (NSDictionary *)preparedRecord:(NSString **)error {
  if(![self prepared:error])return nil;
  struct stat metadata;NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];
  if(lstat(path.fileSystemRepresentation,&metadata)){if(errno==ENOENT){if(error)*error=nil;return nil;}Fail(error,@"route observation existence is unknown");return nil;}
  return [self validatedRecord:NULL error:error];
}
- (NSDictionary *)recordForInterface:(KuroCoreInterface)association bytes:(NSData **)bytes error:(NSString **)error {
  if(![self prepared:error])return nil;
  NSDictionary *record=[self validatedRecord:bytes error:error];if(!record)return nil;
  if(![record[@"phase"]isEqual:@"observed"]||![record[@"interface"]isEqual:KuroRouteAssociation(association)]){Fail(error,@"no observed route receipt for this association");return nil;}return record;
}
- (NSArray *)snapshot:(NSString **)error {
  NSArray *routes=[_backend routes:error];if(!routes)return nil;
  if(!KuroRouteBaseline(routes)){Fail(error,@"route snapshot is malformed or exceeds bound");return nil;}return routes;
}
- (BOOL)prepareForSession:(NSString *)session binding:(NSDictionary *)binding baselineRoutes:(NSArray *)baselineRoutes baselineDNS:(NSDictionary *)baselineDNS physicalInterface:(NSString *)physical error:(NSString **)error {
  _routesOff=NO;NSUUID *uuid=[session isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:session]:nil;
  if(![self prepared:error]||_preparedRecord||_pendingRetirement||!uuid||![uuid.UUIDString isEqual:session]||!KuroRouteBinding(binding)||!KuroRouteBaseline(baselineRoutes)||![baselineDNS isKindOfClass:NSDictionary.class]||!Match(physical,@"\\A[a-zA-Z][a-zA-Z0-9]{0,14}\\z"))return Fail(error,@"route preparation requires canonical session, closed binding and baseline");
  for(NSDictionary *existing in baselineRoutes)for(NSDictionary *target in KuroCoreAutoRoutePlan())if(KuroRouteKey(existing,target))return Fail(error,@"baseline already contains a Core auto-route key");
  NSDictionary *record=@{@"format":@2,@"kind":@"core-auto-route-v1",@"session":session,@"binding":binding,@"baselineRoutes":baselineRoutes,@"baselineDNS":baselineDNS,@"physicalInterface":physical,@"routes":KuroCoreAutoRoutePlan(),@"phase":@"prepared",@"interface":NSNull.null};
  NSData *data=JSONData(record);if(!data||data.length>MessageLimit)return Fail(error,@"route observation and baseline exceed 64KiB bound");
  record=KuroDecodeJSON(data,MessageLimit,error);if(!record||![self persist:record replacing:nil error:error])return NO;
  _preparedRecord=record;return YES;
}
- (BOOL)matchingPreparation:(NSDictionary *)record session:(NSString *)session association:(KuroCoreInterface)association {
  if(!_preparedRecord||![record[@"session"]isEqual:session]||![record[@"binding"][@"process"]isEqual:@{@"pid":@(association.process.pid),@"startSeconds":@(association.process.startSeconds),@"startMicros":@(association.process.startMicros)}])return NO;
  NSMutableDictionary *prepared=[record mutableCopy];prepared[@"phase"]=@"prepared";prepared[@"interface"]=NSNull.null;prepared[@"routes"]=KuroCoreAutoRoutePlan();
  return [prepared isEqual:_preparedRecord];
}
- (KuroRouteObservationState)snapshotReadiness:(NSArray *)targets error:(NSString **)error {
  NSArray *observed=[self snapshot:error];if(!observed)return KuroRouteObservationInvalid;
  BOOL missing=NO;
  // Scan all keys: a missing early route must not hide a later conflict.
  for(NSDictionary *target in targets) {
    NSUInteger count=0;
    for(NSDictionary *route in observed)if(KuroRouteKey(route,target)) {
      count++;
      if(!KuroCoreAutoRouteEqual(route,target)){Fail(error,KuroRouteMismatchDiagnostic(target,route));return KuroRouteObservationInvalid;}
    }
    if(count>1){Fail(error,@"Core auto-route readback is ambiguous");return KuroRouteObservationInvalid;}
    if(!count)missing=YES;
  }
  return missing?KuroRouteObservationPending:KuroRouteObservationReady;
}
- (BOOL)exactSnapshot:(NSArray *)targets error:(NSString **)error {
  KuroRouteObservationState state=[self snapshotReadiness:targets error:error];
  return state==KuroRouteObservationReady || (state==KuroRouteObservationPending?Fail(error,@"Core auto-route readback is absent"):NO);
}
- (KuroRouteObservationState)observeReadinessForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  _routesOff=NO;if(error)*error=nil;NSData *bytes=nil;
  if(![self prepared:error]||!KuroRouteAssociation(association)||!ownership){Fail(error,@"route observation requires a held live association");return KuroRouteObservationInvalid;}
  NSDictionary *record=[self validatedRecord:&bytes error:error];
  if(!record||![self matchingPreparation:record session:session association:association]||ownership(association,error)!=KuroRouteOwnerLive){Fail(error,@"route observation does not match this actor's prepared Core");return KuroRouteObservationInvalid;}
  NSArray *targets=KuroCoreAutoRouteCandidate(association);
  KuroRouteObservationState state=[self snapshotReadiness:targets error:error];
  if(state==KuroRouteObservationInvalid)return state;
  if(ownership(association,error)!=KuroRouteOwnerLive){Fail(error,@"held Core identity changed during route observation");return KuroRouteObservationInvalid;}
  if(![[self journalBytes:error]isEqual:bytes]){Fail(error,@"route preparation changed during observation");return KuroRouteObservationInvalid;}
  if(state==KuroRouteObservationPending) {
    if(![record[@"phase"]isEqual:@"prepared"]){Fail(error,@"previously observed Core route disappeared");return KuroRouteObservationInvalid;}
    return state;
  }
  NSMutableDictionary *next=[record mutableCopy];next[@"phase"]=@"observed";next[@"interface"]=KuroRouteAssociation(association);next[@"routes"]=targets;
  if([record isEqual:next]){if(![self syncDirectory:error])return KuroRouteObservationInvalid;}
  else if(![self persist:next replacing:bytes error:error])return KuroRouteObservationInvalid;
  return [self confirmObservedSession:session interface:association ownership:ownership error:error]?KuroRouteObservationReady:KuroRouteObservationInvalid;
}
- (BOOL)observeForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  KuroRouteObservationState state=[self observeReadinessForSession:session interface:association ownership:ownership error:error];
  return state==KuroRouteObservationReady || (state==KuroRouteObservationPending?Fail(error,@"Core auto-route readback is absent"):NO);
}
- (BOOL)confirmObservedSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  if(![self prepared:error]||!KuroRouteAssociation(association)||!ownership)return Fail(error,@"route confirmation requires a held live association");
  NSData *bytes=nil;NSString *failure=nil;NSDictionary *record=[self recordForInterface:association bytes:&bytes error:&failure];
  if(!record)return KuroRouteConfirmationFailure(error,@"record",failure?:@"observed route record is unavailable");
  if(![self matchingPreparation:record session:session association:association])return KuroRouteConfirmationFailure(error,@"prepared-binding",@"observed record does not match this actor's prepared session and Core binding");
  failure=nil;if(ownership(association,&failure)!=KuroRouteOwnerLive)return KuroRouteConfirmationFailure(error,@"ownership",failure?:@"live Core ownership was not confirmed");
  if(![self exactSnapshot:record[@"routes"] error:error]||ownership(association,error)!=KuroRouteOwnerLive)return NO;
  if(![[self journalBytes:error]isEqual:bytes])return Fail(error,@"route observation changed during confirmation");
  return [self syncDirectory:error];
}
- (BOOL)absent:(NSArray *)targets snapshot:(NSArray *)observed error:(NSString **)error {
  for(NSDictionary *route in observed){if([route[@"flags"]unsignedIntValue]&RTF_PROTO2)return Fail(error,@"legacy marked route remains; observation cannot authorize deletion");for(NSDictionary *target in targets)if(KuroRouteKey(route,target))return Fail(error,@"recorded Core route key remains; preserving route and observation");}return YES;
}
- (BOOL)recoverRecordedAbsence:(NSString **)error {
  _routesOff=NO;_preparedRecord=nil;if(![self prepared:error])return NO;
  NSString *failure=nil;NSDictionary *record=[self preparedRecord:&failure];if(failure)return Fail(error,failure);
  if(_pendingRetirement&&record&&![_pendingRetirement isEqual:record])return Fail(error,@"a different observation appeared during retirement");
  if(!record)record=_pendingRetirement;
  NSArray *targets=record?record[@"routes"]:KuroCoreAutoRoutePlan();
  NSArray *first=[self snapshot:error];if(!first||![self absent:targets snapshot:first error:error])return NO;
  NSArray *again=[self snapshot:error];if(!again||![self absent:targets snapshot:again error:error])return NO;
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];
  if(Exists(path)) {
    NSData *bytes=nil;NSDictionary *current=[self validatedRecord:&bytes error:error];if(![current isEqual:record]||![[self journalBytes:error]isEqual:bytes])return Fail(error,@"route observation changed during absence check");
    _pendingRetirement=record;
    if(unlink(path.fileSystemRepresentation))return Fail(error,@"route observation absence retirement failed");
  }
  if(![self syncDirectory:error])return NO;
  _pendingRetirement=nil;_routesOff=YES;return YES;
}
@end
