// Read-only, sampled association with an already held, unreaped direct child.
// Not exclusive ownership, a lifetime lease, or authority for restart cleanup.
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <limits.h>
#include <errno.h>

typedef struct {
  pid_t pid;
  uint64_t startSeconds, startMicros;
} KuroCoreIdentity;
typedef struct {
  KuroCoreIdentity process;
  int descriptor; // A descriptor in the child, never usable in the helper.
  uint32_t controlID, controlUnit;
  uint64_t socketHandle, pcbHandle; // Opaque observation tokens, not pointers.
  unsigned int interfaceIndex;
  char interfaceName[IF_NAMESIZE];
} KuroCoreInterface;

typedef struct {
  int (*pidInfo)(int, int, uint64_t, void *, int);
  int (*pidFDInfo)(int, int, int, void *, int);
  unsigned int (*nameToIndex)(const char *);
  char *(*indexToName)(unsigned int, char *);
} KuroInterfaceReader;
// Canonical identity of the unique utun only. Other fully read sockets may
// connect/disconnect, be replaced or change counters without changing this FD.
typedef struct {
  int32_t descriptor;
  uint32_t descriptorType;
  uint64_t socketHandle, pcbHandle;
  int family, type, protocol, kind;
  uint32_t connectionState, controlID, controlUnit;
  char controlName[MAX_KCTL_NAME];
} KuroInterfaceFD;
static const NSUInteger KuroInterfaceFDLimit = 4096;

static BOOL KuroInterfaceIdentity(KuroCoreIdentity identity, const KuroInterfaceReader *reader, NSString **error) {
  struct proc_bsdinfo process = {0};
  int count = reader->pidInfo(identity.pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process));
  return (count == sizeof(process) && process.pbi_pid == (uint32_t)identity.pid && process.pbi_ppid == (uint32_t)getpid() &&
    process.pbi_start_tvsec == identity.startSeconds && process.pbi_start_tvusec == identity.startMicros &&
    (process.pbi_status == SRUN || process.pbi_status == SSLEEP || process.pbi_status == SSTOP))
    || Fail(error, @"Core direct-child start identity is unavailable, changed, or not live");
}
static int KuroInterfaceFDOrder(const void *left, const void *right) {
  int a = ((const struct proc_fdinfo *)left)->proc_fd, b = ((const struct proc_fdinfo *)right)->proc_fd;
  return (a > b) - (a < b);
}
static NSData *KuroInterfaceSnapshot(KuroCoreIdentity identity, const KuroInterfaceReader *reader, KuroCoreInterface *candidate, int targetDescriptor, unsigned int sample, NSString **error) {
  // Known-target mode performs real socket reads, not another background FD census.
  struct proc_fdinfo target={targetDescriptor,PROX_FDTYPE_SOCKET};
  struct proc_fdinfo *descriptors=&target;NSUInteger count=1;NSMutableData *listing=nil;
  if(targetDescriptor<0) {
    const NSUInteger entry = sizeof(struct proc_fdinfo), maximum = KuroInterfaceFDLimit * entry;
    int requested = reader->pidInfo(identity.pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (requested <= 0 || (NSUInteger)requested > maximum || requested % entry) { Fail(error, @"Core FD enumeration size is unavailable or exceeds the diagnostic bound"); return nil; }
    // Spare capacity detects a full/truncated result; no retry that hides churn.
    NSUInteger capacity = MIN((NSUInteger)requested + 16 * entry, maximum + entry);
    listing = [NSMutableData dataWithLength:capacity];
    int returned = reader->pidInfo(identity.pid, PROC_PIDLISTFDS, 0, listing.mutableBytes, (int)capacity);
    if (returned <= 0 || (NSUInteger)returned >= capacity || (NSUInteger)returned > maximum || returned % entry) { Fail(error, @"Core FD enumeration is incomplete or changed beyond its bound"); return nil; }
    count = (NSUInteger)returned / entry;
    descriptors = listing.mutableBytes;
    qsort(descriptors, count, entry, KuroInterfaceFDOrder);
  }
  KuroInterfaceFD matched = {0};
  NSUInteger matches = 0;
  for (NSUInteger index = 0; index < count; index++) {
    struct proc_fdinfo descriptor = descriptors[index];
    if (descriptor.proc_fd < 0 || !descriptor.proc_fdtype || (index && descriptor.proc_fd == descriptors[index - 1].proc_fd)) { Fail(error, @"Core FD enumeration contains invalid or duplicate descriptors"); return nil; }
    KuroInterfaceFD current = {0};
    KuroInterfaceFD *entryInfo = &current;
    entryInfo->descriptor = descriptor.proc_fd; entryInfo->descriptorType = descriptor.proc_fdtype;
    if (descriptor.proc_fdtype != PROX_FDTYPE_SOCKET) continue;
    struct socket_fdinfo socket = {0};
    errno=0;
    int socketBytes=reader->pidFDInfo(identity.pid,descriptor.proc_fd,PROC_PIDFDSOCKETINFO,&socket,sizeof(socket)),savedErrno=errno;
    if(socketBytes!=sizeof(socket)) {
      Fail(error,[NSString stringWithFormat:@"Core socket read is denied, incomplete, or raced with a closed FD; socketRead sample=%u fd=%d ordinal=%lu listed=%lu returned=%d expected=%lu errno=%d mode=%@",sample,descriptor.proc_fd,(unsigned long)index+1,(unsigned long)count,socketBytes,(unsigned long)sizeof(socket),savedErrno,targetDescriptor<0?@"discovery":@"target"]);return nil;
    }
    struct socket_info *info = &socket.psi;
    entryInfo->socketHandle = info->soi_so; entryInfo->pcbHandle = info->soi_pcb;
    entryInfo->family = info->soi_family; entryInfo->type = info->soi_type;
    entryInfo->protocol = info->soi_protocol; entryInfo->kind = info->soi_kind;
    entryInfo->connectionState = info->soi_state & (SOI_S_NOFDREF | SOI_S_ISCONNECTED | SOI_S_ISCONNECTING | SOI_S_ISDISCONNECTING | SOI_S_ISDISCONNECTED | SOI_S_DRAINING);
    if (info->soi_family == AF_SYSTEM && info->soi_protocol == SYSPROTO_CONTROL && info->soi_kind != SOCKINFO_KERN_CTL) { Fail(error, @"Core kernel-control socket details are unavailable"); return nil; }
    if (info->soi_kind != SOCKINFO_KERN_CTL) continue;
    struct kern_ctl_info *control = &info->soi_proto.pri_kern_ctl;
    size_t nameLength = strnlen(control->kcsi_name, sizeof(control->kcsi_name));
    if (nameLength == sizeof(control->kcsi_name)) { Fail(error, @"Core kernel-control name is not terminated"); return nil; }
    memcpy(entryInfo->controlName, control->kcsi_name, nameLength);
    entryInfo->controlID = control->kcsi_id; entryInfo->controlUnit = control->kcsi_unit;
    if (strcmp(control->kcsi_name, UTUN_CONTROL_NAME)) continue;
    if (info->soi_family != AF_SYSTEM || info->soi_type != SOCK_DGRAM || info->soi_protocol != SYSPROTO_CONTROL ||
      entryInfo->connectionState != SOI_S_ISCONNECTED || !control->kcsi_id || !control->kcsi_unit || control->kcsi_unit > INT_MAX ||
      !info->soi_so || !info->soi_pcb) { Fail(error, @"Core utun socket has no complete connected control identity"); return nil; }
    if (++matches != 1) { Fail(error, @"Core has multiple utun socket descriptors; association is ambiguous"); return nil; }
    matched = current;
    candidate->process = identity; candidate->descriptor = descriptor.proc_fd;
    candidate->controlID = control->kcsi_id; candidate->controlUnit = control->kcsi_unit;
    candidate->socketHandle = info->soi_so; candidate->pcbHandle = info->soi_pcb;
    int length = snprintf(candidate->interfaceName, sizeof(candidate->interfaceName), "utun%u", control->kcsi_unit - 1);
    if (length <= 0 || (NSUInteger)length >= sizeof(candidate->interfaceName)) { Fail(error, @"Core utun unit does not have a bounded interface name"); return nil; }
  }
  if (matches != 1) { Fail(error, @"Core has no observable connected utun kernel-control socket"); return nil; }
  return [NSData dataWithBytes:&matched length:sizeof(matched)];
}
static BOOL KuroInterfaceIndex(KuroCoreInterface *candidate, const KuroInterfaceReader *reader, NSString **error) {
  unsigned int index = reader->nameToIndex(candidate->interfaceName);
  char reverse[IF_NAMESIZE] = {0};
  if (!index || !reader->indexToName(index, reverse) || !memchr(reverse, '\0', sizeof(reverse)) ||
    strcmp(reverse, candidate->interfaceName) || reader->nameToIndex(candidate->interfaceName) != index) return Fail(error, @"Core utun interface index is unavailable or changed during lookup");
  candidate->interfaceIndex = index;
  return YES;
}
static BOOL KuroInterfaceSameTarget(KuroCoreInterface a,KuroCoreInterface b) {
  return a.process.pid==b.process.pid && a.process.startSeconds==b.process.startSeconds && a.process.startMicros==b.process.startMicros &&
    a.descriptor==b.descriptor && a.controlID==b.controlID && a.controlUnit==b.controlUnit && a.socketHandle==b.socketHandle && a.pcbHandle==b.pcbHandle &&
    a.interfaceIndex==b.interfaceIndex && !strcmp(a.interfaceName,b.interfaceName);
}
static BOOL KuroObserveCoreInterfaceExpectedWithReader(KuroCoreIdentity identity,const KuroCoreInterface *expected,KuroCoreInterface *result,const KuroInterfaceReader *reader,NSString **error) {
  if (result) memset(result, 0, sizeof(*result));
  if (!result || identity.pid <= 0 || !identity.startSeconds || identity.startMicros >= 1000000 || !reader ||
    !reader->pidInfo || !reader->pidFDInfo || !reader->nameToIndex || !reader->indexToName) return Fail(error, @"held Core child identity and complete read-only observer are required");
  if(expected) {
    char name[IF_NAMESIZE]={0};snprintf(name,sizeof(name),"utun%u",expected->controlUnit-1);
    if(expected->process.pid!=identity.pid || expected->process.startSeconds!=identity.startSeconds || expected->process.startMicros!=identity.startMicros ||
      expected->descriptor<0 || !expected->controlID || !expected->controlUnit || expected->controlUnit>INT_MAX || !expected->socketHandle || !expected->pcbHandle || !expected->interfaceIndex ||
      !memchr(expected->interfaceName,'\0',sizeof(expected->interfaceName)) || strcmp(name,expected->interfaceName))return Fail(error,@"saved Core utun association is invalid");
  }
  if (!KuroInterfaceIdentity(identity, reader, error)) return NO;
  KuroCoreInterface first = {0}, second = {0};
  NSData *before = KuroInterfaceSnapshot(identity, reader, &first, expected?expected->descriptor:-1, 1, error);
  if (!before || !KuroInterfaceIndex(&first, reader, error)) return NO;
  NSData *after = KuroInterfaceSnapshot(identity, reader, &second, expected?expected->descriptor:-1, 2, error);
  if (!after || !KuroInterfaceIndex(&second, reader, error)) return NO;
  if (![before isEqual:after]) return Fail(error, @"Core utun FD/control-socket identity changed during verification");
  if (first.interfaceIndex != second.interfaceIndex) return Fail(error, @"Core utun interface index changed during verification");
  if(expected && !KuroInterfaceSameTarget(second,*expected))return Fail(error,@"Core utun target differs from the saved association");
  if (!KuroInterfaceIdentity(identity, reader, error)) return NO;
  *result = second;
  return YES;
}
static BOOL KuroObserveCoreInterfaceWithReader(KuroCoreIdentity identity,KuroCoreInterface *result,const KuroInterfaceReader *reader,NSString **error) {
  return KuroObserveCoreInterfaceExpectedWithReader(identity,NULL,result,reader,error);
}
// Caller must hold the unreaped child in this session; a persisted PID/start
// record alone is not authority. This samples association, never pins an utun.
static BOOL __attribute__((unused)) KuroObserveCoreInterface(KuroCoreIdentity identity, KuroCoreInterface *result, NSString **error) {
  const KuroInterfaceReader reader = {proc_pidinfo, proc_pidfdinfo, if_nametoindex, if_indextoname};
  return KuroObserveCoreInterfaceWithReader(identity, result, &reader, error);
}

// Subsequent checks confirm the saved target, not process-wide utun exclusivity.
static BOOL __attribute__((unused)) KuroObserveExpectedCoreInterface(KuroCoreInterface expected,KuroCoreInterface *result,NSString **error) {
  const KuroInterfaceReader reader={proc_pidinfo,proc_pidfdinfo,if_nametoindex,if_indextoname};
  return KuroObserveCoreInterfaceExpectedWithReader(expected.process,&expected,result,&reader,error);
}

// Only called by a future real start/recovery. Tests inject this snapshot.
#include <ifaddrs.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <arpa/inet.h>
static NSArray<NSDictionary *> *KuroNetworkInterfaces(NSString **error) {
  struct ifaddrs *head=NULL;
  if (getifaddrs(&head)) { Fail(error,@"interface address snapshot unavailable"); return nil; }
  NSMutableArray *result=[NSMutableArray array]; BOOL ok=YES;
  for (struct ifaddrs *entry=head;entry;entry=entry->ifa_next) {
    if (!entry->ifa_name || !entry->ifa_addr) continue;
    int family=entry->ifa_addr->sa_family; if (family!=AF_LINK && family!=AF_INET && family!=AF_INET6) continue;
    unsigned int index=if_nametoindex(entry->ifa_name); char name[IF_NAMESIZE]={0};
    if (!index || !if_indextoname(index,name) || strcmp(name,entry->ifa_name) || result.count>=2048) { ok=NO; break; }
    NSMutableDictionary *value=[@{@"name":@(name),@"index":@(index),@"flags":@(entry->ifa_flags),@"family":@(family==AF_INET?4:family==AF_INET6?6:0)}mutableCopy];
    if (family==AF_LINK) { value[@"linkType"]=@(((struct sockaddr_dl *)entry->ifa_addr)->sdl_type); }
    else {
      char text[INET6_ADDRSTRLEN]={0}; const void *address=family==AF_INET?(const void *)&((struct sockaddr_in *)entry->ifa_addr)->sin_addr:(const void *)&((struct sockaddr_in6 *)entry->ifa_addr)->sin6_addr;
      if (!inet_ntop(family,address,text,sizeof(text)) || !entry->ifa_netmask || entry->ifa_netmask->sa_family!=family) { ok=NO; break; }
      value[@"address"]=@(text);
      const unsigned char *mask=family==AF_INET?(const unsigned char *)&((struct sockaddr_in *)entry->ifa_netmask)->sin_addr:(const unsigned char *)&((struct sockaddr_in6 *)entry->ifa_netmask)->sin6_addr;
      NSUInteger prefix=0; BOOL zero=NO;
      for (NSUInteger bit=0;bit<(family==AF_INET?32:128);bit++) { BOOL one=(mask[bit/8]&(0x80>>(bit%8)))!=0; if (zero && one) ok=NO; if (one) prefix++; else zero=YES; }
      value[@"prefix"]=@(prefix);
    }
    [result addObject:value];
  }
  freeifaddrs(head); if (!ok) { Fail(error,@"interface address snapshot is ambiguous or oversized"); return nil; }
  return result;
}
static BOOL KuroCoreAddressesReady(KuroCoreInterface association, NSArray<NSDictionary *> *interfaces, NSString **error) {
  if (![interfaces isKindOfClass:NSArray.class]) return Fail(error,@"utun address snapshot unavailable");
  NSUInteger v4=0,v6=0;
  for (NSDictionary *entry in interfaces) if ([entry[@"name"]isEqual:@(association.interfaceName)] || [entry[@"index"]isEqual:@(association.interfaceIndex)]) {
    if (![entry[@"name"]isEqual:@(association.interfaceName)] || ![entry[@"index"]isEqual:@(association.interfaceIndex)] ||
      ([entry[@"flags"]unsignedIntValue]&(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT))!=(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT)) return Fail(error,@"observed utun index/flags changed or is not running point-to-point");
    if ([entry[@"family"]isEqual:@4]) { if (![entry[@"address"]isEqual:@"198.18.0.1"] || ![entry[@"prefix"]isEqual:@30]) return Fail(error,@"utun IPv4 address differs from fixed template"); v4++; }
    if ([entry[@"family"]isEqual:@6]) {
      struct in6_addr ip={0}; if (inet_pton(AF_INET6,[entry[@"address"]UTF8String],&ip)!=1) return Fail(error,@"utun IPv6 address is invalid");
      if (IN6_IS_ADDR_LINKLOCAL(&ip)) continue;
      if (![entry[@"address"]isEqual:@"fdfe:dcba:9876::1"] || ![entry[@"prefix"]isEqual:@126]) return Fail(error,@"utun IPv6 address differs from fixed template"); v6++;
    }
  }
  return (v4==1 && v6==1) || Fail(error,@"fixed dual-stack utun addresses are not uniquely ready");
}
