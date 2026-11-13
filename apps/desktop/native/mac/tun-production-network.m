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
// Private syscall seam; production always supplies the real fixed operations.
typedef struct {
  int (*openSocket)(int,int,int); int (*control)(int,int,int);
  int (*option)(int,int,int,const void *,socklen_t); int (*connectSocket)(int,const struct sockaddr *,socklen_t);
  ssize_t (*sendPacket)(int,const void *,size_t,int); int (*waitPacket)(struct pollfd *,nfds_t,int);
  ssize_t (*receivePacket)(int,void *,size_t,int); int (*closeSocket)(int);
} KuroDNSProbeIO;
static int KuroDNSProbeControl(int fd,int operation,int value) { return fcntl(fd,operation,value); }
static NSString *KuroDNSProbeResponseReason(NSData *packet,NSData *question) {
  if(packet.length<12)return @"short-header";
  if(packet.length>512)return @"oversized-datagram";
  const unsigned char *b=packet.bytes,*q=question.bytes;
  if(memcmp(b,q,2))return @"transaction-id";
  if(!(b[2]&0x80)||(b[2]&0x7a))return @"response-flags";
  if(b[3]&0x0f)return @"response-rcode";
  if(KuroDNSWord(b+4)!=1||KuroDNSWord(b+6)!=1||KuroDNSWord(b+8)||KuroDNSWord(b+10))return @"record-counts";
  if(packet.length<question.length+12)return @"short-answer";
  if(memcmp(b+12,q+12,question.length-12))return @"fixed-question-mismatch";
  return @"fixed-answer-record-or-address";
}
static BOOL KuroProbeInternalDNSWithIO(KuroCoreInterface association,NSString **error,const KuroDNSProbeIO *io) {
  for (NSNumber *family in @[@4,@6]) {
    uint64_t started=KuroMonotonicMilliseconds();
    BOOL ipv6=family.intValue==6; int af=ipv6?AF_INET6:AF_INET;
    NSString *stage=@"socket",*reason=@"",*header=@""; int savedErrno=0,polled=0;short revents=0;ssize_t sent=-1,count=-1;BOOL ok=NO;
    int fd=io->openSocket(af,SOCK_DGRAM,0);if(fd<0)savedErrno=errno;
    NSData *question=KuroReadinessQuestion((uint16_t)arc4random_uniform(65536),ipv6);
    if(fd>=0)do {
      stage=@"fcntl-getfl";int flags=io->control(fd,F_GETFL,0);if(flags<0){savedErrno=errno;break;}
      stage=@"fcntl-cloexec";if(io->control(fd,F_SETFD,FD_CLOEXEC)){savedErrno=errno;break;}
      stage=@"fcntl-nonblock";if(io->control(fd,F_SETFL,flags|O_NONBLOCK)){savedErrno=errno;break;}
      unsigned int index=association.interfaceIndex;stage=@"setsockopt-bound-interface";
      if(io->option(fd,ipv6?IPPROTO_IPV6:IPPROTO_IP,ipv6?IPV6_BOUND_IF:IP_BOUND_IF,&index,sizeof(index))){savedErrno=errno;break;}
      struct sockaddr_storage storage={0};socklen_t size;
      if(ipv6){struct sockaddr_in6 *address=(void *)&storage;address->sin6_len=sizeof(*address);address->sin6_family=af;address->sin6_port=htons(53);inet_pton(af,"fdfe:dcba:9876::2",&address->sin6_addr);size=sizeof(*address);}
      else{struct sockaddr_in *address=(void *)&storage;address->sin_len=sizeof(*address);address->sin_family=af;address->sin_port=htons(53);inet_pton(af,"198.18.0.2",&address->sin_addr);size=sizeof(*address);}
      stage=@"connect";if(io->connectSocket(fd,(struct sockaddr *)&storage,size)){savedErrno=errno;break;}
      stage=@"send";sent=io->sendPacket(fd,question.bytes,question.length,0);if(sent!=(ssize_t)question.length){if(sent<0)savedErrno=errno;break;}
      stage=@"poll";struct pollfd ready={.fd=fd,.events=POLLIN};uint64_t deadline=KuroMonotonicMilliseconds()+400;
      do{uint64_t now=KuroMonotonicMilliseconds();if(now>=deadline)break;polled=io->waitPacket(&ready,1,(int)(deadline-now));if(polled<0)savedErrno=errno;else savedErrno=0;}while(polled<0&&savedErrno==EINTR);
      revents=ready.revents;if(polled<=0||!(revents&POLLIN))break;
      stage=@"recv";unsigned char bytes[513];count=io->receivePacket(fd,bytes,sizeof(bytes),0);if(count<=0){if(count<0)savedErrno=errno;break;}
      NSData *packet=[NSData dataWithBytes:bytes length:(NSUInteger)count];stage=@"response-validation";
      ok=KuroReadinessAnswer(packet,question,ipv6);
      if(!ok){reason=KuroDNSProbeResponseReason(packet,question);NSMutableString *value=[NSMutableString string];for(NSUInteger i=0;i<MIN(packet.length,12);i++)[value appendFormat:@"%02x",bytes[i]];header=value;}
    }while(NO);
    if(fd>=0)io->closeSocket(fd); // Never overwrite the failing operation's errno.
    if(!ok)return Fail(error,[NSString stringWithFormat:@"fixed internal IPv%@ DNS static-host probe was not confirmed; stage=%@; elapsedMs=%llu; errno=%d; poll=%d; revents=0x%x; sent=%lld/%lu; received=%lld; header=%@; reason=%@",family,stage,(unsigned long long)(KuroMonotonicMilliseconds()-started),savedErrno,polled,(unsigned short)revents,(long long)sent,(unsigned long)question.length,(long long)count,header,reason]);
  }
  return YES;
}
static BOOL KuroProbeInternalDNS(KuroCoreInterface association, NSString **error) {
  const KuroDNSProbeIO io={socket,KuroDNSProbeControl,setsockopt,connect,send,poll,recv,close};
  return KuroProbeInternalDNSWithIO(association,error,&io);
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
    if (KuroObserveExpectedCoreInterface(expected,&current,&failure) && [KuroRouteAssociation(current)isEqual:KuroRouteAssociation(expected)]) return KuroRouteOwnerLive;
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
// XNU in6.c adds only these scoped multicast parents while configuring an
// IPv6 address. Recognize the observed link-local case, never a write/delete
// target: the held interface and an independent current address must agree.
static BOOL KuroHeldMulticastCompanion(NSDictionary *route, KuroCoreInterface association, NSArray *interfaces) {
  unsigned int index=association.interfaceIndex;
  if (![route[@"family"]isEqual:@6] || ![route[@"interfaceName"]isEqual:@(association.interfaceName)] ||
    ![route[@"interfaceIndex"]isEqual:@(index)] || [route[@"flags"]unsignedIntValue]!=(RTF_UP|RTF_CLONING|RTF_MULTICAST|RTF_IFSCOPE)) return NO;
  NSString *destination=route[@"destination"]; int prefix=[route[@"prefix"]intValue];
  BOOL known=(prefix==8 && [destination isEqual:[NSString stringWithFormat:@"ff00::%%%u",index]]) ||
    (prefix==32 && ([destination isEqual:[NSString stringWithFormat:@"ff01::%%%u",index]] || [destination isEqual:[NSString stringWithFormat:@"ff02::%%%u",index]]));
  if (!known || ![interfaces isKindOfClass:NSArray.class]) return NO;
  NSString *gateway=nil; NSUInteger matches=0;
  for (NSDictionary *entry in interfaces) {
    if (![entry[@"name"]isEqual:@(association.interfaceName)] && ![entry[@"index"]isEqual:@(index)]) continue;
    if (![entry[@"name"]isEqual:@(association.interfaceName)] || ![entry[@"index"]isEqual:@(index)] ||
      ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT))!=(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT)) return NO;
    if (![entry[@"family"]isEqual:@6]) continue;
    struct in6_addr address={0};
    if (inet_pton(AF_INET6,[entry[@"address"]UTF8String],&address)!=1) return NO;
    if (!IN6_IS_ADDR_LINKLOCAL(&address)) continue;
    if (![entry[@"prefix"]isEqual:@64]) return NO;
    char text[INET6_ADDRSTRLEN]={0}; if (!inet_ntop(AF_INET6,&address,text,sizeof(text))) return NO;
    gateway=[NSString stringWithFormat:@"%s%%%u",text,index]; matches++;
  }
  return matches==1 && [route[@"gateway"]isEqual:gateway];
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

// The same admitted literal/scoped-DNS path checks are used at preflight and
// during the held session. No config credentials or arbitrary config are saved.
static BOOL KuroNetworkPreservedPaths(NSArray *routes,NSArray *interfaces,NSDictionary *dns,NSArray *endpoints,NSString *physical,BOOL missingIPv6Default,NSString **error) {
  for (NSString *key in dns) {
    NSDictionary *record=dns[key]; NSString *scoped=[key containsString:@"/Interface/"]?[[key componentsSeparatedByString:@"/"]objectAtIndex:3]:nil;
    NSNumber *index=record[@"InterfaceIndex"]?:record[@"__IF_INDEX__"]; BOOL known=!scoped && !index;
    for (NSDictionary *entry in interfaces) if ((!scoped || [entry[@"name"]isEqual:scoped]) && (!index || [entry[@"index"]isEqual:index])) known=YES;
    if (!known) return Fail(error,@"scoped DNS interface is unavailable; preserving existing resolver");
    for (NSString *address in record[@"ServerAddresses"]) {
      if (!KuroPreservedEndpoint(address,routes,physical,NO,missingIPv6Default,error)) return NO;
      if ((scoped || index) && (KuroPrivateEndpoint(address) || (missingIPv6Default && KuroRouteIP(KuroCanonicalEndpoint(address),6)))) {
        BOOL preserved=NO; for (NSDictionary *route in routes) if ([route[@"prefix"]intValue]>1 && KuroRouteContainsIP(route,address) &&
          (!scoped || [route[@"interfaceName"]isEqual:scoped]) && (!index || [route[@"interfaceIndex"]isEqual:index]) && ([route[@"flags"]unsignedIntValue]&RTF_UP) && !([route[@"flags"]unsignedIntValue]&(RTF_REJECT|RTF_BLACKHOLE))) preserved=YES;
        if (!preserved) return Fail(error,@"scoped LAN DNS server has no preserved route on its original interface");
      }
    }
  }
  for (NSString *address in endpoints) if (!KuroPreservedEndpoint(address,routes,physical,YES,missingIPv6Default,error)) return NO;
  return YES;
}
static BOOL KuroLocalRouteChange(NSDictionary *route,NSArray *interfaces,NSArray *endpoints,NSDictionary *dns,KuroCoreInterface association) {
  NSString *name=route[@"interfaceName"],*destination=route[@"destination"];NSNumber *index=route[@"interfaceIndex"];
  if ([name isEqual:@(association.interfaceName)] || [index isEqual:@(association.interfaceIndex)] || ![route[@"gateway"]isEqual:@"link"]) return NO;
  // A local address is not harmless if it takes over an admitted server path.
  for (NSString *address in endpoints) if (KuroRouteContainsIP(route,address)) return NO;
  for (NSDictionary *record in dns.allValues) for (NSString *address in record[@"ServerAddresses"]) if (KuroRouteContainsIP(route,address)) return NO;
  NSUInteger links=0;BOOL local=NO,linkLocal4=NO,linkLocal6=NO;
  for (NSDictionary *entry in interfaces) {
    if (![entry[@"name"]isEqual:name] && ![entry[@"index"]isEqual:index]) continue;
    if (![entry[@"name"]isEqual:name] || ![entry[@"index"]isEqual:index] ||
      ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_LOOPBACK|IFF_POINTOPOINT))!=(IFF_UP|IFF_RUNNING)) return NO;
    if ([entry[@"family"]isEqual:@0]) { if (![entry[@"linkType"]isEqual:@(IFT_ETHER)]) return NO; links++; }
    if ([entry[@"family"]isEqual:route[@"family"]] && [entry[@"address"]isEqual:destination]) local=YES;
    NSData *v4=KuroRouteIP(entry[@"address"],4);
    if (v4 && ((const unsigned char *)v4.bytes)[0]==169 && ((const unsigned char *)v4.bytes)[1]==254 && [entry[@"prefix"]isEqual:@16]) linkLocal4=YES;
    struct in6_addr v6={0};
    if ([entry[@"family"]isEqual:@6] && inet_pton(AF_INET6,[entry[@"address"]UTF8String],&v6)==1 && IN6_IS_ADDR_LINKLOCAL(&v6) && [entry[@"prefix"]isEqual:@64]) linkLocal6=YES;
  }
  if (links!=1) return NO;
  unsigned int flags=[route[@"flags"]unsignedIntValue];int prefix=[route[@"prefix"]intValue];
  // Sanitized Darwin snapshots have UP|STATIC|CLONING local IPv4 routes,
  // including /32 entries without HOST. Address evidence, not flags, binds them.
  if ([route[@"family"]isEqual:@4] && flags==(RTF_UP|RTF_STATIC|RTF_CLONING))
    return (prefix==32 && local) || (prefix==16 && [destination isEqual:@"169.254.0.0"] && linkLocal4);
  if (![route[@"family"]isEqual:@6] || !linkLocal6) return NO;
  NSString *zone=[NSString stringWithFormat:@"%%%u",index.unsignedIntValue];
  if (prefix==64 && [destination isEqual:[@"fe80::"stringByAppendingString:zone]] && flags==(RTF_UP|RTF_CLONING|RTF_IFSCOPE)) return YES;
  BOOL multicast=(prefix==8 && [destination isEqual:[@"ff00::"stringByAppendingString:zone]]) ||
    (prefix==32 && ([destination isEqual:[@"ff01::"stringByAppendingString:zone]] || [destination isEqual:[@"ff02::"stringByAppendingString:zone]]));
  return multicast && flags==(RTF_UP|RTF_CLONING|RTF_MULTICAST|RTF_IFSCOPE);
}

// Exact multisets retain duplicate-baseline detection while allowing dump order changes.
static BOOL KuroNetworkSameRoutes(NSArray *left,NSArray *right) {
  if(![left isKindOfClass:NSArray.class]||![right isKindOfClass:NSArray.class]||left.count!=right.count)return NO;
  NSMutableArray *remaining=[right mutableCopy];
  for(id route in left){NSUInteger index=[remaining indexOfObject:route];if(index==NSNotFound)return NO;[remaining removeObjectAtIndex:index];}
  return !remaining.count;
}
// Bounded summary of already read snapshots, never cleanup authority.
static NSString *KuroRouteBaselineDifference(NSArray *before,NSArray *after) {
  NSMutableArray *remaining=[after mutableCopy];NSUInteger missing=0;NSDictionary *firstMissing=nil;
  for(NSDictionary *route in before) {
    NSUInteger index=[remaining indexOfObject:route];
    if(index==NSNotFound){missing++;if(!firstMissing)firstMissing=route;}
    else [remaining removeObjectAtIndex:index];
  }
  NSDictionary *firstUnmatched=remaining.firstObject;
  NSDictionary *summary=@{@"missing":@(missing),@"unmatched":@(remaining.count),@"firstMissing":firstMissing?:NSNull.null,@"firstUnmatched":firstUnmatched?:NSNull.null,@"examplesOmitted":@NO};
  NSData *encoded=JSONData(summary);
  if(!encoded || encoded.length>768)encoded=JSONData(@{@"missing":@(missing),@"unmatched":@(remaining.count),@"examplesOmitted":@YES,@"firstMissingSHA256":firstMissing?Hash(JSONData(firstMissing)):@"",@"firstUnmatchedSHA256":firstUnmatched?Hash(JSONData(firstUnmatched)):@""});
  return [@"routeDiff="stringByAppendingString:[[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding]?:@"unavailable"];
}
static NSDictionary *KuroNetworkOwnerBinding(NSDictionary *owner) {
  if(!KuroRestartRecord(owner,NULL))return nil;
  NSDictionary *launch=owner[@"launch"];
  NSDictionary *binding=@{@"configSHA256":launch[@"configSHA256"]?:NSNull.null,@"runtimeSHA256":launch[@"runtimeSHA256"]?:NSNull.null,@"coreSHA256":launch[@"coreSHA256"]?:NSNull.null,@"template":launch[@"template"]?:NSNull.null,
    @"process":@{@"pid":owner[@"pid"],@"startSeconds":owner[@"startSeconds"],@"startMicros":owner[@"startMicros"]}};
  return KuroRouteBinding(binding)?binding:nil;
}
// configd promotes this session's exact catch-all resolver to Global. The
// original default and every other resolver remain part of the frozen baseline.
static NSDictionary *KuroDNSDerivedGlobal(NSDictionary *global, NSString *session) {
  if (!KuroDNSKey(session) || ![global isKindOfClass:NSDictionary.class] || global.count!=5 ||
    !KuroDNSPreflight(@{@"State:/Network/Global/DNS":global},NULL) ||
    !KuroNumber(global[@"__ORDER__"],0,0)) return nil;
  return @{@"ServerAddresses":KuroDNSValue()[@"ServerAddresses"],@"SearchOrder":@1,
    @"__CONFIGURATION_ID__":[NSString stringWithFormat:@"Supplemental: dev.kuro.tun.%@ 0",session],
    @"__ORDER__":@0,@"__FLAGS__":@([global[@"__FLAGS__"]unsignedIntValue]|0x4000)};
}
static BOOL KuroDNSOwnDerivedBaseline(NSDictionary *before, NSDictionary *after, NSString *session) {
  if (![before isKindOfClass:NSDictionary.class] || ![after isKindOfClass:NSDictionary.class]) return NO;
  NSString *key=@"State:/Network/Global/DNS";
  NSDictionary *expected=KuroDNSDerivedGlobal(before[key],session),*observed=after[key];
  if (!expected || ![observed isKindOfClass:NSDictionary.class] ||
    !KuroNumber(observed[@"SearchOrder"],1,1) || !KuroNumber(observed[@"__ORDER__"],0,0) ||
    !KuroNumber(observed[@"__FLAGS__"],0,UINT32_MAX)) return NO;
  NSMutableDictionary *snapshot=[before mutableCopy];snapshot[key]=expected;
  return [after isEqual:snapshot];
}
// Failure-only summary of the existing snapshot. Never disclose resolver values,
// arbitrary dictionary keys, domains, or service identifiers.
static NSString *KuroDNSBaselineDifference(NSDictionary *before, NSDictionary *after, NSString *session) {
  if (![after isKindOfClass:NSDictionary.class]) return @"dnsDiff snapshot=unavailable";
  NSString *key=@"State:/Network/Global/DNS"; NSUInteger added=0,removed=0,changed=0;
  for (id entry in after) { if (!before[entry]) added++; else if (![after[entry]isEqual:before[entry]]) changed++; }
  for (id entry in before) if (!after[entry]) removed++;
  NSDictionary *a=[before[key]isKindOfClass:NSDictionary.class]?before[key]:@{};
  NSDictionary *b=[after[key]isKindOfClass:NSDictionary.class]?after[key]:@{};
  BOOL (^equal)(id,id)=^BOOL(id x,id y){return x==y || [x isEqual:y];};
  NSArray *fields=@[@"__CONFIGURATION_ID__",@"__ORDER__",@"__IF_INDEX__",@"InterfaceIndex",@"__FLAGS__",@"ServerAddresses",@"DomainName",@"SearchDomains",@"SearchOrder",@"SupplementalMatchDomains",@"SupplementalMatchOrders"];
  NSArray *labels=@[@"cid",@"order",@"if",@"publicIf",@"flags",@"servers",@"domain",@"search",@"searchOrder",@"match",@"matchOrder"];
  NSMutableArray *differences=[NSMutableArray array]; NSUInteger unknown=0;
  for (NSUInteger i=0;i<fields.count;i++) if (!equal(a[fields[i]],b[fields[i]])) [differences addObject:labels[i]];
  NSMutableSet *all=[NSMutableSet setWithArray:a.allKeys];[all addObjectsFromArray:b.allKeys];
  for (id field in all) if (![fields containsObject:field]&&!equal(a[field],b[field])) unknown++;
  NSString *(^metadata)(NSDictionary *)=^NSString *(NSDictionary *value){
    id cid=value[@"__CONFIGURATION_ID__"]; NSString *kind=@"other";
    if (!cid) kind=@"missing";
    else if ([cid isKindOfClass:NSString.class]) { if ([cid hasPrefix:@"Default: "])kind=@"Default";else if ([cid hasPrefix:@"Supplemental: "])kind=@"Supplemental"; }
    BOOL own=session&&[cid isEqual:[NSString stringWithFormat:@"Supplemental: dev.kuro.tun.%@ 0",session]];
    NSMutableArray *numbers=[NSMutableArray array];
    for (NSString *field in @[@"__ORDER__",@"__IF_INDEX__",@"InterfaceIndex",@"__FLAGS__"]) { id number=value[field];[numbers addObject:!number?@"-":KuroNumber(number,0,UINT32_MAX)?[number stringValue]:@"invalid"]; }
    return [NSString stringWithFormat:@"%@/self%d:%@",kind,own,[numbers componentsJoinedByString:@","]];
  };
  NSDictionary *own=KuroDNSValue();
  NSString *summary=[NSString stringWithFormat:@"dnsDiff keys=+%lu/-%lu/~%lu;global=%@;fields=%@;unknown=%lu;meta(order,if,publicIf,flags)=%@->%@;eq(base/own)servers=%d/%d,match=%d/%d,orders=%d/%d;domainAbsent=%d;searchOrder1=%d",
    (unsigned long)added,(unsigned long)removed,(unsigned long)changed,!after[key]?@"removed":!before[key]?@"added":equal(a,b)?@"same":@"changed",[differences componentsJoinedByString:@","],(unsigned long)unknown,metadata(a),metadata(b),
    equal(b[@"ServerAddresses"],a[@"ServerAddresses"]),equal(b[@"ServerAddresses"],own[@"ServerAddresses"]),equal(b[@"SupplementalMatchDomains"],a[@"SupplementalMatchDomains"]),equal(b[@"SupplementalMatchDomains"],own[@"SupplementalMatchDomains"]),equal(b[@"SupplementalMatchOrders"],a[@"SupplementalMatchOrders"]),equal(b[@"SupplementalMatchOrders"],own[@"SupplementalMatchOrders"]),b[@"DomainName"]==nil,equal(b[@"SearchOrder"],@1)];
  // All emitted characters are fixed ASCII labels, bounded numbers and booleans.
  return [summary substringToIndex:MIN(summary.length,(NSUInteger)512)];
}
// Only rejects current session footprints. It grants no route deletion or
// authority over unrelated physical routes, including a changed address.
static BOOL KuroCurrentOwnedRoutesAbsent(NSArray *routes, NSDictionary *association, NSString **error) {
  for (NSDictionary *route in routes) {
    if (([route[@"flags"]unsignedIntValue]&RTF_PROTO2) || ([route[@"prefix"]intValue]==1 && ([route[@"flags"]unsignedIntValue]&RTF_UP)))
      return Fail(error,@"current marked/split-default route is not absent; stage=route-owned-absence");
    if (association && ([route[@"interfaceName"]isEqual:association[@"interfaceName"]] || [route[@"interfaceIndex"]isEqual:association[@"interfaceIndex"]]))
      return Fail(error,@"recorded utun route is not absent; stage=route-owned-absence");
    if (KuroRouteOverlapsCorePool(route))
      return Fail(error,@"current route overlaps the fixed utun/internal DNS pool; stage=route-owned-absence");
  }
  return YES;
}
@interface KuroProductionNetwork : NSObject {
  NSString *_directory; uid_t _owner; pthread_t _thread;
  id<KuroRouteStore> _routeBackend; id<KuroDNSStore> _dnsBackend; KuroNetworkEnvironment *_environment;
  KuroOwnedRoutes *_routes; KuroOwnedDNS *_dns;
  NSArray *_baselineRoutes,*_baselineInterfaces,*_pathEndpoints; NSDictionary *_baselineDNS; NSString *_physical, *_session;
  KuroCoreInterface _association; BOOL _prepared, _networkOff, _internalDNSReady;
  NSArray *_installedRoutes;
  NSDictionary *_stoppedEvidence,*_binding,*_recoveryOwner,*_recoveryObservation,*_retiredRouteRecord;
  KuroSessionHook _writerAbsent;
}
@property(nonatomic,readonly) NSString *runtimeInterfaceName;
@property(nonatomic,readonly) BOOL networkOff;
@property(nonatomic,readonly) NSDictionary *recoveryObservation;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner routes:(id<KuroRouteStore>)routes dns:(id<KuroDNSStore>)dns environment:(KuroNetworkEnvironment *)environment;
- (BOOL)preflightConfig:(NSDictionary *)config error:(NSString **)error;
- (BOOL)prepareSession:(NSString *)session binding:(NSDictionary *)binding error:(NSString **)error;
- (BOOL)readyChild:(pid_t)child session:(NSString *)session error:(NSString **)error;
- (BOOL)applyChild:(pid_t)child session:(NSString *)session error:(NSString **)error;
- (BOOL)recoverSession:(NSString *)session error:(NSString **)error;
- (NSDictionary *)recoverRecordedOwner:(NSDictionary *)owner error:(NSString **)error;
- (NSDictionary *)recoverRecordedOwner:(NSDictionary *)owner writerAbsent:(KuroSessionHook)writerAbsent error:(NSString **)error;
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
- (NSDictionary *)recoveryObservation { return [_recoveryObservation copy]; }
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
  _prepared=NO; _physical=nil; _installedRoutes=nil; _internalDNSReady=NO;
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
  NSMutableArray *endpoints=[NSMutableArray array]; NSDictionary *settings=config[@"dns"];
  for (NSString *field in @[@"nameservers",@"bootstrap",@"proxyNameservers"]) [endpoints addObjectsFromArray:settings[field]];
  for (NSDictionary *policy in settings[@"policies"]) [endpoints addObjectsFromArray:policy[@"nameservers"]];
  for (NSDictionary *proxy in config[@"proxies"]) [endpoints addObject:proxy[@"server"]];
  if (!KuroNetworkPreservedPaths(routes,interfaces,dns,endpoints,physical,!v6,error)) return NO;
  _baselineRoutes=routes; _baselineInterfaces=[interfaces copy]; _pathEndpoints=[endpoints copy]; _baselineDNS=dns; _physical=[physical copy]; _prepared=YES; return YES;
}
// No route writer exists here. Complete observations and their protected
// pre-resume baseline record, not an in-memory phase, gate DNS publication.
- (BOOL)confirmedRoutePlan:(NSArray *)plan error:(NSString **)error {
  NSDictionary *record=[_routes recordForInterface:_association bytes:NULL error:error];
  if (!plan || ![record[@"phase"]isEqual:@"observed"] || ![record[@"binding"]isEqual:_binding] || ![record[@"session"]isEqual:_session] || ![record[@"routes"]isEqual:plan])
    return Fail(error,@"network readiness lacks its exact Core route observation");
  return [_routes confirmObservedSession:_session interface:_association ownership:_environment.ownership error:error];
}
- (BOOL)prepareSession:(NSString *)session binding:(NSDictionary *)binding error:(NSString **)error {
  if (![self adapters:error] || !_prepared || _session || !KuroDNSKey(session))return Fail(error,@"one clean preflight is required before Core resume");
  // Preparation occurs while the exact held child is suspended. Freeze the
  // same baseline again before granting that child any network side effects.
  NSArray *routes=KuroStableRoutes([_routeBackend routes:error]);
  NSDictionary *dns=[_dnsBackend dnsRecords:error];
  if (!KuroNetworkSameRoutes(routes,_baselineRoutes) || ![dns isEqual:_baselineDNS])
    return Fail(error,@"route or DNS baseline changed before Core resume");
  if(![self unchangedBaseline:error])return NO;
  // Save the trusted owner before publishing: a failed final fsync may leave a
  // valid intent that this held worker must still reconcile after child reap.
  if(!KuroRouteBinding(binding))return Fail(error,@"trusted prepared Core binding is invalid");
  _session=[session copy];_binding=[binding copy];
  return [_routes prepareForSession:session binding:binding baselineRoutes:_baselineRoutes baselineDNS:_baselineDNS physicalInterface:_physical error:error];
}
- (BOOL)unchangedBaseline:(NSString **)error { return [self unchangedBaselineInstalled:NO error:error]; }
- (BOOL)unchangedBaselineInstalled:(BOOL)installed error:(NSString **)error {
  if (_installedRoutes && ![self confirmedRoutePlan:_installedRoutes error:error]) return NO;
  NSArray *current=KuroStableRoutes([_routeBackend routes:error]); if (!current) return NO;
  NSArray *interfaces=_environment.interfaces(error); if (!interfaces) return NO;
  BOOL dynamic=_installedRoutes && KuroRouteAssociation(_association);
  if (dynamic) for (NSDictionary *entry in interfaces) {
    BOOL pool=[@[@"198.18.0.1",@"198.18.0.2",@"fdfe:dcba:9876::1",@"fdfe:dcba:9876::2"]containsObject:entry[@"address"]?:@""];
    if (pool && (![entry[@"name"]isEqual:@(_association.interfaceName)] || ![entry[@"index"]isEqual:@(_association.interfaceIndex)])) return Fail(error,@"fixed internal TUN address appeared on another interface");
  }
  NSMutableArray *remaining=[current mutableCopy];
  for (NSDictionary *before in _baselineRoutes) { NSUInteger index=[remaining indexOfObject:before]; if (index==NSNotFound) { if (dynamic && KuroLocalRouteChange(before,_baselineInterfaces,_pathEndpoints,_baselineDNS,_association)) continue; return Fail(error,[NSString stringWithFormat:@"route baseline changed; preserve all existing routing; dnsPublished=%d; %@",installed,KuroRouteBaselineDifference(_baselineRoutes,current)]); } [remaining removeObjectAtIndex:index]; }
  for (NSDictionary *extra in remaining) {
    BOOL recorded=NO; for (NSDictionary *target in _installedRoutes) if (KuroCoreAutoRouteEqual(extra,target)) recorded=YES;
    if (recorded) continue;
    if (KuroHeldMulticastCompanion(extra,_association,interfaces)) continue;
    NSUInteger equal=0;for (NSDictionary *entry in current) if ([entry isEqual:extra]) equal++;
    if (dynamic && equal==1 && KuroLocalRouteChange(extra,interfaces,_pathEndpoints,_baselineDNS,_association)) continue;
    BOOL own=[extra[@"interfaceName"]isEqual:@(_association.interfaceName)] && [extra[@"interfaceIndex"]isEqual:@(_association.interfaceIndex)];
    NSString *destination=extra[@"destination"]; int prefix=[extra[@"prefix"]intValue];
    BOOL expected=([extra[@"family"]isEqual:@4] && (([destination isEqual:@"198.18.0.0"] && prefix==30) || ([destination isEqual:@"198.18.0.1"] && prefix==32))) ||
      ([extra[@"family"]isEqual:@6] && (([destination isEqual:@"fdfe:dcba:9876::"] && prefix==126) || ([destination isEqual:@"fdfe:dcba:9876::1"] && prefix==128) || ([destination hasPrefix:@"fe80:"] && (prefix==64 || prefix==128))));
    if (!own || !expected || ([extra[@"flags"]unsignedIntValue]&(RTF_GATEWAY|RTF_PROTO2))) {
      // Preserve the exact closed read-only entry before stopping the child.
      // This evidence never changes admission or grants cleanup authority.
      NSData *encoded=JSONData(extra);
      NSString *observed=encoded && encoded.length<=1024 ? [[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding] : @"[route evidence unavailable or oversized]";
      return Fail(error,[NSString stringWithFormat:@"unexpected route appeared while creating Core utun; refusing takeover; phase=%@; owned-interface=%s/%u; observed=%@",installed?@"active verification":@"Core startup",_association.interfaceName,_association.interfaceIndex,observed]);
    }
  }
  NSMutableArray *preserved=[NSMutableArray array];BOOL missingIPv6Default=YES;
  for (NSDictionary *route in current) {
    BOOL recorded=NO;for (NSDictionary *target in _installedRoutes) if (KuroCoreAutoRouteEqual(route,target)) recorded=YES;
    if (!recorded) [preserved addObject:route];
    if ([route[@"family"]isEqual:@6] && [route[@"prefix"]isEqual:@0] && ([route[@"flags"]unsignedIntValue]&RTF_UP) && !([route[@"flags"]unsignedIntValue]&RTF_IFSCOPE)) missingIPv6Default=NO;
  }
  if (!KuroNetworkPreservedPaths(preserved,interfaces,_baselineDNS,_pathEndpoints,_physical,missingIPv6Default,error)) return NO;
  NSMutableDictionary *dns=[[_dnsBackend dnsRecords:error]mutableCopy];
  if (installed) {
    NSString *key=KuroDNSKey(_session); if (![dns[key]isEqual:KuroDNSValue()]) return Fail(error,@"owned DNS key changed or disappeared during active session");
    [dns removeObjectForKey:key];
    NSString *failure=nil; if (![[_dnsBackend valueForDNSKey:key error:&failure]isEqual:KuroDNSValue()] || failure) return Fail(error,@"owned DNS direct readback is uncertain");
  }
  if (![dns isEqual:_baselineDNS] && !(installed && KuroDNSOwnDerivedBaseline(_baselineDNS,dns,_session))) return Fail(error,[NSString stringWithFormat:@"DNS baseline changed; preserving existing resolvers and stopping this session; %@",KuroDNSBaselineDifference(_baselineDNS,dns,_session)]);
  BOOL physical=NO;
  for (NSDictionary *entry in interfaces) if ([entry[@"family"]isEqual:@0] && [entry[@"name"]isEqual:_physical] && [entry[@"linkType"]isEqual:@(IFT_ETHER)] &&
    ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_LOOPBACK|IFF_POINTOPOINT))==(IFF_UP|IFF_RUNNING)) {
      for (NSDictionary *route in _baselineRoutes) if ([route[@"prefix"]isEqual:@0] && [route[@"interfaceName"]isEqual:_physical] && [entry[@"index"]isEqual:route[@"interfaceIndex"]]) physical=YES;
    }
  return physical || Fail(error,@"physical egress disappeared during startup");
}
- (BOOL)readyChild:(pid_t)child session:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || ![_session isEqual:session] || _internalDNSReady || _installedRoutes || child<=0)
    return Fail(error,@"prepared same-session baseline is required for Core route readiness");
  uint64_t deadline=KuroMonotonicMilliseconds()+1500; NSString *failure=nil;
  do {
    KuroCoreInterface candidate={0}; failure=nil;
    if (_environment.observeChild(child,&candidate,&failure) && candidate.process.pid==child && KuroRouteAssociation(candidate) && KuroCoreAddressesReady(candidate,_environment.interfaces(&failure),&failure)) {
      _association=candidate;
      if (_environment.ownership(_association,error)!=KuroRouteOwnerLive)return NO;
      KuroRouteObservationState observation=[_routes observeReadinessForSession:session interface:_association ownership:_environment.ownership error:&failure];
      if(observation==KuroRouteObservationInvalid)return Fail(error,failure?:@"Core route observation is invalid");
      if(observation==KuroRouteObservationPending){failure=@"fixed Core auto-route readiness deadline expired with incomplete route plan";usleep(10000);continue;}
      _installedRoutes=KuroCoreAutoRouteCandidate(_association);
      if (![self confirmedRoutePlan:_installedRoutes error:error] || ![self unchangedBaseline:error] || !_environment.probeDNS(_association,error) || _environment.ownership(_association,error)!=KuroRouteOwnerLive)return NO;
      _internalDNSReady=YES;return YES;
    }
    usleep(10000);
  } while(KuroMonotonicMilliseconds()<deadline);
  return Fail(error,failure?:@"fixed dual-stack Core/utun readiness deadline expired");
}
- (BOOL)applyChild:(pid_t)child session:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || !_internalDNSReady || ![_session isEqual:session] || child!=_association.process.pid)
    return Fail(error,@"same DNS-ready held Core is required before resolver publication");
  if (![self confirmedRoutePlan:KuroCoreAutoRouteCandidate(_association) error:error] || ![self unchangedBaseline:error])return NO;
  // Core already owns its routes. Helper's only network write is its existing
  // exact temporary DNS key, admitted against current observed Core routes.
  if (![_dns installPreparedSession:session admission:^BOOL(NSString **failure) {
    NSString *readFailure=nil;id value=[self->_dnsBackend valueForDNSKey:KuroDNSKey(self->_session) error:&readFailure];
    if(readFailure)return Fail(failure,readFailure);
    return [self confirmedRoutePlan:KuroCoreAutoRouteCandidate(self->_association) error:failure] &&
      [self unchangedBaselineInstalled:[value isEqual:KuroDNSValue()] error:failure] && KuroCoreAddressesReady(self->_association,self->_environment.interfaces(failure),failure) && self->_environment.probeDNS(self->_association,failure);
  } error:error])return NO;
  return [self confirmSession:session error:error];
}
- (BOOL)confirmSession:(NSString *)session error:(NSString **)error {
  if (![self adapters:error] || !_prepared || ![_session isEqual:session] || !_internalDNSReady || !KuroRouteAssociation(_association))return Fail(error,@"active held session is required for network confirmation");
  if (![_installedRoutes isEqual:KuroCoreAutoRouteCandidate(_association)] || ![self confirmedRoutePlan:_installedRoutes error:error] || ![self unchangedBaselineInstalled:YES error:error] ||
    !KuroCoreAddressesReady(_association,_environment.interfaces(error),error) || !_environment.probeDNS(_association,error))return NO;
  return _environment.ownership(_association,error)==KuroRouteOwnerLive || Fail(error,@"held Core owner changed during active network confirmation");
}
- (NSDictionary *)stoppedEvidenceForSession:(NSString *)session error:(NSString **)error {
  if(!pthread_equal(_thread,pthread_self()) || !session || ![_stoppedEvidence[@"session"]isEqual:session] || !_networkOff || !_routes.routesOff || !_dns.dnsOff ||
    Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) || Exists([_directory stringByAppendingPathComponent:KuroDNSJournal])) {
    Fail(error,@"this session has no independent route and DNS cleanup confirmation");return nil;
  }
  return [_stoppedEvidence copy];
}
- (BOOL)recordedInterfaceAbsent:(NSDictionary *)record error:(NSString **)error {
  if(_session || ![record[@"format"]isEqual:@2] || ![record[@"interface"]isKindOfClass:NSDictionary.class])return YES;
  NSString *failure=nil;NSArray *interfaces=_environment.interfaces(&failure);
  if(failure || ![interfaces isKindOfClass:NSArray.class])return Fail(error,@"recorded utun absence readback unavailable; stage=interface-read");
  NSDictionary *association=record[@"interface"];
  for(id entry in interfaces) {
    if(![entry isKindOfClass:NSDictionary.class] || ![entry[@"name"]isKindOfClass:NSString.class] || !KuroNumber(entry[@"index"],1,UINT16_MAX))return Fail(error,@"recorded utun absence readback malformed; stage=interface-read");
    if([entry[@"name"]isEqual:association[@"interfaceName"]] || [entry[@"index"]isEqual:association[@"interfaceIndex"]])return Fail(error,@"recorded utun interface is not absent; stage=interface-present");
  }
  return YES;
}
- (BOOL)recoverSession:(NSString *)session error:(NSString **)error {
  // This short readback allowance is part of cleanup, not a new outer timeout.
  uint64_t readbackDeadline=KuroMonotonicMilliseconds()+200;
  NSDictionary *previous=_stoppedEvidence; _networkOff=NO; _recoveryObservation=nil;
  NSDictionary *observation=nil;
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
  // DNS recovery and read-only route absence are independent attempts. Core
  // teardown is the only route-removal mechanism; this helper never deletes.
  NSString *dnsFailure=nil,*routeFailure=nil;
  BOOL dnsRecovered=[_dns recoverDNS:&dnsFailure];
  BOOL routesRecovered=YES;
  NSDictionary *record=[_routes preparedRecord:&routeFailure];
  // This actor may recheck a successful retirement after later work/summary
  // failure. Memory is rejection/readback context, never a recreated receipt.
  NSString *authoritySession=session?:_recoveryOwner[@"session"];
  BOOL retiredContext=!record && !routeFailure && authoritySession && [_retiredRouteRecord[@"session"]isEqual:authoritySession];
  BOOL heldReplay=retiredContext && held && [previous[@"session"]isEqual:session];
  if(retiredContext)record=_retiredRouteRecord;
  KuroCoreInterface recoveryAssociation=_association;
  if(heldReplay && [record[@"interface"]isKindOfClass:NSDictionary.class])KuroRouteDecodeAssociation(record[@"interface"],&recoveryAssociation);
  if(routeFailure)routesRecovered=NO;
  if(routesRecovered && record && !_session && !heldReplay && (!_writerAbsent || !_recoveryOwner || !_writerAbsent(&routeFailure)))
    routesRecovered=Fail(&routeFailure,@"recorded route intent requires the session's explicit writer-exit validation before retirement");
  if(routesRecovered && record && _session && (![record[@"format"]isEqual:@2] || ![record[@"session"]isEqual:_session]))
    routesRecovered=Fail(&routeFailure,@"held Core cannot retire a different or legacy route intent");
  if(routesRecovered && [record[@"format"]isEqual:@1]) {
    NSDictionary *process=record[@"interface"];
    if(![record[@"session"]isEqual:_recoveryOwner[@"session"]] || ![process[@"pid"]isEqual:_recoveryOwner[@"pid"]] || ![process[@"startSeconds"]isEqual:_recoveryOwner[@"startSeconds"]] || ![process[@"startMicros"]isEqual:_recoveryOwner[@"startMicros"]])
      routesRecovered=Fail(&routeFailure,@"legacy route observation does not match the protected Core owner");
  }
  if(routesRecovered && [record[@"format"]isEqual:@2]) {
    NSDictionary *binding=heldReplay?record[@"binding"]:_binding;
    if(!_session && !heldReplay) {
      NSDictionary *owner=ReadJSON(_directory,[_directory stringByAppendingPathComponent:@"owner.json"],_owner,&routeFailure);
      binding=KuroNetworkOwnerBinding(owner);
      if(![owner isEqual:_recoveryOwner] || ![owner[@"session"]isEqual:record[@"session"]])binding=nil;
    }
    if(!binding || ![binding isEqual:record[@"binding"]] || (_session && ![_session isEqual:record[@"session"]]))routesRecovered=Fail(&routeFailure,@"route intent does not match the complete recorded Core owner binding; stage=owner-binding");
    if(routesRecovered) {
      BOOL baselineConfirmed=NO;
      for(;;) {
        // Only the already validated writer/Core/interface absence can wait.
        if(held && KuroRouteAssociation(recoveryAssociation) && _environment.ownership(recoveryAssociation,&routeFailure)!=KuroRouteOwnerExitedInterfaceGone) { routesRecovered=Fail(&routeFailure,@"Core/interface exit is not independently confirmed; stage=owner-exit");break; }
        if(_writerAbsent && !_writerAbsent(&routeFailure)){routesRecovered=NO;break;}
        if(![self recordedInterfaceAbsent:record error:&routeFailure]){routesRecovered=NO;break;}
        NSString *readFailure=nil;NSArray *raw=[_routeBackend routes:&readFailure],*current=KuroStableRoutes(raw);
        if(readFailure || !current){routesRecovered=Fail(&routeFailure,@"recorded route baseline readback unavailable; stage=route-read");break;}
        NSDictionary *association=[record[@"interface"]isKindOfClass:NSDictionary.class]?record[@"interface"]:KuroRouteAssociation(_association);
        if(!KuroCurrentOwnedRoutesAbsent(raw,association,&routeFailure)){routesRecovered=NO;break;}
        BOOL same=KuroNetworkSameRoutes(current,record[@"baselineRoutes"]);
        observation=@{@"kind":@"current-owned-absence",@"systemRouteBaselineRestored":@(same),@"routeDifference":same?@"":KuroRouteBaselineDifference(record[@"baselineRoutes"],current)};
        readFailure=nil;NSDictionary *dns=[_dnsBackend dnsRecords:&readFailure];
        if(readFailure || ![dns isKindOfClass:NSDictionary.class]){routesRecovered=Fail(&routeFailure,@"recorded DNS baseline readback unavailable; stage=dns-read");break;}
        if([dns isEqual:record[@"baselineDNS"]]) { if(baselineConfirmed)break;baselineConfirmed=YES;continue; }
        baselineConfirmed=NO;
        BOOL pending=dnsRecovered && KuroDNSOwnDerivedBaseline(record[@"baselineDNS"],dns,record[@"session"]);
        uint64_t now=KuroMonotonicMilliseconds();
        if(!pending || now>=readbackDeadline) {
          routesRecovered=Fail(&routeFailure,[NSString stringWithFormat:@"recorded pre-resume DNS baseline has not been restored; stage=%@; %@",pending?@"dns-derived-pending-timeout":@"dns-changed",KuroDNSBaselineDifference(record[@"baselineDNS"],dns,record[@"session"])]);break;
        }
        struct timespec pause={.tv_nsec=(long)(MIN((uint64_t)20,readbackDeadline-now)*1000000)};nanosleep(&pause,NULL);
      }
    }
  }
  if(routesRecovered && held && KuroRouteAssociation(recoveryAssociation) && _environment.ownership(recoveryAssociation,&routeFailure)!=KuroRouteOwnerExitedInterfaceGone)routesRecovered=Fail(&routeFailure,@"Core/interface exit is not independently confirmed; stage=owner-exit");
  if(routesRecovered && _writerAbsent && !_writerAbsent(&routeFailure))routesRecovered=NO;
  if(routesRecovered && ![self recordedInterfaceAbsent:record error:&routeFailure])routesRecovered=NO;
  if(routesRecovered && !dnsRecovered)routesRecovered=Fail(&routeFailure,@"DNS ownership retirement is not durable; stage=dns-retirement");
  if(routesRecovered && _recoveryOwner) {
    NSString *routeRead=nil,*dnsRead=nil;NSArray *raw=[_routeBackend routes:&routeRead];NSDictionary *dns=[_dnsBackend dnsRecords:&dnsRead];
    if(routeRead || !KuroStableRoutes(raw))routesRecovered=Fail(&routeFailure,@"current route readback unavailable; stage=route-read");
    else if(dnsRead || ![dns isKindOfClass:NSDictionary.class])routesRecovered=Fail(&routeFailure,@"current DNS readback unavailable; stage=dns-read");
    else {
      NSDictionary *association=[record[@"interface"]isKindOfClass:NSDictionary.class]?record[@"interface"]:nil;
      routesRecovered=KuroCurrentOwnedRoutesAbsent(raw,association,&routeFailure);
      for(id key in dns)if(![key isKindOfClass:NSString.class] || [key hasPrefix:KuroDNSPrefix]){routesRecovered=Fail(&routeFailure,@"current owned DNS UUID key is not absent");break;}
    }
  }
  if(routesRecovered){routesRecovered=[_routes recoverRecordedAbsence:&routeFailure];if(routesRecovered&&[record[@"format"]isEqual:@2])_retiredRouteRecord=record;}
  if(routesRecovered && _writerAbsent && !_writerAbsent(&routeFailure))routesRecovered=NO;
  if(!dnsRecovered || !routesRecovered) {
    NSMutableArray *failures=[NSMutableArray array];
    if(!dnsRecovered)[failures addObject:[@"DNS: "stringByAppendingString:dnsFailure?:@"recovery not confirmed"]];
    if(!routesRecovered)[failures addObject:[@"routes: "stringByAppendingString:routeFailure?:@"Core/interface exit or route absence not confirmed"]];
    return Fail(error,[failures componentsJoinedByString:@"; "]);
  }
  _networkOff=_routes.routesOff && _dns.dnsOff;
  if(_networkOff)_recoveryObservation=observation;
  if(_networkOff && held) {
    _stoppedEvidence=@{@"format":@1,@"session":session,@"routesOff":@YES,@"dnsOff":@YES,
      @"routeJournalSHA256":previous[@"routeJournalSHA256"]?:journals[KuroRouteJournal],@"dnsJournalSHA256":previous[@"dnsJournalSHA256"]?:journals[KuroDNSJournal]};
  }
  if (_networkOff) { _installedRoutes=nil; _internalDNSReady=NO; _session=nil; memset(&_association,0,sizeof(_association)); _prepared=NO; _physical=nil; _baselineRoutes=nil; _baselineDNS=nil; _binding=nil; }
  return _networkOff || Fail(error,@"network recovery lacks independent route/DNS absence proofs");
}
- (NSDictionary *)recoverRecordedOwner:(NSDictionary *)owner writerAbsent:(KuroSessionHook)writerAbsent error:(NSString **)error {
  if(_session || _writerAbsent || !writerAbsent || !KuroRestartRecord(owner,error) || !writerAbsent(error))return nil;
  NSDictionary *stored=ReadJSON(_directory,[_directory stringByAppendingPathComponent:@"owner.json"],_owner,error);
  if(![stored isEqual:owner]){Fail(error,@"recovery authority does not match the protected owner");return nil;}
  _recoveryOwner=[owner copy];_writerAbsent=[writerAbsent copy];
  @try { return [self recoverRecordedOwner:owner error:error]; }
  @finally { _writerAbsent=nil;_recoveryOwner=nil; }
}
// Fresh evidence describes actual current backend absence, not a held session's
// historical writes and not the mere disappearance of journal files.
- (NSDictionary *)recoverRecordedOwner:(NSDictionary *)owner error:(NSString **)error {
  if(!KuroRestartRecord(owner,error))return nil;
  NSString *session=owner[@"session"];
  if(!KuroDNSKey(session))return nil;
  NSString *ownerPath=[_directory stringByAppendingPathComponent:@"owner.json"];struct stat node={0};
  if(!lstat(ownerPath.fileSystemRepresentation,&node)) {
    NSDictionary *stored=ReadJSON(_directory,ownerPath,_owner,error);
    if(![stored isEqual:owner]){Fail(error,@"recovered network request does not match protected owner");return nil;}
  } else if(errno!=ENOENT || !SafeChain(_directory,_directory,_owner,YES,error)) {
    Fail(error,@"recorded owner absence is not observable");return nil;
  }
  // A durable stopped-proof replay may legitimately outlive owner unlink. With
  // no route receipt this is current absence only; it grants no retirement.
  if(Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) && !_writerAbsent){Fail(error,@"route receipt retirement requires explicit session writer-exit authority");return nil;}
  if(_writerAbsent && !_writerAbsent(error))return nil;
  BOOL scopedOwner=_recoveryOwner==nil;if(scopedOwner)_recoveryOwner=[owner copy];
  @try {
    if(![self recoverSession:nil error:error])return nil;
    if(!_networkOff || Exists([_directory stringByAppendingPathComponent:KuroRouteJournal]) || Exists([_directory stringByAppendingPathComponent:KuroDNSJournal])){Fail(error,@"current network receipts are not durably retired");return nil;}
    if(_writerAbsent && !_writerAbsent(error)){_networkOff=NO;_recoveryObservation=nil;return nil;}
    return @{@"format":@1,@"kind":@"current-owned-absence",@"session":session,@"routesOff":@YES,@"dnsOff":@YES};
  } @finally {if(scopedOwner)_recoveryOwner=nil;}
}

@end
