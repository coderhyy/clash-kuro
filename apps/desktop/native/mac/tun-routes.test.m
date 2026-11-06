#import "tun-routes.m"
static KuroCoreInterface RouteFixtureInterface(void) {
  KuroCoreInterface value={.process={.pid=456,.startSeconds=123,.startMicros=456},.descriptor=9,.controlID=1,.controlUnit=8,.socketHandle=55,.pcbHandle=66,.interfaceIndex=7};
  strlcpy(value.interfaceName,"utun7",sizeof(value.interfaceName)); return value;
}
static NSDictionary *ObservedRoute(NSDictionary *entry) {
  NSMutableDictionary *value=[entry mutableCopy]; // Model the fixed Darwin callback, independently of the expected-readback function.
  unsigned int flags=KuroRouteFlags(entry);
  if (!(flags&(RTF_HOST|RTF_CLONING|RTF_MULTICAST))) flags|=RTF_PRCLONING;
  value[@"flags"]=@(flags); return value;
}
@interface KuroFakeRouteStore : NSObject <KuroRouteStore>
@property(nonatomic) NSMutableArray<NSDictionary *> *entries;
@property(nonatomic) NSString *directory;
@property(nonatomic) NSUInteger additions, deletions, snapshots;
@property(nonatomic) BOOL addThenFail, lieDelete, failRead;
@property(nonatomic,copy) void (^onSnapshot)(KuroFakeRouteStore *);
@end
@implementation KuroFakeRouteStore
- (instancetype)init { if ((self=[super init])) _entries=[NSMutableArray array]; return self; }
- (NSArray *)routes:(NSString **)error {
  _snapshots++; if (_onSnapshot) _onSnapshot(self);
  if (_failRead) { Fail(error,@"injected unknown snapshot"); return nil; }
  return [_entries copy];
}
- (BOOL)addRoute:(NSDictionary *)entry error:(NSString **)error {
  NSDictionary *record=ReadJSON(_directory,[_directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),NULL);
  CHECK([record[@"routes"]containsObject:entry] && [record[@"applied"]unsignedIntegerValue]==_additions);
  for (NSDictionary *route in _entries) if (KuroRouteKey(route,entry)) return Fail(error,@"existing fixture route");
  _additions++; [_entries addObject:ObservedRoute(entry)];
  return !_addThenFail || Fail(error,@"simulated lost add acknowledgement");
}
- (BOOL)deleteRoute:(NSDictionary *)entry error:(NSString **)error {
  NSUInteger index=[_entries indexOfObject:ObservedRoute(entry)]; if (index==NSNotFound) return Fail(error,@"fixture exact-delete failed");
  _deletions++; if (!_lieDelete) [_entries removeObjectAtIndex:index]; return YES;
}
@end
@interface KuroRouteDurabilityFixture : KuroOwnedRoutes
@property(nonatomic) BOOL refuseSync;
@property(nonatomic) NSUInteger syncCalls;
@end
@implementation KuroRouteDurabilityFixture
- (BOOL)syncDirectory:(NSString **)error {self.syncCalls++;return self.refuseSync?Fail(error,@"injected route sync failure"):[super syncDirectory:error];}
@end
// Fixed, sanitized Darwin RTM_GET wire shapes shared with admission tests.
// Masks retain radix bytes; local host scope belongs to en0 even via lo0.
static NSArray<NSData *> *DarwinRouteFixturePackets(void) {
  NSArray *encoded=@[
    @"lAAFBAEAAAABCQAAJwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAADAAAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAgAAfwAAAAAAAAAAAAAAEAIAAH8AAAEAAAAAAAAAAAX/////AAAAEAIAAH8AAAEAAAAAAAAAAA==",
    @"mAAFBAIAAAABCQAAJwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANwFAAAAAAAAR4rpagAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAgAAwKgBAAAAAAAAAAAAFBICAAYAAAAAAAAAAAAAAAAAAAAH////////ABACAADAqAEKAAAAAAAAAAA=",
    @"wAAFBAIAAAABAAEBJwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcHgAAAAAAAP6AAAIAAAAAAAAAAAAAAAAAAAAAHB4AAAAAAAD+gAACAAAAAAAAAAAAAAABAAAAABD///////////////////8cHgAAAAAAAP6AAAIAAAAAAAAAAAAAAAEAAAAA",
    @"qAAFBAEAAAAFBCABIwAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAcHgAAAAAAAP6AAAIAAAAAAAAAAAAAEjQAAAAAFBICAAYABgACAAAAAAAAAAAAAAAcHgAAAAAAAP6AAAIAAAAAAAAAAAAAEjQAAAAA"
  ];
  NSMutableArray *packets=[NSMutableArray array];
  for(NSString *wire in encoded)[packets addObject:[[NSData alloc]initWithBase64EncodedString:wire options:0]];
  return packets;
}
// Pure decoding only; no sysctl/PF_ROUTE or interface lookup.
static void RouteKernelDumpTests(void) {
  NSArray *fixtures=DarwinRouteFixturePackets();
  NSArray *destinations=@[@"127.0.0.0",@"192.168.1.0",@"fe80::%2",@"fe80::1234%2"],*prefixes=@[@8,@24,@64,@128];
  NSString *error=nil;
  for(NSUInteger i=0;i<fixtures.count;i++) {
    NSArray *decoded=KuroRouteDecodeDump(fixtures[i],&error);CHECK(decoded.count==1);
    CHECK([decoded[0][@"destination"]isEqual:destinations[i]] && [decoded[0][@"prefix"]isEqual:prefixes[i]]);
  }
  NSMutableData *local=[fixtures[3]mutableCopy];
  struct rt_msghdr *header=local.mutableBytes;CHECK(header->rtm_index==1);
  CHECK([KuroRouteDecodeDump(local,&error).firstObject[@"interfaceIndex"]isEqual:@1]);
  header->rtm_flags&=~RTF_LOCAL;CHECK(!KuroRouteDecodeDump(local,&error));header->rtm_flags|=RTF_LOCAL;
  header->rtm_flags&=~RTF_HOST;CHECK(!KuroRouteDecodeDump(local,&error));header->rtm_flags|=RTF_HOST;
  struct sockaddr_in6 *destination=(void *)((char *)local.mutableBytes+sizeof(*header));
  destination->sin6_scope_id=3;CHECK(!KuroRouteDecodeDump(local,&error));
  destination->sin6_scope_id=2;CHECK(KuroRouteDecodeDump(local,&error).count==1);
  destination->sin6_scope_id=0;destination->sin6_addr.s6_addr[2]=destination->sin6_addr.s6_addr[3]=0;
  CHECK(KuroRouteDecodeDump(local,&error).count==1); // Unscoped local keeps route scope.
  NSMutableData *mask=[fixtures[1]mutableCopy];
  unsigned char *bytes=mask.mutableBytes;bytes[128+4]=0xfe; // ff fe ff 00 is non-contiguous.
  CHECK(!KuroRouteDecodeDump(mask,&error));
  CHECK(!KuroRouteDecodeDump([mask subdataWithRange:NSMakeRange(0,mask.length-1)],&error));
  puts("Darwin route parser: four sanitized recorded wire shapes + nonlocal/nonhost/conflicting-zone/noncontiguous/truncation rejects PASS");
}

static void RouteTests(void) {
  RouteKernelDumpTests();
  CHECK(geteuid()!=0);
  KuroCoreInterface association=RouteFixtureInterface();
  NSArray *plan=KuroSplitRouteCandidate(association); CHECK(plan.count==4);
  __block NSString *error=nil;NSString *session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  // Pure packets, including both address families. No PF_ROUTE/sysctl operation.
  NSMutableData *dump=[NSMutableData data];
  for (NSDictionary *entry in plan) {
    CHECK(KuroRouteEntry(entry)); NSMutableData *packet=[KuroRouteMessage(entry,RTM_ADD,1,&error) mutableCopy];
    CHECK(packet && ((struct rt_msghdr *)packet.mutableBytes)->rtm_index==7);
    struct rt_msghdr *header=packet.mutableBytes;
    CHECK(!(header->rtm_flags&(RTF_PRCLONING|RTF_IFSCOPE)));
    header->rtm_type=RTM_GET; header->rtm_flags|=RTF_PRCLONING; [dump appendData:packet];
  }
  NSArray *decoded=KuroRouteDecodeDump(dump,&error); CHECK(decoded.count==4);
  for (NSUInteger i=0;i<plan.count;i++) CHECK(KuroRouteEqual(decoded[i],plan[i]));
  // The fixed IPv4/IPv6 non-host callbacks add exactly PRCLONING. Missing it,
  // unexpected scope/cloning/ownership bits, and host-route PRCLONING are material.
  for (NSDictionary *entry in plan) {
    NSMutableDictionary *readback=[ObservedRoute(entry)mutableCopy];
    CHECK(KuroRouteEqual(readback,entry));
    unsigned int expected=[readback[@"flags"]unsignedIntValue];
    readback[@"flags"]=@(expected|RTF_DONE|RTF_IFREF); CHECK(KuroRouteEqual(readback,entry));
    readback[@"flags"]=@(expected&~RTF_PRCLONING); CHECK(!KuroRouteEqual(readback,entry));
    for (NSNumber *flag in @[@(RTF_IFSCOPE),@(RTF_CLONING),@(RTF_HOST),@(RTF_MULTICAST),@(RTF_GATEWAY),@(RTF_REJECT),@(RTF_BLACKHOLE),@(RTF_WASCLONED),@(RTF_DYNAMIC)]) {
      readback[@"flags"]=@(expected|flag.unsignedIntValue); CHECK(!KuroRouteEqual(readback,entry));
    }
    for (NSNumber *flag in @[@(RTF_UP),@(RTF_STATIC),@(RTF_PROTO2)]) {
      readback[@"flags"]=@(expected&~flag.unsignedIntValue); CHECK(!KuroRouteEqual(readback,entry));
    }
    NSMutableDictionary *host=[entry mutableCopy];host[@"prefix"]=[entry[@"family"]isEqual:@4]?@32:@128;
    CHECK(KuroRouteEntry(host));readback=[ObservedRoute(host)mutableCopy];
    CHECK(KuroRouteEqual(readback,host)&&!([readback[@"flags"]unsignedIntValue]&RTF_PRCLONING));
    readback[@"flags"]=@([readback[@"flags"]unsignedIntValue]|RTF_PRCLONING);CHECK(!KuroRouteEqual(readback,host));
  }
  NSMutableData *bad=[dump mutableCopy]; ((struct rt_msghdr *)bad.mutableBytes)->rtm_msglen=1;
  CHECK(!KuroRouteDecodeDump(bad,&error)); CHECK(!KuroRouteDecodeDump([dump subdataWithRange:NSMakeRange(0,dump.length-1)],&error));
  // Corrupted gateway index must never compare as our link gateway.
  bad=[KuroRouteMessage(plan[0],RTM_ADD,1,&error) mutableCopy]; ((struct rt_msghdr *)bad.mutableBytes)->rtm_type=RTM_GET;
  struct sockaddr_dl *gateway=(void *)((char *)bad.mutableBytes+sizeof(struct rt_msghdr)+sizeof(struct sockaddr_in)); gateway->sdl_index=8;
  CHECK(!KuroRouteEqual(KuroRouteDecodeDump(bad,&error).firstObject,plan[0]));
  // Non-contiguous masks and scoped IPv6 addresses are conservatively rejected.
  bad=[KuroRouteMessage(plan[0],RTM_ADD,1,&error) mutableCopy]; ((struct rt_msghdr *)bad.mutableBytes)->rtm_type=RTM_GET;
  struct sockaddr_in *mask=(void *)((char *)bad.mutableBytes+sizeof(struct rt_msghdr)+sizeof(struct sockaddr_in)+KuroRouteAligned(sizeof(struct sockaddr_dl)));
  ((unsigned char *)&mask->sin_addr)[1]=1; CHECK(!KuroRouteDecodeDump(bad,&error));
  bad=[KuroRouteMessage(plan[2],RTM_ADD,1,&error) mutableCopy]; ((struct rt_msghdr *)bad.mutableBytes)->rtm_type=RTM_GET;
  ((struct sockaddr_in6 *)((char *)bad.mutableBytes+sizeof(struct rt_msghdr)))->sin6_scope_id=7;
  CHECK(!KuroRouteDecodeDump(bad,&error));
  // A scoped link-local gateway is baseline metadata, never an admitted write.
  NSMutableDictionary *scoped=[plan[2]mutableCopy]; scoped[@"gateway"]=@"2001:db8::1";
  bad=[KuroRouteMessage(scoped,RTM_ADD,1,&error)mutableCopy]; ((struct rt_msghdr *)bad.mutableBytes)->rtm_type=RTM_GET;
  struct sockaddr_in6 *v6gateway=(void *)((char *)bad.mutableBytes+sizeof(struct rt_msghdr)+sizeof(struct sockaddr_in6));
  inet_pton(AF_INET6,"fe80::1",&v6gateway->sin6_addr); v6gateway->sin6_scope_id=7;
  NSDictionary *observedScoped=KuroRouteDecodeDump(bad,&error).firstObject; CHECK([observedScoped[@"gateway"]isEqual:@"fe80::1%7"]);
  CHECK(!KuroRouteEqual(observedScoped,plan[2])); v6gateway->sin6_scope_id=8; CHECK(!KuroRouteDecodeDump(bad,&error));
  v6gateway->sin6_scope_id=0; v6gateway->sin6_addr.s6_addr[3]=7; CHECK([KuroRouteDecodeDump(bad,&error).firstObject[@"gateway"]isEqual:@"fe80::1%7"]);
  NSMutableDictionary *invalid=[plan[0] mutableCopy]; invalid[@"prefix"]=@0; CHECK(!KuroRouteEntry(invalid));
  invalid=[plan[0] mutableCopy]; invalid[@"destination"]=@"1.0.0.0"; CHECK(!KuroRouteEntry(invalid));
  invalid=[plan[0] mutableCopy]; invalid[@"interfaceIndex"]=@YES; CHECK(!KuroRouteEntry(invalid));
  invalid=[plan[0] mutableCopy]; invalid[@"command"]=@"route"; CHECK(!KuroRouteMessage(invalid,RTM_ADD,1,&error));
  char temporary[]="/tmp/kuro-route-owner-XXXXXX"; CHECK(mkdtemp(temporary)); char canonical[PATH_MAX]; CHECK(realpath(temporary,canonical)); NSString *base=@(canonical);
  __block KuroRouteOwnerState owner=KuroRouteOwnerLive;
  KuroRouteOwnership ownership=^KuroRouteOwnerState(KuroCoreInterface expected, NSString **failure) { (void)failure; CHECK([KuroRouteAssociation(expected)isEqual:KuroRouteAssociation(association)]); return owner; };
  for (NSUInteger scenario=0;scenario<12;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"run%lu",(unsigned long)scenario]]; FixtureDirectory(directory);
    NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];
    KuroFakeRouteStore *backend=[KuroFakeRouteStore new]; backend.directory=directory;
    NSDictionary *lan=@{@"family":@4,@"destination":@"192.168.1.0",@"prefix":@24,@"gateway":@"link",@"interfaceIndex":@2,@"interfaceName":@"en0",@"flags":@(RTF_UP)};
    [backend.entries addObject:lan];
    KuroOwnedRoutes *routes=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:backend]; owner=KuroRouteOwnerLive;
    if (scenario==0) {
      CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);
      CHECK([routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);
      CHECK(![routes confirmInstalledSession:@"11112233-4455-6677-8899-AABBCCDDEEFF" interface:association ownership:ownership error:&error]);
      CHECK([ReadJSON(directory,journal,geteuid(),NULL)[@"applied"]isEqual:@4]);
      CHECK([routes recoverForInterface:association ownership:ownership error:&error] && routes.routesOff && backend.deletions==4 && backend.entries.count==1 && [backend.entries.firstObject isEqual:lan] && !Exists(journal));
    } else if (scenario==1) {
      [backend.entries addObject:ObservedRoute(plan[0])];
      CHECK(![routes installForSession:session interface:association routes:plan ownership:ownership error:&error] && !Exists(journal) && !backend.additions && !backend.deletions);
    } else if (scenario==2 || scenario==3) {
      backend.addThenFail=YES;
      CHECK(![routes installForSession:session interface:association routes:plan ownership:ownership error:&error] && Exists(journal));
      CHECK(![routes recoverForInterface:association ownership:ownership error:&error] && !backend.deletions && Exists(journal));
      if (scenario==3) {
        [backend.entries removeLastObject]; owner=KuroRouteOwnerExitedInterfaceGone;
        CHECK([routes recoverForInterface:association ownership:ownership error:&error] && routes.routesOff && !backend.deletions);
      }
    } else if (scenario==4 || scenario==5 || scenario==6) {
      CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);
      if (scenario==4) { NSMutableDictionary *foreign=[backend.entries[1]mutableCopy]; foreign[@"gateway"]=@"198.18.0.1"; backend.entries[1]=foreign; }
      if (scenario==5) owner=KuroRouteOwnerUnknown;
      if (scenario==6) owner=KuroRouteOwnerExitedInterfaceGone;
      CHECK(![routes recoverForInterface:association ownership:ownership error:&error] && Exists(journal) && !backend.deletions && !routes.routesOff);
    } else if (scenario==7) {
      CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]); backend.lieDelete=YES;
      CHECK(![routes recoverForInterface:association ownership:ownership error:&error] && Exists(journal) && !routes.routesOff);
      backend.lieDelete=NO; CHECK([routes recoverForInterface:association ownership:ownership error:&error] && routes.routesOff);
    } else if (scenario==8) {
      Put(journal,Bytes(@"[]"),0600); CHECK(![routes recoverForInterface:association ownership:ownership error:&error] && !backend.deletions && Exists(journal));
    } else if (scenario==9) {
      CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);
      KuroCoreInterface changed=association; changed.socketHandle++;
      CHECK(![routes recoverForInterface:changed ownership:ownership error:&error] && !backend.deletions && Exists(journal));
    } else if (scenario==10) {
      CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);
      [backend.entries removeObjectsInRange:NSMakeRange(1,backend.entries.count-1)]; owner=KuroRouteOwnerExitedInterfaceGone;
      CHECK([routes recoverForInterface:association ownership:ownership error:&error] && !backend.deletions && routes.routesOff);
    } else {
      // Previously absent/unreceipted entry appears between preflight and deletion.
      backend.addThenFail=YES; CHECK(![routes installForSession:session interface:association routes:plan ownership:ownership error:&error]); [backend.entries removeLastObject];
      __block NSUInteger reads=0;
      backend.onSnapshot=^(KuroFakeRouteStore *store) { if (++reads==2) [store.entries addObject:ObservedRoute(plan[3])]; };
      CHECK(![routes recoverForInterface:association ownership:ownership error:&error] && !backend.deletions && Exists(journal));
    }
  }
  for(NSUInteger scenario=0;scenario<2;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"durable%lu",(unsigned long)scenario]];FixtureDirectory(directory);
    KuroFakeRouteStore *backend=[KuroFakeRouteStore new];backend.directory=directory;
    KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:backend];owner=KuroRouteOwnerLive;
    CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);[backend.entries removeAllObjects];owner=KuroRouteOwnerExitedInterfaceGone;routes.refuseSync=YES;
    BOOL (^recover)(void)=^BOOL{return scenario==0?[routes recoverRecordedAbsence:&error]:[routes recoverForInterface:association ownership:ownership error:&error];};
    CHECK(!recover()&&!routes.routesOff&&!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));NSUInteger calls=routes.syncCalls;
    CHECK(!recover()&&!routes.routesOff&&routes.syncCalls==calls+1);routes.refuseSync=NO;CHECK(recover()&&routes.routesOff&&!backend.deletions);
  }
  puts("native route durability: 2 absence-only retirement/retry paths require successful directory sync, no route deletion");
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native kernel flags: both IPv4/IPv6 /1 readbacks require PRCLONING, host routes do not; scope/material flag negatives preserved");
  puts("native routes: bounded wire fixtures and 12 ownership/recovery scenarios passed; no PF_ROUTE/sysctl/network operation executed");
}
