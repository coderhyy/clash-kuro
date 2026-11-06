// Internal bounded route primitive, not an RPC or an authorization gate.
// No default plan is installed here. The caller supplies an admitted fixed plan.
#import "tun-interface.m"
#include <arpa/inet.h>
#include <net/route.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <sys/sysctl.h>
#include <pthread.h>

static const NSUInteger KuroRouteLimit = 16, KuroRouteDumpLimit = 1024 * 1024;
static NSString *const KuroRouteJournal = @"network.json";
static NSUInteger KuroRouteAligned(NSUInteger length) { return length ? (length + 3) & ~(NSUInteger)3 : 4; }
static NSData *KuroRouteIP(id text, int family) {
  if (![text isKindOfClass:NSString.class] || [text containsString:@"%"] || (family != 4 && family != 6)) return nil;
  unsigned char bytes[16] = {0};
  if (inet_pton(family == 4 ? AF_INET : AF_INET6, [text UTF8String], bytes) != 1) return nil;
  char canonical[INET6_ADDRSTRLEN] = {0};
  if (!inet_ntop(family == 4 ? AF_INET : AF_INET6, bytes, canonical, sizeof(canonical)) || ![text isEqual:@(canonical)]) return nil;
  return [NSData dataWithBytes:bytes length:family == 4 ? 4 : 16];
}
static BOOL KuroRouteEntry(id entry) {
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
static int KuroRouteFlags(NSDictionary *entry) {
  return RTF_UP | RTF_STATIC | RTF_PROTO2 | ([entry[@"gateway"] isEqual:@"link"] ? 0 : RTF_GATEWAY) |
    ([entry[@"prefix"] intValue] == ([entry[@"family"] intValue] == 4 ? 32 : 128) ? RTF_HOST : 0);
}
// XNU in_addroute/in6_addroute add PRCLONING to non-host unicast routes.
// Keep request flags separate: scope, cloning, and all other differences remain material.
static int KuroRouteObservedFlags(NSDictionary *entry) {
  int flags=KuroRouteFlags(entry);
  return (flags & RTF_HOST) ? flags : flags | RTF_PRCLONING;
}
static BOOL KuroRouteKey(NSDictionary *left, NSDictionary *right) {
  return [left[@"family"] isEqual:right[@"family"]] && [left[@"destination"] isEqual:right[@"destination"]] && [left[@"prefix"] isEqual:right[@"prefix"]];
}
static BOOL KuroRouteEqual(NSDictionary *observed, NSDictionary *entry) {
  if (!Keys(observed, @[@"family",@"destination",@"prefix",@"gateway",@"interfaceIndex",@"interfaceName",@"flags"])) return NO;
  NSMutableDictionary *value = [observed mutableCopy]; [value removeObjectForKey:@"flags"];
  // DONE/IFREF are kernel bookkeeping; every other flag is material.
  return [value isEqual:entry] && ([observed[@"flags"] unsignedIntValue] & ~(RTF_DONE | RTF_IFREF)) == (unsigned int)KuroRouteObservedFlags(entry);
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

static void KuroRouteAppendAddress(NSMutableData *message, const void *address, NSUInteger length) {
  [message appendBytes:address length:length]; [message increaseLengthBy:KuroRouteAligned(length) - length];
}
static void KuroRouteAppendIP(NSMutableData *message, NSString *text, int family) {
  NSData *ip = KuroRouteIP(text, family);
  if (family == 4) { struct sockaddr_in address = {.sin_len=sizeof(address),.sin_family=AF_INET}; memcpy(&address.sin_addr, ip.bytes, 4); KuroRouteAppendAddress(message, &address, sizeof(address)); }
  else { struct sockaddr_in6 address = {.sin6_len=sizeof(address),.sin6_family=AF_INET6}; memcpy(&address.sin6_addr, ip.bytes, 16); KuroRouteAppendAddress(message, &address, sizeof(address)); }
}
// Pure wire encoder. DELETE includes the recorded gateway and interface, but the
// kernel has no public compare-and-swap token: real race behavior remains a gate.
static NSData *KuroRouteMessage(NSDictionary *entry, int operation, int sequence, NSString **error) {
  if (!KuroRouteEntry(entry) || (operation != RTM_ADD && operation != RTM_DELETE) || sequence <= 0) { Fail(error,@"route message is outside the closed operation schema"); return nil; }
  struct rt_msghdr header = {.rtm_version=RTM_VERSION,.rtm_type=(unsigned char)operation,.rtm_index=[entry[@"interfaceIndex"] unsignedShortValue],
    .rtm_flags=KuroRouteFlags(entry),.rtm_addrs=RTA_DST|RTA_GATEWAY|RTA_NETMASK|RTA_IFP,.rtm_pid=getpid(),.rtm_seq=sequence};
  NSMutableData *message = [NSMutableData dataWithBytes:&header length:sizeof(header)];
  int family = [entry[@"family"] intValue]; KuroRouteAppendIP(message, entry[@"destination"], family);
  struct sockaddr_dl link = {.sdl_len=sizeof(link),.sdl_family=AF_LINK,.sdl_index=[entry[@"interfaceIndex"] unsignedShortValue]};
  NSData *name = [entry[@"interfaceName"] dataUsingEncoding:NSASCIIStringEncoding];
  if (name.length > sizeof(link.sdl_data)) { Fail(error,@"interface name exceeds fixed link sockaddr"); return nil; }
  link.sdl_nlen = (unsigned char)name.length; memcpy(link.sdl_data,name.bytes,name.length);
  if ([entry[@"gateway"] isEqual:@"link"]) KuroRouteAppendAddress(message,&link,sizeof(link)); else KuroRouteAppendIP(message,entry[@"gateway"],family);
  unsigned char mask[16] = {0}; for (int bit=0;bit<[entry[@"prefix"] intValue];bit++) mask[bit/8] |= 0x80 >> (bit%8);
  char maskText[INET6_ADDRSTRLEN]; inet_ntop(family == 4 ? AF_INET : AF_INET6,mask,maskText,sizeof(maskText)); KuroRouteAppendIP(message,@(maskText),family);
  KuroRouteAppendAddress(message,&link,sizeof(link));
  ((struct rt_msghdr *)message.mutableBytes)->rtm_msglen=(unsigned short)message.length;
  return message;
}
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
- (BOOL)addRoute:(NSDictionary *)entry error:(NSString **)error;
- (BOOL)deleteRoute:(NSDictionary *)entry error:(NSString **)error;
@end
// Private transport seam: production uses these exact syscalls; fixtures use no socket.
typedef struct {
  int (*openSocket)(int,int,int); int (*control)(int,int,int);
  ssize_t (*sendPacket)(int,const void *,size_t,int); int (*waitPacket)(struct pollfd *,nfds_t,int);
  ssize_t (*receivePacket)(int,void *,size_t,int); int (*closeSocket)(int);
  int (*clock)(clockid_t,struct timespec *);
} KuroRouteExchangeIO;
static int KuroRouteControl(int fd,int operation,int value) { return fcntl(fd,operation,value); }
static NSDictionary *KuroRouteAckFields(struct rt_msghdr value) {
  return @{@"pid":@(value.rtm_pid),@"sequence":@(value.rtm_seq),@"version":@(value.rtm_version),@"type":@(value.rtm_type),@"length":@(value.rtm_msglen),@"errno":@(value.rtm_errno),@"flags":@((uint32_t)value.rtm_flags),@"interfaceIndex":@(value.rtm_index),@"addresses":@(value.rtm_addrs)};
}
static BOOL KuroRouteExchangeWithIO(NSDictionary *entry,NSData *request,int operation,int sequence,const KuroRouteExchangeIO *io,NSString **error) {
  struct timespec started={0},began={0},now={0};io->clock(CLOCK_MONOTONIC,&started);
  NSString *stage=@"socket",*reason=@"PF_ROUTE socket unavailable";int savedErrno=0,polled=0;short revents=0;
  ssize_t sent=-1,count=-1;NSUInteger packets=0,ignored=0;NSDictionary *matching=nil,*lastHeader=nil;NSString *shortPrefix=@"";BOOL ok=NO;
  int fd=io->openSocket(PF_ROUTE,SOCK_RAW,AF_UNSPEC);if(fd<0)savedErrno=errno;
  if(fd>=0)do {
    reason=@"route socket cannot be bounded";stage=@"fcntl-getfl";int flags=io->control(fd,F_GETFL,0);if(flags<0){savedErrno=errno;break;}
    stage=@"fcntl-nonblock";if(io->control(fd,F_SETFL,flags|O_NONBLOCK)){savedErrno=errno;break;}
    stage=@"fcntl-cloexec";if(io->control(fd,F_SETFD,FD_CLOEXEC)){savedErrno=errno;break;}
    reason=@"route request was not sent completely; inspect journal";stage=@"send";
    sent=io->sendPacket(fd,request.bytes,request.length,0);if(sent!=(ssize_t)request.length){if(sent<0)savedErrno=errno;break;}
    reason=@"route acknowledgement absent or rejected; ownership must be reconciled";io->clock(CLOCK_MONOTONIC,&began);
    for(packets=0;packets<256;packets++) {
      stage=@"deadline";io->clock(CLOCK_MONOTONIC,&now);long elapsed=(now.tv_sec-began.tv_sec)*1000+(now.tv_nsec-began.tv_nsec)/1000000;
      if(elapsed>=1000)break;
      stage=@"poll";struct pollfd ready={.fd=fd,.events=POLLIN};polled=io->waitPacket(&ready,1,(int)(1000-elapsed));revents=ready.revents;savedErrno=polled<0?errno:0;
      if(polled<0 && savedErrno==EINTR)continue;if(polled<=0 || (revents&(POLLERR|POLLNVAL)))break;
      stage=@"recv";unsigned char bytes[8192];count=io->receivePacket(fd,bytes,sizeof(bytes),MSG_DONTWAIT);savedErrno=count<0?errno:0;
      if(count<0 && (savedErrno==EAGAIN || savedErrno==EINTR))continue;
      if(count<(ssize_t)sizeof(struct rt_msghdr)){if(count>0)shortPrefix=Hex([NSData dataWithBytes:bytes length:MIN((NSUInteger)count,(NSUInteger)32)]);break;}
      struct rt_msghdr response;memcpy(&response,bytes,sizeof(response));lastHeader=KuroRouteAckFields(response);
      if(response.rtm_pid!=getpid() || response.rtm_seq!=sequence){ignored++;continue;}
      stage=@"matching-ack";matching=lastHeader;
      if(response.rtm_version!=RTM_VERSION || response.rtm_type!=operation || response.rtm_msglen!=count || response.rtm_errno)break;
      ok=YES;break;
    }
    if(packets==256)stage=@"packet-limit";
  }while(NO);
  // Capture errno before close and preserve only the closed request/header metadata.
  if(fd>=0)io->closeSocket(fd);if(ok)return YES;io->clock(CLOCK_MONOTONIC,&now);
  long elapsed=(now.tv_sec-started.tv_sec)*1000+(now.tv_nsec-started.tv_nsec)/1000000;
  NSDictionary *details=@{@"operation":@(operation),@"route":entry,@"sequence":@(sequence),@"stage":stage,@"syscallErrno":@(savedErrno),@"elapsedMs":@(elapsed),@"sent":@(sent),@"requestBytes":@(request.length),@"polled":@(polled),@"revents":@((unsigned short)revents),@"received":@(count),@"iterations":@(packets),@"ignoredHeaders":@(ignored),@"matchingAck":matching?:NSNull.null,@"lastHeader":lastHeader?:NSNull.null,@"shortHeaderPrefixHex":shortPrefix};
  NSData *encoded=JSONData(details);NSString *text=encoded.length<=2048?[[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding]:@"[bounded route diagnostic unavailable]";
  return Fail(error,[NSString stringWithFormat:@"%@; routeExchange=%@",reason,text]);
}
@interface KuroDarwinRouteStore : NSObject <KuroRouteStore> { int _sequence; }
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
- (BOOL)exchange:(NSDictionary *)entry operation:(int)operation error:(NSString **)error {
  if (geteuid()!=0 || _sequence==INT_MAX) return Fail(error,@"root route writer unavailable");
  NSData *request=KuroRouteMessage(entry,operation,++_sequence,error); if (!request) return NO;
  char currentName[IF_NAMESIZE]={0}; unsigned int index=[entry[@"interfaceIndex"]unsignedIntValue];
  if (!if_indextoname(index,currentName) || ![entry[@"interfaceName"]isEqual:@(currentName)] || if_nametoindex(currentName)!=index) return Fail(error,@"route target interface no longer matches the admitted association");
  const KuroRouteExchangeIO io={.openSocket=socket,.control=KuroRouteControl,.sendPacket=send,.waitPacket=poll,.receivePacket=recv,.closeSocket=close,.clock=clock_gettime};
  return KuroRouteExchangeWithIO(entry,request,operation,_sequence,&io,error);
}
- (BOOL)addRoute:(NSDictionary *)entry error:(NSString **)error {
  NSArray *before=[self routes:error]; if (!before) return NO;
  for (NSDictionary *route in before) if (KuroRouteKey(route,entry)) return Fail(error,@"existing route preserved; add refused");
  return [self exchange:entry operation:RTM_ADD error:error];
}
- (BOOL)deleteRoute:(NSDictionary *)entry error:(NSString **)error {
  NSArray *before=[self routes:error]; if (!before) return NO; NSUInteger matches=0;
  for (NSDictionary *route in before) if (KuroRouteKey(route,entry)) { if (!KuroRouteEqual(route,entry)) return Fail(error,@"route changed; compare-delete refused"); matches++; }
  if (matches!=1) return Fail(error,@"exact route comparison unavailable; deletion refused");
  return [self exchange:entry operation:RTM_DELETE error:error];
}
@end

static NSArray<NSDictionary *> *KuroInternalDNSRouteCandidate(KuroCoreInterface association);
static NSArray<NSDictionary *> *KuroSessionRouteCandidate(KuroCoreInterface association);

@interface KuroOwnedRoutes : NSObject {
  NSString *_directory; uid_t _owner; id<KuroRouteStore> _backend; pthread_t _thread; BOOL _routesOff; NSData *_hostPreparationReceipt;
}
@property(nonatomic,readonly) BOOL routesOff;
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroRouteStore>)backend;
- (BOOL)installForSession:(NSString *)session interface:(KuroCoreInterface)association routes:(NSArray<NSDictionary *> *)routes ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)continueSessionRoutesForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)recoverForInterface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)confirmInstalledSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error;
- (BOOL)recoverRecordedAbsence:(NSString **)error;
@end
@implementation KuroOwnedRoutes
- (instancetype)initWithDirectory:(NSString *)directory owner:(uid_t)owner backend:(id<KuroRouteStore>)backend {
  if ((self=[super init])) { _directory=[directory copy]; _owner=owner; _backend=backend; _thread=pthread_self(); } return self;
}
- (BOOL)routesOff { return _routesOff; }
- (BOOL)prepared:(NSString **)error {
  NSString *anchor=@"";
#ifdef KURO_TESTING
  anchor=_directory;
#endif
  return (_backend && pthread_equal(_thread,pthread_self()) && SafeChain(anchor,_directory,_owner,YES,error)) || Fail(error,@"route owner requires its protected directory and serial thread");
}
- (BOOL)syncDirectory:(NSString **)error {
  int fd=open(_directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); BOOL ok=fd>=0 && !fsync(fd); if (fd>=0) close(fd);
  return ok || Fail(error,@"route journal directory sync failed");
}
- (BOOL)persist:(NSDictionary *)record replacing:(NSData *)previous error:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal]; NSData *data=JSONData(record);
  if (!data || data.length>MessageLimit) return Fail(error,@"route journal exceeds bound");
  if (!previous) return WriteNew(path,data,0600,error) && [self syncDirectory:error];
  NSData *current=ReadProtected(_directory,path,_owner,error); if (![current isEqual:previous]) return Fail(error,@"route journal changed before receipt");
  NSString *temporary=[_directory stringByAppendingPathComponent:[@".network-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if (!WriteNew(temporary,data,0600,error)) return NO;
  // Root-owned directory and serial actor exclude unprivileged replacement.
  if (rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)) { unlink(temporary.fileSystemRepresentation); return Fail(error,@"route receipt publish failed"); }
  return [self syncDirectory:error];
}
- (NSData *)journalBytes:(NSString **)error {
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal]; struct stat metadata;
  if (lstat(path.fileSystemRepresentation,&metadata) || metadata.st_size<0 || metadata.st_size>(off_t)MessageLimit) { Fail(error,@"route journal unavailable or oversized"); return nil; }
  return ReadProtected(_directory,path,_owner,error);
}
- (NSDictionary *)recordForInterface:(KuroCoreInterface)association bytes:(NSData **)bytes error:(NSString **)error {
  NSData *data=[self journalBytes:error]; id record=data?KuroDecodeJSON(data,MessageLimit,error):nil;
  if (!Keys(record,@[@"format",@"kind",@"session",@"interface",@"routes",@"applied"])) { Fail(error,@"invalid route journal mapping"); return nil; }
  NSUUID *uuid=[record[@"session"] isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:record[@"session"]]:nil;
  if (!KuroNumber(record[@"format"],1,1) || ![record[@"kind"]isEqual:@"routes-v1"] || !uuid || ![uuid.UUIDString isEqual:record[@"session"]] ||
    ![record[@"interface"]isEqual:KuroRouteAssociation(association)] || ![self plan:record[@"routes"] interface:association error:error] || !KuroNumber(record[@"applied"],0,[record[@"routes"]count])) { Fail(error,@"route journal is incomplete, changed or not this owner"); return nil; }
  if (bytes) *bytes=data; return record;
}
- (BOOL)confirmInstalledSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  if (![self prepared:error] || !ownership || !KuroRouteAssociation(association)) return Fail(error,@"route readiness requires trusted current owner");
  NSData *bytes=nil; NSDictionary *record=[self recordForInterface:association bytes:&bytes error:error];
  if (!record || ![record[@"session"]isEqual:session] || [record[@"applied"]unsignedIntegerValue]!=[record[@"routes"]count] || ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"route readiness lacks complete durable receipts/live owner");
  NSArray *observed=[_backend routes:error]; if (!observed) return NO;
  for (NSDictionary *target in record[@"routes"]) { NSUInteger count=0;
    for (NSDictionary *route in observed) if (KuroRouteKey(route,target)) { if (!KuroRouteEqual(route,target)) return Fail(error,@"installed route changed before DNS activation"); count++; }
    if (count!=1) return Fail(error,@"installed route readback is absent/ambiguous");
  }
  if (ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"owner changed during readiness check");
  if (![[self journalBytes:error]isEqual:bytes]) return Fail(error,@"route receipt changed during readiness check");
  // A previous publish may have succeeded while its directory sync failed.
  return [self syncDirectory:error];
}
- (BOOL)plan:(NSArray *)routes interface:(KuroCoreInterface)association error:(NSString **)error {
  if (!KuroRouteAssociation(association) || ![routes isKindOfClass:NSArray.class] || !routes.count || routes.count>KuroRouteLimit) return Fail(error,@"route plan or interface association unavailable");
  NSMutableArray *seen=[NSMutableArray array];
  for (NSDictionary *route in routes) {
    if (!KuroRouteEntry(route) || ![route[@"interfaceIndex"] isEqual:@(association.interfaceIndex)] || ![route[@"interfaceName"] isEqual:@(association.interfaceName)]) return Fail(error,@"route plan escapes observed interface");
    for (NSDictionary *prior in seen) if (KuroRouteKey(prior,route)) return Fail(error,@"duplicate route plan key");
    [seen addObject:route];
  }
  return YES;
}
- (BOOL)installForSession:(NSString *)session interface:(KuroCoreInterface)association routes:(NSArray<NSDictionary *> *)routes ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  _routesOff=NO; _hostPreparationReceipt=nil; NSUUID *uuid=[session isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:session]:nil;
  if (![self prepared:error] || !uuid || ![uuid.UUIDString isEqual:session] || !ownership || ![self plan:routes interface:association error:error]) return Fail(error,@"route install requires canonical session, live owner and a closed plan");
  if (ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"live held Core/interface authority is required before route writes");
  // Freeze caller input before any adapter callback can mutate it.
  routes=KuroDecodeJSON([NSJSONSerialization dataWithJSONObject:routes options:NSJSONWritingSortedKeys error:NULL],MessageLimit,error); if (![self plan:routes interface:association error:error]) return NO;
  NSArray *before=[_backend routes:error]; if (!before) return NO;
  for (NSDictionary *route in before) for (NSDictionary *target in routes) if (KuroRouteKey(route,target)) return Fail(error,@"route plan conflicts with existing destination; nothing replaced");
  NSMutableDictionary *record=[@{@"format":@1,@"kind":@"routes-v1",@"session":session,@"interface":KuroRouteAssociation(association),@"routes":routes,@"applied":@0} mutableCopy];
  if (![self persist:record replacing:nil error:error]) return NO;
  NSData *previous=JSONData(record);
  for (NSDictionary *target in routes) {
    if (ownership(association,error)!=KuroRouteOwnerLive || ![_backend addRoute:target error:error]) return NO;
    NSArray *observed=[_backend routes:error]; if (!observed) return NO; NSUInteger matches=0;
    for (NSDictionary *route in observed) if (KuroRouteKey(route,target)) { if (!KuroRouteEqual(route,target)) return Fail(error,@"added route differs from admitted plan; journal retained"); matches++; }
    if (matches!=1 || ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"added route or live owner was not independently confirmed");
    record[@"applied"]=@([record[@"applied"] unsignedIntegerValue]+1);
    if (![self persist:record replacing:previous error:error]) return NO;
    previous=JSONData(record);
  }
  if ([routes isEqual:KuroInternalDNSRouteCandidate(association)]) _hostPreparationReceipt=previous;
  return YES;
}
- (BOOL)continueSessionRoutesForSession:(NSString *)session interface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  _routesOff=NO;
  if (![self prepared:error] || !ownership || !_hostPreparationReceipt || !KuroRouteAssociation(association)) return Fail(error,@"route continuation requires this actor's completed internal DNS preparation");
  NSData *previous=nil; NSDictionary *prior=[self recordForInterface:association bytes:&previous error:error];
  NSArray *hosts=KuroInternalDNSRouteCandidate(association),*combined=KuroSessionRouteCandidate(association);
  if (!prior || ![previous isEqual:_hostPreparationReceipt] || ![prior[@"session"]isEqual:session] || ![prior[@"routes"]isEqual:hosts] || ![prior[@"applied"]isEqual:@2]) return Fail(error,@"route continuation does not match the exact completed host prefix");
  if (![self confirmInstalledSession:session interface:association ownership:ownership error:error]) return NO;
  NSArray *observed=[_backend routes:error]; if (!observed) return NO;
  for (NSDictionary *host in hosts) { NSUInteger matches=0;
    for (NSDictionary *route in observed) if (KuroRouteKey(route,host)) { if (!KuroRouteEqual(route,host)) return Fail(error,@"internal DNS host changed before continuation"); matches++; }
    if (matches!=1) return Fail(error,@"internal DNS host is absent/ambiguous before continuation");
  }
  for (NSDictionary *route in observed) for (NSUInteger i=hosts.count;i<combined.count;i++) if (KuroRouteKey(route,combined[i])) return Fail(error,@"split route conflicts before continuation; host receipt retained");
  if (ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"held owner changed before route continuation");
  NSMutableDictionary *record=[prior mutableCopy]; record[@"routes"]=combined;
  // Consume same-actor authority before publishing. Any failure requires cleanup,
  // never resuming an append from a newly read journal or a replacement actor.
  _hostPreparationReceipt=nil;
  if (![self persist:record replacing:previous error:error]) return NO;
  previous=JSONData(record);
  for (NSUInteger i=hosts.count;i<combined.count;i++) {
    NSDictionary *target=combined[i];
    if (ownership(association,error)!=KuroRouteOwnerLive || ![_backend addRoute:target error:error]) return NO;
    NSArray *current=[_backend routes:error]; if (!current) return NO; NSUInteger matches=0;
    for (NSDictionary *route in current) if (KuroRouteKey(route,target)) { if (!KuroRouteEqual(route,target)) return Fail(error,@"continued route differs from admitted plan; journal retained"); matches++; }
    if (matches!=1 || ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"continued route or live owner was not independently confirmed");
    record[@"applied"]=@(i+1);
    if (![self persist:record replacing:previous error:error]) return NO;
    previous=JSONData(record);
  }
  return YES;
}
- (BOOL)recoverRecordedAbsence:(NSString **)error {
  _routesOff=NO; _hostPreparationReceipt=nil; if (![self prepared:error]) return NO;
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];
  NSArray *observed=[_backend routes:error]; if (!observed) return NO;
  if (!Exists(path)) {
    for (NSDictionary *route in observed) if ([route[@"flags"]unsignedIntValue]&RTF_PROTO2) return Fail(error,@"unrecorded marked route remains; no restart cleanup authority");
    if(![self syncDirectory:error])return NO;
    _routesOff=YES; return YES;
  }
  NSData *bytes=[self journalBytes:error]; NSDictionary *raw=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
  if (![raw isKindOfClass:NSDictionary.class]) return Fail(error,@"restart route receipt is not a mapping");
  NSDictionary *a=raw[@"interface"]; KuroCoreInterface association={0};
  if (!Keys(a,@[@"pid",@"startSeconds",@"startMicros",@"descriptor",@"controlID",@"controlUnit",@"socketHandle",@"pcbHandle",@"interfaceIndex",@"interfaceName"]) ||
    !KuroNumber(a[@"pid"],1,INT_MAX) || !KuroNumber(a[@"startSeconds"],1,INT64_MAX) || !KuroNumber(a[@"startMicros"],0,999999) ||
    !KuroNumber(a[@"descriptor"],0,INT_MAX) || !KuroNumber(a[@"controlID"],1,UINT32_MAX) || !KuroNumber(a[@"controlUnit"],1,INT_MAX) ||
    !KuroNumber(a[@"interfaceIndex"],1,UINT16_MAX) || !Match(a[@"socketHandle"],@"\\A[1-9][0-9]{0,19}\\z") || !Match(a[@"pcbHandle"],@"\\A[1-9][0-9]{0,19}\\z") ||
    !Match(a[@"interfaceName"],@"\\Autun[0-9]{1,9}\\z")) return Fail(error,@"restart route receipt lacks a valid closed association");
  association.process=(KuroCoreIdentity){[a[@"pid"]intValue],[a[@"startSeconds"]unsignedLongLongValue],[a[@"startMicros"]unsignedLongLongValue]};
  association.descriptor=[a[@"descriptor"]intValue]; association.controlID=[a[@"controlID"]unsignedIntValue]; association.controlUnit=[a[@"controlUnit"]unsignedIntValue];
  association.socketHandle=strtoull([a[@"socketHandle"]UTF8String],NULL,10); association.pcbHandle=strtoull([a[@"pcbHandle"]UTF8String],NULL,10);
  association.interfaceIndex=[a[@"interfaceIndex"]unsignedIntValue]; strlcpy(association.interfaceName,[a[@"interfaceName"]UTF8String],sizeof(association.interfaceName));
  NSDictionary *record=[self recordForInterface:association bytes:NULL error:error]; if (!record) return NO;
  for (NSDictionary *route in observed) for (NSDictionary *target in record[@"routes"]) if (KuroRouteKey(route,target)) return Fail(error,@"recorded route prefix remains after restart; preserving conflict and receipt");
  // No owner inference or route write: only already-absent recorded keys.
  NSArray *again=[_backend routes:error]; if (!again) return NO;
  for (NSDictionary *route in again) for (NSDictionary *target in record[@"routes"]) if (KuroRouteKey(route,target)) return Fail(error,@"route appeared during restart absence check");
  if (![[self journalBytes:error]isEqual:bytes] || unlink(path.fileSystemRepresentation) || ![self syncDirectory:error]) return Fail(error,@"restart route absence receipt could not be retired");
  _routesOff=YES; return YES;
}
- (BOOL)recoverForInterface:(KuroCoreInterface)association ownership:(KuroRouteOwnership)ownership error:(NSString **)error {
  _routesOff=NO; _hostPreparationReceipt=nil; if (![self prepared:error] || !ownership || !KuroRouteAssociation(association)) return Fail(error,@"current authoritative interface context is required for route recovery");
  NSString *path=[_directory stringByAppendingPathComponent:KuroRouteJournal];
  NSArray *observed=[_backend routes:error]; if (!observed) return NO;
  if (!Exists(path)) {
    for (NSDictionary *route in observed) if ([route[@"interfaceIndex"] isEqual:@(association.interfaceIndex)] && ([route[@"flags"] unsignedIntValue]&RTF_PROTO2)) return Fail(error,@"unrecorded marked routes preserved; ownership unknown");
    if (ownership(association,error)==KuroRouteOwnerUnknown) return Fail(error,@"route absence lacks current owner evidence");
    if(![self syncDirectory:error])return NO;
    _routesOff=YES; return YES;
  }
  NSData *bytes=nil; NSDictionary *record=[self recordForInterface:association bytes:&bytes error:error]; if (!record) return NO;
  NSArray *plan=record[@"routes"]; NSUInteger applied=[record[@"applied"]unsignedIntegerValue];
  KuroRouteOwnerState state=ownership(association,error); if (state==KuroRouteOwnerUnknown) return Fail(error,@"restarted/uncertain owner cannot authorize route cleanup");
  // Validate the whole plan before deleting anything. Prepared-but-unreceipted
  // present routes may be a concurrent add or interrupted acknowledgement.
  for (NSUInteger i=0;i<plan.count;i++) { NSUInteger matches=0; for (NSDictionary *route in observed) if (KuroRouteKey(route,plan[i]) &&
    (++matches>1 || state!=KuroRouteOwnerLive || i>=applied || !KuroRouteEqual(route,plan[i]))) return Fail(error,@"route changed, unreceipted or interface reused; preserving routes and journal"); }
  for (NSUInteger i=plan.count;i>0;i--) {
    NSDictionary *target=plan[i-1];
    if (state!=KuroRouteOwnerLive) break;
    NSArray *current=[_backend routes:error]; if (!current) return NO; NSUInteger count=0;
    for (NSDictionary *route in current) if (KuroRouteKey(route,target)) { if (!KuroRouteEqual(route,target)) return Fail(error,@"route changed during recovery"); count++; }
    if (!count) continue;
    if (count!=1 || i>applied) return Fail(error,@"route appeared without a unique durable receipt during recovery");
    if (ownership(association,error)!=KuroRouteOwnerLive) return Fail(error,@"owner changed before route deletion");
    if (![_backend deleteRoute:target error:error]) return NO;
  }
  NSArray *after=[_backend routes:error]; if (!after) return NO;
  for (NSDictionary *route in after) for (NSDictionary *target in plan) if (KuroRouteKey(route,target)) return Fail(error,@"route deletion/absence not independently confirmed");
  if (ownership(association,error)==KuroRouteOwnerUnknown) return Fail(error,@"owner evidence lost before final route absence receipt");
  NSData *unchanged=[self journalBytes:error];
  if (![unchanged isEqual:bytes] || unlink(path.fileSystemRepresentation) || ![self syncDirectory:error]) return Fail(error,@"route journal removal was not durable");
  _routesOff=YES; return YES;
}
@end
// Offline candidate only: more-specific LAN/split routes remain in place, but
// default-only LAN, scoped routing, VPNs, egress and DNS must pass caller preflight.
static NSArray<NSDictionary *> *__attribute__((unused)) KuroSplitRouteCandidate(KuroCoreInterface association) {
  if (!KuroRouteAssociation(association)) return nil;
  NSMutableArray *routes=[NSMutableArray array];
  for (NSArray *pair in @[@[@4,@"0.0.0.0"],@[@4,@"128.0.0.0"],@[@6,@"::"],@[@6,@"8000::"]])
    [routes addObject:@{@"family":pair[0],@"destination":pair[1],@"prefix":@1,@"gateway":@"link",@"interfaceIndex":@(association.interfaceIndex),@"interfaceName":@(association.interfaceName)}];
  return routes;
}

// The only preparatory writes are these two internal DNS hosts, never broad traffic.
static NSArray<NSDictionary *> *__attribute__((unused)) KuroInternalDNSRouteCandidate(KuroCoreInterface association) {
  if (!KuroRouteAssociation(association)) return nil;
  return @[
    @{@"family":@4,@"destination":@"198.18.0.2",@"prefix":@32,@"gateway":@"link",@"interfaceIndex":@(association.interfaceIndex),@"interfaceName":@(association.interfaceName)},
    @{@"family":@6,@"destination":@"fdfe:dcba:9876::2",@"prefix":@128,@"gateway":@"link",@"interfaceIndex":@(association.interfaceIndex),@"interfaceName":@(association.interfaceName)}
  ];
}
static NSArray<NSDictionary *> *__attribute__((unused)) KuroSessionRouteCandidate(KuroCoreInterface association) {
  NSArray *hosts=KuroInternalDNSRouteCandidate(association);
  return hosts?[hosts arrayByAddingObjectsFromArray:KuroSplitRouteCandidate(association)]:nil;
}
