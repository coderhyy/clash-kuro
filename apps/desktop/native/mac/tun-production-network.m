// Root-internal coordinator. Construction is inert; system observation starts
// only at authenticated preflight/readiness/recovery, never from App fields.
#import "tun-network.m"
#import "tun-config.m"
#include <netinet/in.h>

static NSString *const KuroReadinessDomain=@"kuro-tun-ready.invalid";
static NSDictionary *KuroProductionRuntimeFields(void) {
  return @{@"hosts":@{KuroReadinessDomain:@[@"198.18.0.1",@"fdfe:dcba:9876::1"]}};
}
// All seams are private to root/ordinary fixture tests, not RPC parameters.
@interface KuroNetworkEnvironment : NSObject
@property(nonatomic,copy) NSArray<NSDictionary *> *(^interfaces)(NSString **);
@property(nonatomic,copy) BOOL (^observeChild)(pid_t,KuroCoreInterface *,NSString **);
@property(nonatomic,copy) KuroRouteOwnership ownership;
@property(nonatomic,copy) BOOL (^probeDNS)(KuroCoreInterface,NSString **);
@end
@implementation KuroNetworkEnvironment
@end

static uint16_t KuroDNSWord(const unsigned char *bytes) { return ((uint16_t)bytes[0]<<8)|bytes[1]; }
static NSData *KuroReadinessQuestion(uint16_t identifier, BOOL ipv6) {
  unsigned char header[12]={identifier>>8,identifier&255,0,0,0,1,0,0,0,0,0,0};
  NSMutableData *packet=[NSMutableData dataWithBytes:header length:sizeof(header)];
  for (NSString *label in [KuroReadinessDomain componentsSeparatedByString:@"."]) { uint8_t size=(uint8_t)label.length; [packet appendBytes:&size length:1]; [packet appendData:[label dataUsingEncoding:NSASCIIStringEncoding]]; }
  unsigned char tail[5]={0,0,ipv6?28:1,0,1}; [packet appendBytes:tail length:sizeof(tail)]; return packet;
}
static BOOL KuroReadinessAnswer(NSData *packet, NSData *question, BOOL ipv6) {
  if (packet.length<question.length+12 || packet.length>512 || question.length<17) return NO;
  const unsigned char *b=packet.bytes,*q=question.bytes;
  if (memcmp(b,q,2) || !(b[2]&0x80) || (b[2]&0x7a) || (b[3]&0x0f) || KuroDNSWord(b+4)!=1 || KuroDNSWord(b+6)!=1 || KuroDNSWord(b+8) || KuroDNSWord(b+10) || memcmp(b+12,q+12,question.length-12)) return NO;
  NSUInteger cursor=question.length;
  // The answer must name the exact fixed question, compressed or literal.
  if (b[cursor]==0xc0 && b[cursor+1]==12) cursor+=2;
  else { NSUInteger nameLength=question.length-16; if (packet.length-cursor<nameLength || memcmp(b+cursor,q+12,nameLength)) return NO; cursor+=nameLength; }
  if (packet.length-cursor<10 || KuroDNSWord(b+cursor)!=(ipv6?28:1) || KuroDNSWord(b+cursor+2)!=1) return NO;
  NSUInteger length=KuroDNSWord(b+cursor+8); cursor+=10;
  NSData *expected=KuroRouteIP(ipv6?@"fdfe:dcba:9876::1":@"198.18.0.1",ipv6?6:4);
  return length==expected.length && packet.length==cursor+length && !memcmp(b+cursor,expected.bytes,length);
}
static BOOL KuroProbeInternalDNS(KuroCoreInterface association, NSString **error) {
  for (NSNumber *family in @[@4,@6]) {
    BOOL ipv6=family.intValue==6; int af=ipv6?AF_INET6:AF_INET;
    int fd=socket(af,SOCK_DGRAM,0); if (fd<0) return Fail(error,@"internal DNS probe socket unavailable");
    unsigned int index=association.interfaceIndex; int flags=fcntl(fd,F_GETFL,0);
    BOOL ok=flags>=0 && !fcntl(fd,F_SETFD,FD_CLOEXEC) && !fcntl(fd,F_SETFL,flags|O_NONBLOCK) &&
      !setsockopt(fd,ipv6?IPPROTO_IPV6:IPPROTO_IP,ipv6?IPV6_BOUND_IF:IP_BOUND_IF,&index,sizeof(index));
    struct sockaddr_storage storage={0}; socklen_t size;
    if (ipv6) { struct sockaddr_in6 *address=(void *)&storage; address->sin6_len=sizeof(*address); address->sin6_family=af; address->sin6_port=htons(53); inet_pton(af,"fdfe:dcba:9876::2",&address->sin6_addr); size=sizeof(*address); }
    else { struct sockaddr_in *address=(void *)&storage; address->sin_len=sizeof(*address); address->sin_family=af; address->sin_port=htons(53); inet_pton(af,"198.18.0.2",&address->sin_addr); size=sizeof(*address); }
    NSData *question=KuroReadinessQuestion((uint16_t)arc4random_uniform(65536),ipv6);
    ok=ok && !connect(fd,(struct sockaddr *)&storage,size) && send(fd,question.bytes,question.length,0)==(ssize_t)question.length;
    if (ok) { struct pollfd ready={.fd=fd,.events=POLLIN}; int polled=0; uint64_t deadline=KuroMonotonicMilliseconds()+400;
      do { uint64_t now=KuroMonotonicMilliseconds(); if (now>=deadline) break; polled=poll(&ready,1,(int)(deadline-now)); } while (polled<0 && errno==EINTR);
      unsigned char bytes[513]; ssize_t count=polled>0 && (ready.revents&POLLIN)?recv(fd,bytes,sizeof(bytes),0):-1;
      ok=count>0 && KuroReadinessAnswer([NSData dataWithBytes:bytes length:(NSUInteger)count],question,ipv6);
    }
    close(fd); if (!ok) return Fail(error,ipv6?@"fixed internal IPv6 DNS static-host probe was not confirmed":@"fixed internal IPv4 DNS static-host probe was not confirmed");
  }
  return YES;
}
static KuroNetworkEnvironment *KuroProductionEnvironment(void) {
  KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
  environment.interfaces=^NSArray *(NSString **error) { return KuroNetworkInterfaces(error); };
  environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **error) {
    struct proc_bsdinfo info={0};
    if (proc_pidinfo(child,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info) || info.pbi_pid!=(uint32_t)child || info.pbi_ppid!=(uint32_t)getpid()) return Fail(error,@"held Core direct-child identity unavailable");
    KuroCoreIdentity identity={child,info.pbi_start_tvsec,info.pbi_start_tvusec}; return KuroObserveCoreInterface(identity,result,error);
  };
  environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **error) {
    KuroCoreInterface current={0}; NSString *failure=nil;
    if (KuroObserveCoreInterface(expected.process,&current,&failure) && [KuroRouteAssociation(current)isEqual:KuroRouteAssociation(expected)]) return KuroRouteOwnerLive;
    struct proc_bsdinfo info={0}; errno=0; int count=proc_pidinfo(expected.process.pid,PROC_PIDTBSDINFO,0,&info,sizeof(info)); int saved=errno;
    BOOL exited=count==sizeof(info)?info.pbi_start_tvsec!=expected.process.startSeconds || info.pbi_start_tvusec!=expected.process.startMicros || info.pbi_status==SZOMB:count==0 && saved==ESRCH;
    char name[IF_NAMESIZE]={0}; BOOL gone=if_nametoindex(expected.interfaceName)==0 && (!if_indextoname(expected.interfaceIndex,name) || strcmp(name,expected.interfaceName));
    if (exited && gone) return KuroRouteOwnerExitedInterfaceGone;
    Fail(error,failure ?: @"Core/interface ownership is uncertain; preserve network receipts"); return KuroRouteOwnerUnknown;
  };
  environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **error) { return KuroProbeInternalDNS(value,error); };
  return environment;
}
static NSArray *KuroStableRoutes(NSArray *routes) {
  if (![routes isKindOfClass:NSArray.class] || routes.count>4096) return nil;
  NSMutableArray *result=[NSMutableArray array];
  for (NSDictionary *route in routes) {
    if (!Keys(route,@[@"family",@"destination",@"prefix",@"gateway",@"interfaceIndex",@"interfaceName",@"flags"])) return nil;
    unsigned int flags=[route[@"flags"]unsignedIntValue];
    // Neighbour/ARP clones may appear during normal traffic. They are never an
    // installation target or cleanup authority; all parent routes stay pinned.
    if ((flags&(RTF_LLINFO|RTF_WASCLONED)) && (flags&RTF_HOST) && !(flags&RTF_PROTO2)) continue;
    NSMutableDictionary *entry=[route mutableCopy]; entry[@"flags"]=@(flags&~(RTF_DONE|RTF_IFREF)); [result addObject:entry];
  }
  return result;
}
static NSString *KuroCanonicalEndpoint(NSString *text) {
  if (![text isKindOfClass:NSString.class]) return nil;
  unsigned char bytes[16]; char canonical[INET6_ADDRSTRLEN];
  for (NSNumber *family in @[@4,@6]) { int af=family.intValue==4?AF_INET:AF_INET6;
    if (inet_pton(af,text.UTF8String,bytes)==1 && inet_ntop(af,bytes,canonical,sizeof(canonical))) return @(canonical);
  }
  return nil;
}
static BOOL KuroRouteContainsIP(NSDictionary *route, NSString *text) {
  int family=[route[@"family"]intValue]; NSData *address=KuroRouteIP(KuroCanonicalEndpoint(text),family), *network=KuroRouteIP([[route[@"destination"]componentsSeparatedByString:@"%"]firstObject],family);
  NSUInteger bits=[route[@"prefix"]unsignedIntegerValue]; if (!address || !network || bits>address.length*8) return NO;
  const unsigned char *a=address.bytes,*n=network.bytes;
  for (NSUInteger bit=0;bit<bits;bit++) if ((a[bit/8]&(0x80>>(bit%8)))!=(n[bit/8]&(0x80>>(bit%8)))) return NO;
  return YES;
}
static BOOL KuroPrivateEndpoint(NSString *text) {
  text=KuroCanonicalEndpoint(text); NSData *v4=KuroRouteIP(text,4); if (v4) { const unsigned char *a=v4.bytes; return a[0]==10 || a[0]==127 || (a[0]==172 && a[1]>=16 && a[1]<=31) || (a[0]==192 && a[1]==168) || (a[0]==169 && a[1]==254); }
  NSData *v6=KuroRouteIP(text,6); if (v6) { const unsigned char *a=v6.bytes; struct in6_addr ip; memcpy(&ip,a,16); return (a[0]&0xfe)==0xfc || IN6_IS_ADDR_LINKLOCAL(&ip) || IN6_IS_ADDR_LOOPBACK(&ip); } return NO;
}
static BOOL KuroPreservedEndpoint(NSString *text, NSArray *routes, NSString *physical, BOOL coreBound, BOOL missingIPv6Default, NSString **error) {
  // A domain proxy address is resolved by the admitted Profile. This function
  // only claims preservation for literal endpoints observable in this baseline.
  struct in6_addr mapped={0};
  if ([text isKindOfClass:NSString.class] && inet_pton(AF_INET6,text.UTF8String,&mapped)==1 && IN6_IS_ADDR_V4MAPPED(&mapped)) return Fail(error,@"IPv4-mapped IPv6 endpoint is unsupported; cannot prove address-family route preservation");
  // Missing external IPv6 does not disable local dual stack. Literal IPv6
  // endpoints still need a preserved path outside the new split-default routes.
  BOOL needsIPv6Route=missingIPv6Default && KuroRouteIP(KuroCanonicalEndpoint(text),6)!=nil;
  if (!KuroPrivateEndpoint(text) && !needsIPv6Route) return YES;
  NSInteger longest=-1; NSMutableArray *matches=[NSMutableArray array];
  for (NSDictionary *route in routes) if (KuroRouteContainsIP(route,text) && [route[@"prefix"]intValue]>1 && ([route[@"flags"]unsignedIntValue]&RTF_UP)) {
    NSInteger prefix=[route[@"prefix"]integerValue];
    if (prefix>longest) { longest=prefix; [matches removeAllObjects]; }
    if (prefix==longest && ![matches containsObject:route]) [matches addObject:route];
  }
  if (matches.count>1) return Fail(error,@"LAN/DNS endpoint has ambiguous longest-prefix scoped routes; preserving baseline");
  NSDictionary *best=matches.firstObject;
  if (!best || ([best[@"flags"]unsignedIntValue]&(RTF_REJECT|RTF_BLACKHOLE)) || (coreBound && ![best[@"interfaceName"]isEqual:physical])) return Fail(error,[NSString stringWithFormat:@"LAN/DNS endpoint %@ has no provably preserved more-specific %@route%@; preserving configured endpoint",text,coreBound?@"physical ":@"",needsIPv6Route?@" while no IPv6 default exists":@""]);
  return YES;
}

@interface KuroProductionNetwork : NSObject {
  NSString *_directory; uid_t _owner; pthread_t _thread;
  id<KuroRouteStore> _routeBackend; id<KuroDNSStore> _dnsBackend; KuroNetworkEnvironment *_environment;
  KuroOwnedRoutes *_routes; KuroOwnedDNS *_dns;
  NSArray *_baselineRoutes; NSDictionary *_baselineDNS; NSString *_physical, *_session;
  KuroCoreInterface _association; BOOL _prepared, _networkOff;
  NSDictionary *_stoppedEvidence;
}
@property(nonatomic,readonly) NSString *runtimeInterfaceName;
@property(nonatomic,readonly) BOOL networkOff;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner routes:(id<KuroRouteStore>)routes dns:(id<KuroDNSStore>)dns environment:(KuroNetworkEnvironment *)environment;
- (BOOL)preflightConfig:(NSDictionary *)config error:(NSString **)error;
- (BOOL)readyChild:(pid_t)child session:(NSString *)session error:(NSString **)error;
- (BOOL)applyChild:(pid_t)child session:(NSString *)session error:(NSString **)error;
- (BOOL)recoverSession:(NSString *)session error:(NSString **)error;
- (NSDictionary *)recoverRecordedSession:(NSString *)session error:(NSString **)error;
- (BOOL)confirmSession:(NSString *)session error:(NSString **)error;
- (NSDictionary *)stoppedEvidenceForSession:(NSString *)session error:(NSString **)error;
@end
@implementation KuroProductionNetwork
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner {
  return [self initWithDirectory:directory owner:owner routes:[KuroDarwinRouteStore new] dns:nil environment:KuroProductionEnvironment()];
}
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner routes:(id<KuroRouteStore>)routes dns:(id<KuroDNSStore>)dns environment:(KuroNetworkEnvironment *)environment {
  if ((self=[super init])) { _directory=[directory copy]; _owner=owner; _thread=pthread_self(); _routeBackend=routes; _dnsBackend=dns; _environment=environment; } return self;
}
- (NSString *)runtimeInterfaceName { return _prepared?_physical:nil; }
- (BOOL)networkOff { return _networkOff; }
- (BOOL)adapters:(NSString **)error {
  if (!pthread_equal(_thread,pthread_self()) || !_routeBackend || !_environment.interfaces || !_environment.observeChild || !_environment.ownership || !_environment.probeDNS) return Fail(error,@"network coordinator requires owning serial thread and complete internal adapters");
  if (!_dnsBackend) _dnsBackend=[[KuroDarwinDNSStore alloc]initWithError:error]; if (!_dnsBackend) return NO;
  if (!_routes) _routes=[[KuroOwnedRoutes alloc]initWithDirectory:_directory owner:_owner backend:_routeBackend];
  if (!_dns) _dns=[[KuroOwnedDNS alloc]initWithDirectory:_directory owner:_owner backend:_dnsBackend];
  return YES;
}
- (BOOL)preflightConfig:(NSDictionary *)config error:(NSString **)error {
  _stoppedEvidence=nil;
  _networkOff=NO;
  if (_session) return Fail(error,@"network preflight cannot replace active session");
  if (![self adapters:error]) return NO;
  _prepared=NO; _physical=nil;
  if (!KuroValidateTunConfig(JSONData(config),error)) return NO;
  if (Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) || Exists([_directory stringByAppendingPathComponent:KuroDNSJournal])) return Fail(error,@"retained network receipt requires recovery before a new start");
  NSArray *routes=KuroStableRoutes([_routeBackend routes:error]),*interfaces=_environment.interfaces(error); if (!routes || !interfaces) return Fail(error,@"complete route/interface baseline unavailable");
  NSDictionary *dns=KuroDNSPreflight([_dnsBackend dnsRecords:error],error); if (!dns) return NO;
  NSMutableDictionary *defaults=[NSMutableDictionary dictionary];
  for (NSDictionary *route in routes) {
    unsigned int flags=[route[@"flags"]unsignedIntValue];
    if ((flags&RTF_PROTO2) || ([route[@"prefix"]intValue]==1 && [route[@"flags"]unsignedIntValue]&RTF_UP)) return Fail(error,@"retained marked route or existing split-default owner conflicts with fixed plan");
    if ([route[@"prefix"]intValue]!=0 || !(flags&RTF_UP) || (flags&RTF_IFSCOPE)) continue;
    // A split default must not bypass an administrator's existing drop route.
    if (flags&(RTF_REJECT|RTF_BLACKHOLE)) return Fail(error,@"default egress is an existing reject/blackhole route; refusing to bypass it");
    NSNumber *family=route[@"family"]; if (defaults[family]) return Fail(error,@"multiple unscoped default routes are unsupported"); defaults[family]=route;
  }
  NSDictionary *v4=defaults[@4],*v6=defaults[@6];
  if (!v4 || (v6 && (![v4[@"interfaceName"]isEqual:v6[@"interfaceName"]] || ![v4[@"interfaceIndex"]isEqual:v6[@"interfaceIndex"]]))) return Fail(error,@"one observable IPv4 default egress is required; IPv6 must use the common observable physical egress when present");
  NSString *physical=v4[@"interfaceName"]; BOOL verified=NO;
  for (NSDictionary *entry in interfaces) if ([entry[@"family"]isEqual:@0] && [entry[@"name"]isEqual:physical] && [entry[@"index"]isEqual:v4[@"interfaceIndex"]] && [entry[@"linkType"]isEqual:@(IFT_ETHER)] &&
    ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_LOOPBACK|IFF_POINTOPOINT))==(IFF_UP|IFF_RUNNING)) verified=YES;
  if (!verified || !Match(physical,@"\\A[a-zA-Z][a-zA-Z0-9]{0,14}\\z")) return Fail(error,@"default egress is not a verified running Ethernet/Wi-Fi interface");
  // Never shadow any pre-existing address/route in the fixed internal pools.
  for (NSDictionary *entry in interfaces) if ([entry[@"address"]isEqual:@"198.18.0.1"] || [entry[@"address"]isEqual:@"198.18.0.2"] || [entry[@"address"]isEqual:@"fdfe:dcba:9876::1"] || [entry[@"address"]isEqual:@"fdfe:dcba:9876::2"]) return Fail(error,@"fixed internal TUN address already exists");
  for (NSDictionary *route in routes) if ([route[@"prefix"]intValue]>0 && (KuroRouteContainsIP(route,@"198.18.0.1") || KuroRouteContainsIP(route,@"198.18.0.2") || KuroRouteContainsIP(route,@"fdfe:dcba:9876::1") || KuroRouteContainsIP(route,@"fdfe:dcba:9876::2"))) return Fail(error,@"existing route overlaps fixed internal DNS/utun pool");
  for (NSString *key in dns) {
    NSDictionary *record=dns[key]; NSString *scoped=[key containsString:@"/Interface/"]?[[key componentsSeparatedByString:@"/"]objectAtIndex:3]:nil;
    NSNumber *index=record[@"InterfaceIndex"]?:record[@"__IF_INDEX__"]; BOOL known=!scoped && !index;
    for (NSDictionary *entry in interfaces) if ((!scoped || [entry[@"name"]isEqual:scoped]) && (!index || [entry[@"index"]isEqual:index])) known=YES;
    if (!known) return Fail(error,@"scoped DNS interface is unavailable; preserving existing resolver");
    for (NSString *address in record[@"ServerAddresses"]) {
      if (!KuroPreservedEndpoint(address,routes,physical,NO,!v6,error)) return NO;
      if ((scoped || index) && (KuroPrivateEndpoint(address) || (!v6 && KuroRouteIP(KuroCanonicalEndpoint(address),6)))) {
        BOOL preserved=NO; for (NSDictionary *route in routes) if ([route[@"prefix"]intValue]>1 && KuroRouteContainsIP(route,address) &&
          (!scoped || [route[@"interfaceName"]isEqual:scoped]) && (!index || [route[@"interfaceIndex"]isEqual:index]) && ([route[@"flags"]unsignedIntValue]&RTF_UP) && !([route[@"flags"]unsignedIntValue]&(RTF_REJECT|RTF_BLACKHOLE))) preserved=YES;
        if (!preserved) return Fail(error,@"scoped LAN DNS server has no preserved route on its original interface");
      }
    }
  }
  NSMutableArray *endpoints=[NSMutableArray array]; NSDictionary *settings=config[@"dns"];
  for (NSString *field in @[@"nameservers",@"bootstrap",@"proxyNameservers"]) [endpoints addObjectsFromArray:settings[field]];
  for (NSDictionary *policy in settings[@"policies"]) [endpoints addObjectsFromArray:policy[@"nameservers"]];
  for (NSDictionary *proxy in config[@"proxies"]) [endpoints addObject:proxy[@"server"]];
  for (NSString *address in endpoints) if (!KuroPreservedEndpoint(address,routes,physical,YES,!v6,error)) return NO;
  _baselineRoutes=routes; _baselineDNS=dns; _physical=[physical copy]; _prepared=YES; return YES;
}
- (BOOL)unchangedBaseline:(NSString **)error { return [self unchangedBaselineInstalled:NO error:error]; }
- (BOOL)unchangedBaselineInstalled:(BOOL)installed error:(NSString **)error {
  NSArray *current=KuroStableRoutes([_routeBackend routes:error]); if (!current) return NO;
  NSMutableArray *remaining=[current mutableCopy];
  for (NSDictionary *before in _baselineRoutes) { NSUInteger index=[remaining indexOfObject:before]; if (index==NSNotFound) return Fail(error,@"route baseline changed during Core startup; preserve all existing routing"); [remaining removeObjectAtIndex:index]; }
  for (NSDictionary *extra in remaining) {
    BOOL recorded=NO; if (installed) for (NSDictionary *target in KuroSplitRouteCandidate(_association)) if (KuroRouteEqual(extra,target)) recorded=YES;
    if (recorded) continue;
    BOOL own=[extra[@"interfaceName"]isEqual:@(_association.interfaceName)] && [extra[@"interfaceIndex"]isEqual:@(_association.interfaceIndex)];
    NSString *destination=extra[@"destination"]; int prefix=[extra[@"prefix"]intValue];
    BOOL expected=([extra[@"family"]isEqual:@4] && (([destination isEqual:@"198.18.0.0"] && prefix==30) || ([destination isEqual:@"198.18.0.1"] && prefix==32))) ||
      ([extra[@"family"]isEqual:@6] && (([destination isEqual:@"fdfe:dcba:9876::"] && prefix==126) || ([destination isEqual:@"fdfe:dcba:9876::1"] && prefix==128) || ([destination hasPrefix:@"fe80:"] && (prefix==64 || prefix==128))));
    if (!own || !expected || ([extra[@"flags"]unsignedIntValue]&(RTF_GATEWAY|RTF_PROTO2))) return Fail(error,@"unexpected route appeared while creating Core utun; refusing takeover");
  }
  NSMutableDictionary *dns=[[_dnsBackend dnsRecords:error]mutableCopy];
  if (installed) {
    NSString *key=KuroDNSKey(_session); if (![dns[key]isEqual:KuroDNSValue()]) return Fail(error,@"owned DNS key changed or disappeared during active session");
    [dns removeObjectForKey:key];
    NSString *failure=nil; if (![[_dnsBackend valueForDNSKey:key error:&failure]isEqual:KuroDNSValue()] || failure) return Fail(error,@"owned DNS direct readback is uncertain");
  }
  if (![dns isEqual:_baselineDNS]) return Fail(error,@"DNS baseline changed; preserving existing resolvers and stopping this session");
  NSArray *interfaces=_environment.interfaces(error); BOOL physical=NO;
  for (NSDictionary *entry in interfaces) if ([entry[@"family"]isEqual:@0] && [entry[@"name"]isEqual:_physical] && [entry[@"linkType"]isEqual:@(IFT_ETHER)] &&
    ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_LOOPBACK|IFF_POINTOPOINT))==(IFF_UP|IFF_RUNNING)) {
      for (NSDictionary *route in _baselineRoutes) if ([route[@"prefix"]isEqual:@0] && [route[@"interfaceName"]isEqual:_physical] && [entry[@"index"]isEqual:route[@"interfaceIndex"]]) physical=YES;
    }
  return physical || Fail(error,@"physical egress disappeared during startup");
}
- (BOOL)readyChild:(pid_t)child session:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || _session || !KuroDNSKey(session) || child<=0) return Fail(error,@"prepared baseline and one held session are required for readiness");
  _session=[session copy]; uint64_t deadline=KuroMonotonicMilliseconds()+1500; NSString *failure=nil;
  do {
    KuroCoreInterface candidate={0}; failure=nil;
    if (_environment.observeChild(child,&candidate,&failure) && candidate.process.pid==child && KuroRouteAssociation(candidate) && KuroCoreAddressesReady(candidate,_environment.interfaces(&failure),&failure)) {
      _association=candidate;
      if (![self unchangedBaseline:error]) return NO;
      if (_environment.ownership(_association,error)!=KuroRouteOwnerLive || !_environment.probeDNS(_association,error) || _environment.ownership(_association,error)!=KuroRouteOwnerLive) return NO;
      return YES;
    }
    usleep(10000);
  } while (KuroMonotonicMilliseconds()<deadline);
  return Fail(error,failure ?: @"fixed dual-stack Core/utun readiness deadline expired");
}
- (BOOL)applyChild:(pid_t)child session:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || ![_session isEqual:session] || child!=_association.process.pid || ![self unchangedBaseline:error]) return Fail(error,@"same ready held Core and unchanged baseline required before network writes");
  if (_environment.ownership(_association,error)!=KuroRouteOwnerLive || !KuroCoreAddressesReady(_association,_environment.interfaces(error),error) || !_environment.probeDNS(_association,error)) return NO;
  if (![_routes installForSession:session interface:_association routes:KuroSplitRouteCandidate(_association) ownership:_environment.ownership error:error]) return NO;
  KuroCoreInterface association=_association; KuroNetworkEnvironment *environment=_environment;
  if (![_dns installForSession:session routes:_routes interface:_association ownership:_environment.ownership dnsReady:^BOOL(NSString **failure) { return KuroCoreAddressesReady(association,environment.interfaces(failure),failure) && environment.probeDNS(association,failure); } error:error]) return NO;
  return [self confirmSession:session error:error];
}
- (BOOL)confirmSession:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || ![_session isEqual:session] || !KuroRouteAssociation(_association)) return Fail(error,@"active held session is required for network confirmation");
  if (![_routes confirmInstalledSession:session interface:_association ownership:_environment.ownership error:error] || ![self unchangedBaselineInstalled:YES error:error] ||
    !KuroCoreAddressesReady(_association,_environment.interfaces(error),error) || !_environment.probeDNS(_association,error)) return NO;
  return _environment.ownership(_association,error)==KuroRouteOwnerLive || Fail(error,@"held Core owner changed during active network confirmation");
}
- (NSDictionary *)stoppedEvidenceForSession:(NSString *)session error:(NSString **)error {
  if(!pthread_equal(_thread,pthread_self()) || !session || ![_stoppedEvidence[@"session"]isEqual:session] || !_networkOff || !_routes.routesOff || !_dns.dnsOff ||
    Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) || Exists([_directory stringByAppendingPathComponent:KuroDNSJournal])) {
    Fail(error,@"this session has no independent route and DNS cleanup confirmation");return nil;
  }
  return [_stoppedEvidence copy];
}
- (BOOL)recoverSession:(NSString *)session error:(NSString **)error {
  NSDictionary *previous=_stoppedEvidence; _stoppedEvidence=nil;
  BOOL held=session && ([_session isEqual:session] || _prepared || [previous[@"session"]isEqual:session]);
  NSMutableDictionary *journals=[NSMutableDictionary dictionary];
  if(held)for(NSString *name in @[KuroRouteJournal,KuroDNSJournal]) {
    NSString *path=[_directory stringByAppendingPathComponent:name];
    NSData *bytes=Exists(path)?ReadProtected(_directory,path,_owner,error):nil;
    if(Exists(path)&&!bytes)return NO;
    journals[name]=bytes?Hash(bytes):(id)NSNull.null;
  }
  _networkOff=NO; if (![self adapters:error]) return NO;
  if (session && !KuroDNSKey(session)) return Fail(error,@"recovery session identifier is invalid");
  if (_session && ![_session isEqual:session]) return Fail(error,@"network recovery cannot replace the held session owner");
  if (_session && KuroRouteAssociation(_association)) {
    KuroRouteOwnerState state=_environment.ownership(_association,error); if (state==KuroRouteOwnerUnknown) return NO;
    // Stop can call this after reaping the original Core. Its disappearing utun
    // must already have removed routes; presence is an unknown conflict.
    if (![_dns recoverDNS:error] || ![_routes recoverForInterface:_association ownership:_environment.ownership error:error]) return NO;
  } else {
    // DNS authority is the protected exact UUID journal, not old process data.
    // Route recovery remains absence-only. Neither failure blocks the other
    // component's independent bounded recovery attempt.
    NSString *dnsFailure=nil,*routeFailure=nil;
    BOOL dnsRecovered=[_dns recoverDNS:&dnsFailure];
    BOOL routesRecovered=[_routes recoverRecordedAbsence:&routeFailure];
    if(!dnsRecovered || !routesRecovered) {
      NSMutableArray *failures=[NSMutableArray array];
      if(!dnsRecovered)[failures addObject:[@"DNS: "stringByAppendingString:dnsFailure?:@"recovery not confirmed"]];
      if(!routesRecovered)[failures addObject:[@"routes: "stringByAppendingString:routeFailure?:@"absence not confirmed"]];
      return Fail(error,[failures componentsJoinedByString:@"; "]);
    }
  }
  _networkOff=_routes.routesOff && _dns.dnsOff;
  if(_networkOff && held) {
    _stoppedEvidence=@{@"format":@1,@"session":session,@"routesOff":@YES,@"dnsOff":@YES,
      @"routeJournalSHA256":previous[@"routeJournalSHA256"]?:journals[KuroRouteJournal],@"dnsJournalSHA256":previous[@"dnsJournalSHA256"]?:journals[KuroDNSJournal]};
  }
  if (_networkOff) { _session=nil; memset(&_association,0,sizeof(_association)); _prepared=NO; _physical=nil; _baselineRoutes=nil; _baselineDNS=nil; }
  return _networkOff || Fail(error,@"network recovery lacks independent route/DNS absence proofs");
}
// Fresh evidence describes actual current backend absence, not a held session's
// historical writes and not the mere disappearance of journal files.
- (NSDictionary *)recoverRecordedSession:(NSString *)session error:(NSString **)error {
  if(!KuroDNSKey(session) || ![self recoverSession:nil error:error])return nil;
  NSArray *routes=KuroStableRoutes([_routeBackend routes:error]);
  NSDictionary *dns=[_dnsBackend dnsRecords:error];
  if(!routes || ![dns isKindOfClass:NSDictionary.class]){Fail(error,@"complete current route/DNS readback unavailable");return nil;}
  for(NSDictionary *route in routes)if(([route[@"flags"]unsignedIntValue]&RTF_PROTO2) || ([route[@"prefix"]intValue]==1 && ([route[@"flags"]unsignedIntValue]&RTF_UP))) {Fail(error,@"current marked/split-default route is not absent");return nil;}
  for(NSDictionary *route in routes)if([route[@"prefix"]intValue]>0 && (KuroRouteContainsIP(route,@"198.18.0.1") || KuroRouteContainsIP(route,@"198.18.0.2") || KuroRouteContainsIP(route,@"fdfe:dcba:9876::1") || KuroRouteContainsIP(route,@"fdfe:dcba:9876::2"))){Fail(error,@"current route overlaps the fixed utun/internal DNS pool");return nil;}
  for(id key in dns)if(![key isKindOfClass:NSString.class] || [key hasPrefix:KuroDNSPrefix]){Fail(error,@"current owned DNS UUID key is not absent");return nil;}
  if(!_networkOff || Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) || Exists([_directory stringByAppendingPathComponent:KuroDNSJournal])){Fail(error,@"current network receipts are not durably retired");return nil;}
  return @{@"format":@1,@"kind":@"current-owned-absence",@"session":session,@"routesOff":@YES,@"dnsOff":@YES};
}

@end
