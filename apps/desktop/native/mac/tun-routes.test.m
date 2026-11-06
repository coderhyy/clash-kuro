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
@property(nonatomic,copy) void (^onAdd)(KuroFakeRouteStore *,NSDictionary *);
@end
@implementation KuroFakeRouteStore
- (instancetype)init { if ((self=[super init])) _entries=[NSMutableArray array]; return self; }
- (NSArray *)routes:(NSString **)error {
  _snapshots++; if (_onSnapshot) _onSnapshot(self);
  if (_failRead) { Fail(error,@"injected unknown snapshot"); return nil; }
  return [_entries copy];
}
- (BOOL)addRoute:(NSDictionary *)entry error:(NSString **)error {
  if (_onAdd) _onAdd(self,entry);
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
@property(nonatomic) NSUInteger syncCalls, failSyncAt;
@property(nonatomic) BOOL refuseContinuationPublish;
@property(nonatomic) NSDictionary *lastSyncedRecord;
@end
@implementation KuroRouteDurabilityFixture
- (BOOL)syncDirectory:(NSString **)error {
  self.syncCalls++;
  if(self.refuseSync || (self.failSyncAt && self.syncCalls==self.failSyncAt))return Fail(error,@"injected route sync failure");
  if(![super syncDirectory:error])return NO;
  self.lastSyncedRecord=[self recordForInterface:RouteFixtureInterface() bytes:NULL error:NULL];return YES;
}
- (BOOL)persist:(NSDictionary *)record replacing:(NSData *)previous error:(NSString **)error {
  if(self.refuseContinuationPublish && previous && [record[@"routes"]count]==6 && [record[@"applied"]isEqual:@2])return Fail(error,@"injected continuation publish refusal");
  return [super persist:record replacing:previous error:error];
}
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


static void RoutePreparationTests(void) {
  CHECK(geteuid()!=0);KuroCoreInterface association=RouteFixtureInterface();
  NSArray *hosts=KuroInternalDNSRouteCandidate(association),*combined=KuroSessionRouteCandidate(association);
  CHECK(hosts.count==2 && combined.count==6 && [[combined subarrayWithRange:NSMakeRange(0,2)]isEqual:hosts]);
  CHECK([hosts[0][@"destination"]isEqual:@"198.18.0.2"] && [hosts[0][@"prefix"]isEqual:@32]);
  CHECK([hosts[1][@"destination"]isEqual:@"fdfe:dcba:9876::2"] && [hosts[1][@"prefix"]isEqual:@128]);
  for(NSDictionary *host in hosts)CHECK(KuroRouteEntry(host) && (KuroRouteFlags(host)&RTF_HOST) && !(KuroRouteObservedFlags(host)&RTF_PRCLONING));
  KuroCoreInterface invalid=association;invalid.interfaceIndex=0;CHECK(!KuroInternalDNSRouteCandidate(invalid)&&!KuroSessionRouteCandidate(invalid));
  char temporary[]="/tmp/kuro-route-preparation-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical);
  NSString *session=@"00112233-4455-6677-8899-AABBCCDDEEFF";__block KuroRouteOwnerState owner=KuroRouteOwnerLive;
  KuroRouteOwnership ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)failure;CHECK([KuroRouteAssociation(expected)isEqual:KuroRouteAssociation(association)]);return owner;};
  for(NSUInteger scenario=0;scenario<20;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]];FixtureDirectory(directory);
    NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal],*error=nil;
    KuroFakeRouteStore *backend=[KuroFakeRouteStore new];backend.directory=directory;
    KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:backend];owner=KuroRouteOwnerLive;
    NSArray *initial=hosts;if(scenario==2)initial=KuroSplitRouteCandidate(association);if(scenario==3)initial=@[hosts[1],hosts[0]];
    CHECK([routes installForSession:session interface:association routes:initial ownership:ownership error:&error]);
    CHECK(backend.additions==initial.count && [ReadJSON(directory,journal,geteuid(),NULL)[@"applied"]isEqual:@(initial.count)]);
    NSData *before=[NSData dataWithContentsOfFile:journal];NSUInteger synced=routes.syncCalls;
    if(scenario==0) {
      __weak KuroRouteDurabilityFixture *weakRoutes=routes;
      backend.onAdd=^(KuroFakeRouteStore *store,NSDictionary *target){(void)target;NSDictionary *durable=weakRoutes.lastSyncedRecord;CHECK([durable[@"routes"]isEqual:combined] && [durable[@"applied"]unsignedIntegerValue]==store.additions);};
      CHECK([routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]);
      CHECK(backend.additions==6 && routes.syncCalls==synced+6); // host confirm + merged publish + four receipts.
      CHECK([routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);
      CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error] && backend.additions==6);
      CHECK([routes recoverForInterface:association ownership:ownership error:&error]&&routes.routesOff&&backend.deletions==6&&!Exists(journal));continue;
    }
    if(scenario==1)routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:backend]; // No restart adoption.
    if(scenario==4){NSMutableDictionary *record=[ReadJSON(directory,journal,geteuid(),NULL)mutableCopy];record[@"session"]=@"11112233-4455-6677-8899-AABBCCDDEEFF";Put(journal,JSONData(record),0600);}
    if(scenario==5){NSMutableDictionary *foreign=[backend.entries[0]mutableCopy];foreign[@"gateway"]=@"198.18.0.1";backend.entries[0]=foreign;}
    if(scenario==6)[backend.entries addObject:backend.entries[0]];
    if(scenario==7)[backend.entries removeObjectAtIndex:0];
    if(scenario==8)[backend.entries addObject:ObservedRoute(combined[2])];
    if(scenario==9)owner=KuroRouteOwnerUnknown;
    if(scenario==10)owner=KuroRouteOwnerExitedInterfaceGone;
    if(scenario==11)backend.failRead=YES;
    if(scenario==12)routes.refuseContinuationPublish=YES;
    if(scenario==13)routes.failSyncAt=synced+2; // confirm sync then merged publish actual rename/sync failure.
    if(scenario==14)backend.addThenFail=YES;
    if(scenario==15)backend.onSnapshot=^(KuroFakeRouteStore *store){if(store.additions==3){NSMutableDictionary *foreign=[store.entries.lastObject mutableCopy];foreign[@"gateway"]=@"198.18.0.1";store.entries[store.entries.count-1]=foreign;}};
    if(scenario==16)routes.failSyncAt=synced+6; // Actual final applied=6 publication fails its directory sync.
    if(scenario==17)routes.refuseSync=YES; // Even existing complete host receipt must re-sync before continuation.
    if(scenario==18)backend.onSnapshot=^(KuroFakeRouteStore *store){if(store.snapshots==5)[store.entries removeObjectAtIndex:0];};
    if(scenario==19)backend.onSnapshot=^(KuroFakeRouteStore *store){if(store.additions==3)owner=KuroRouteOwnerUnknown;};
    CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]);
    CHECK(!backend.deletions && Exists(journal));
    if(scenario<=13 || scenario==17 || scenario==18)CHECK(backend.additions==initial.count);
    if(scenario==12){CHECK([[NSData dataWithContentsOfFile:journal]isEqual:before]);routes.refuseContinuationPublish=NO;CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]);}
    if(scenario==13){NSDictionary *record=ReadJSON(directory,journal,geteuid(),NULL);CHECK([record[@"routes"]isEqual:combined]&&[record[@"applied"]isEqual:@2]);routes.failSyncAt=0;CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]);CHECK([routes recoverForInterface:association ownership:ownership error:&error]&&routes.routesOff&&backend.deletions==2);}
    if(scenario==14 || scenario==15 || scenario==19){CHECK(backend.additions==3);CHECK(![routes recoverForInterface:association ownership:ownership error:&error]&&!backend.deletions&&Exists(journal));backend.onSnapshot=nil;[backend.entries removeAllObjects];owner=KuroRouteOwnerExitedInterfaceGone;CHECK([routes recoverForInterface:association ownership:ownership error:&error]&&routes.routesOff&&!backend.deletions);}
    if(scenario==16){CHECK(backend.additions==6&&[ReadJSON(directory,journal,geteuid(),NULL)[@"applied"]isEqual:@6]);routes.refuseSync=YES;NSUInteger calls=routes.syncCalls;CHECK(![routes confirmInstalledSession:session interface:association ownership:ownership error:&error]&&routes.syncCalls==calls+1);CHECK(![routes confirmInstalledSession:session interface:association ownership:ownership error:&error]&&routes.syncCalls==calls+2);routes.refuseSync=NO;CHECK([routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]&&backend.additions==6);}
  }
  // Preparation failures cannot mint same-actor continuation authority, even if a later sync confirms the file.
  for(NSUInteger scenario=0;scenario<4;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"hostFailure%lu",(unsigned long)scenario]];FixtureDirectory(directory);NSString *error=nil,*journal=[directory stringByAppendingPathComponent:KuroRouteJournal];
    KuroFakeRouteStore *backend=[KuroFakeRouteStore new];backend.directory=directory;
    KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:backend];owner=KuroRouteOwnerLive;
    if(scenario==0)backend.addThenFail=YES;
    if(scenario==1)backend.onAdd=^(KuroFakeRouteStore *store,NSDictionary *entry){(void)entry;if(store.additions==1)store.addThenFail=YES;};
    if(scenario==2)routes.failSyncAt=3;
    if(scenario==3)routes.failSyncAt=1;
    CHECK(![routes installForSession:session interface:association routes:hosts ownership:ownership error:&error] && Exists(journal));
    CHECK(backend.additions==(scenario==0?1:scenario==3?0:2));
    CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]&&!backend.deletions);
    if(scenario==2){routes.refuseSync=YES;CHECK(![routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);CHECK(![routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);routes.refuseSync=NO;CHECK([routes confirmInstalledSession:session interface:association ownership:ownership error:&error]);CHECK(![routes continueSessionRoutesForSession:session interface:association ownership:ownership error:&error]);}
    if(scenario<2)CHECK(![routes recoverForInterface:association ownership:ownership error:&error]&&!backend.deletions);
    [backend.entries removeAllObjects];owner=KuroRouteOwnerExitedInterfaceGone;routes.refuseSync=NO;CHECK([routes recoverForInterface:association ownership:ownership error:&error]&&routes.routesOff&&!backend.deletions);
  }
  // Old four-entry and new host-only/combined v1 receipts all retain absence-only restart semantics.
  for(NSArray *plan in @[KuroSplitRouteCandidate(association),hosts,combined]) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"restart%lu",(unsigned long)plan.count]];FixtureDirectory(directory);NSString *error=nil,*journal=[directory stringByAppendingPathComponent:KuroRouteJournal];
    KuroFakeRouteStore *backend=[KuroFakeRouteStore new];backend.directory=directory;KuroOwnedRoutes *routes=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:backend];owner=KuroRouteOwnerLive;
    CHECK([routes installForSession:session interface:association routes:plan ownership:ownership error:&error]);
    KuroOwnedRoutes *restarted=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:backend];
    CHECK(![restarted recoverRecordedAbsence:&error] && !backend.deletions && Exists(journal));
    owner=KuroRouteOwnerExitedInterfaceGone;CHECK(![routes recoverForInterface:association ownership:ownership error:&error]&&!backend.deletions&&Exists(journal));
    [backend.entries removeAllObjects];CHECK([restarted recoverRecordedAbsence:&error]&&restarted.routesOff&&!backend.deletions&&!Exists(journal));
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native staged routes: 20 continuation + 4 host-preparation failure cases + old4/host2/combined6 absence-only recovery PASS; no network operations");
}

static void RouteTests(void) {
  RoutePreparationTests();
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
