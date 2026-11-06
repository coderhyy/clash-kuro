#import "tun-routes.m"
static KuroCoreInterface RouteFixtureInterface(void) {
  KuroCoreInterface value={.process={.pid=456,.startSeconds=123,.startMicros=456},.descriptor=9,.controlID=1,.controlUnit=8,.socketHandle=55,.pcbHandle=66,.interfaceIndex=7};
  strlcpy(value.interfaceName,"utun7",sizeof(value.interfaceName));return value;
}
// Models the upstream Darwin route request + fixed XNU non-host callback.
static NSDictionary *ObservedRoute(NSDictionary *entry) {
  NSMutableDictionary *route=[entry mutableCopy];route[@"flags"]=@(RTF_UP|RTF_STATIC|RTF_GATEWAY|RTF_PRCLONING);return route;
}
@interface KuroFakeRouteStore:NSObject <KuroRouteStore>
@property(nonatomic) NSMutableArray<NSDictionary *> *entries;
@property(nonatomic) NSString *directory;
@property(nonatomic) NSUInteger snapshots;
@property(nonatomic) BOOL failRead;
@property(nonatomic,copy) void (^onSnapshot)(KuroFakeRouteStore *);
@end
@implementation KuroFakeRouteStore
- (instancetype)init{if((self=[super init]))_entries=[NSMutableArray array];return self;}
- (NSArray *)routes:(NSString **)error {
  self.snapshots++;if(self.onSnapshot)self.onSnapshot(self);
  if(self.failRead){Fail(error,@"injected unknown snapshot");return nil;}return [self.entries copy];
}
@end
@interface KuroRouteDurabilityFixture:KuroOwnedRoutes
@property(nonatomic) BOOL refuseSync;
@property(nonatomic) NSUInteger syncCalls,failSyncAt;
@end
@implementation KuroRouteDurabilityFixture
- (BOOL)syncDirectory:(NSString **)error {
  self.syncCalls++;if(self.refuseSync||(self.failSyncAt&&self.syncCalls==self.failSyncAt))return Fail(error,@"injected observation sync failure");return [super syncDirectory:error];
}
@end
static NSDictionary *RouteFixtureBinding(void) {
  KuroCoreInterface value=RouteFixtureInterface();
  return @{@"configSHA256":[@"a"stringByPaddingToLength:64 withString:@"a"startingAtIndex:0],@"runtimeSHA256":[@"b"stringByPaddingToLength:64 withString:@"b"startingAtIndex:0],@"coreSHA256":[@"c"stringByPaddingToLength:64 withString:@"c"startingAtIndex:0],@"template":@"macos-dual-stack-v1",@"process":@{@"pid":@(value.process.pid),@"startSeconds":@(value.process.startSeconds),@"startMicros":@(value.process.startMicros)}};
}
static NSArray *RouteFixtureBaseline(void) {
  return @[@{@"family":@4,@"destination":@"0.0.0.0",@"prefix":@0,@"gateway":@"192.0.2.1",@"interfaceIndex":@2,@"interfaceName":@"en0",@"flags":@(RTF_UP|RTF_GATEWAY)}];
}
static void RouteFixtureCoreAppears(KuroFakeRouteStore *store) {
  for(NSDictionary *target in KuroCoreAutoRouteCandidate(RouteFixtureInterface()))[store.entries addObject:ObservedRoute(target)];
}
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


static void RouteObservationTests(void) {
  CHECK(geteuid()!=0);KuroCoreInterface association=RouteFixtureInterface();NSArray *targets=KuroCoreAutoRouteCandidate(association);
  CHECK(targets.count==5 && [targets[2][@"prefix"]isEqual:@30] && [targets[2][@"destination"]isEqual:@"198.18.0.0"]);
  for(NSDictionary *target in targets) {
    CHECK([target[@"gateway"]isEqual:([target[@"family"]isEqual:@4]?@"198.18.0.1":@"fdfe:dcba:9876::1")]);
    NSMutableDictionary *observed=[ObservedRoute(target)mutableCopy];CHECK(KuroCoreAutoRouteEqual(observed,target));
    unsigned int flags=[observed[@"flags"]unsignedIntValue];observed[@"flags"]=@(flags|RTF_DONE|RTF_IFREF);CHECK(KuroCoreAutoRouteEqual(observed,target));
    for(NSNumber *bit in @[@(RTF_UP),@(RTF_STATIC),@(RTF_GATEWAY),@(RTF_PRCLONING)]){observed[@"flags"]=@(flags&~bit.unsignedIntValue);CHECK(!KuroCoreAutoRouteEqual(observed,target));}
    for(NSNumber *bit in @[@(RTF_HOST),@(RTF_LLINFO),@(RTF_PROTO2),@(RTF_IFSCOPE),@(RTF_CLONING),@(RTF_MULTICAST),@(RTF_REJECT),@(RTF_BLACKHOLE),@(RTF_WASCLONED)]){observed[@"flags"]=@(flags|bit.unsignedIntValue);CHECK(!KuroCoreAutoRouteEqual(observed,target));}
  }
  KuroCoreInterface invalid=association;invalid.interfaceIndex=0;CHECK(!KuroCoreAutoRouteCandidate(invalid));
  char temporary[]="/tmp/kuro-route-observer-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  for(NSUInteger scenario=0;scenario<20;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];KuroFakeRouteStore *store=[KuroFakeRouteStore new];store.entries=[RouteFixtureBaseline()mutableCopy];
    KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:store];
    __block KuroRouteOwnerState owner=KuroRouteOwnerLive;KuroRouteOwnership ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)failure;CHECK([KuroRouteAssociation(value)isEqual:KuroRouteAssociation(association)]);return owner;};
    NSDictionary *dns=@{@"State:/Network/Global/DNS":@{@"ServerAddresses":@[@"192.0.2.53"]}};
    CHECK(![routes preparedRecord:&error]&&!error);
    if(scenario==16)routes.refuseSync=YES;
    NSArray *baseline=scenario==18?@[ObservedRoute(targets[0])]:RouteFixtureBaseline();
    if(scenario==17)dns=@{@"oversized":[@"x"stringByPaddingToLength:MessageLimit withString:@"x"startingAtIndex:0]};
    BOOL prepared=[routes prepareForSession:session binding:RouteFixtureBinding() baselineRoutes:baseline baselineDNS:dns physicalInterface:@"en0" error:&error];
    if(scenario==16){CHECK(!prepared&&Exists(journal)&&!routes.routesOff);RouteFixtureCoreAppears(store);CHECK(![routes observeForSession:session interface:association ownership:ownership error:&error]);store.entries=[RouteFixtureBaseline()mutableCopy];CHECK(![routes recoverRecordedAbsence:&error]&&!routes.routesOff);routes.refuseSync=NO;CHECK([routes recoverRecordedAbsence:&error]&&routes.routesOff);continue;}
    if(scenario==17||scenario==18){CHECK(!prepared&&!Exists(journal));continue;}
    CHECK(prepared&&store.snapshots==0&&!routes.routesOff);
    NSDictionary *record=[routes preparedRecord:&error];CHECK([record[@"phase"]isEqual:@"prepared"]&&record[@"interface"]==NSNull.null&&[record[@"baselineRoutes"]isEqual:baseline]&&[record[@"baselineDNS"]isEqual:dns]);
    if(scenario==19){CHECK(![routes prepareForSession:session binding:RouteFixtureBinding() baselineRoutes:baseline baselineDNS:dns physicalInterface:@"en0" error:&error]);continue;}
    RouteFixtureCoreAppears(store);NSData *preparedBytes=[NSData dataWithContentsOfFile:journal];
    if(scenario==1)[store.entries removeLastObject];
    if(scenario==2)[store.entries addObject:store.entries.lastObject];
    if(scenario>=3&&scenario<=5){NSMutableDictionary *changed=[store.entries.lastObject mutableCopy];if(scenario==3)changed[@"gateway"]=@"fdfe:dcba:9876::2";if(scenario==4)changed[@"interfaceIndex"]=@9;if(scenario==5)changed[@"flags"]=@([changed[@"flags"]unsignedIntValue]|RTF_LLINFO);store.entries[store.entries.count-1]=changed;}
    if(scenario==6)owner=KuroRouteOwnerUnknown;
    if(scenario==7)store.onSnapshot=^(KuroFakeRouteStore *value){(void)value;owner=KuroRouteOwnerUnknown;};
    if(scenario==8)store.failRead=YES;
    KuroCoreInterface value=association;if(scenario==9)value.process.startSeconds++;
    NSString *requested=scenario==10?@"11112233-4455-6677-8899-AABBCCDDEEFF":session;
    if(scenario==11)Put(journal,Bytes(@"[]"),0600);
    if(scenario==13)routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:store];
    if(scenario==14){NSMutableDictionary *changed=[record mutableCopy];changed[@"physicalInterface"]=@"en1";Put(journal,JSONData(changed),0600);}
    if(scenario==15)routes.refuseSync=YES;
    BOOL observed=[routes observeForSession:requested interface:value ownership:ownership error:&error];
    if(scenario==0||scenario==12){CHECK(observed&&[routes confirmObservedSession:session interface:association ownership:ownership error:&error]);record=[routes preparedRecord:&error];CHECK([record[@"phase"]isEqual:@"observed"]&&[record[@"routes"]isEqual:targets]);if(scenario==12){KuroOwnedRoutes *fresh=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:store];CHECK(![fresh confirmObservedSession:session interface:association ownership:ownership error:&error]);}continue;}
    CHECK(!observed&&!routes.routesOff&&Exists(journal));
    if(scenario>=1&&scenario<=10)CHECK([[NSData dataWithContentsOfFile:journal]isEqual:preparedBytes]);
    if(scenario==15){CHECK([[routes preparedRecord:&error][@"phase"]isEqual:@"observed"]);CHECK(![routes confirmObservedSession:session interface:association ownership:ownership error:&error]);CHECK(![routes observeForSession:session interface:association ownership:ownership error:&error]);routes.refuseSync=NO;CHECK([routes observeForSession:session interface:association ownership:ownership error:&error]);}
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native Core auto-route observer: fixed upstream five routes, closed pre-CONT baseline/binding, 20 observation/adoption/material-flags/durable-retry cases PASS; snapshot only");
}
static void RouteReadinessTests(void) {
  char temporary[]="/tmp/kuro-route-readiness-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));
  NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<11;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];KuroFakeRouteStore *store=[KuroFakeRouteStore new];store.entries=[RouteFixtureBaseline()mutableCopy];
    KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:store];
    CHECK([routes prepareForSession:session binding:RouteFixtureBinding() baselineRoutes:RouteFixtureBaseline() baselineDNS:@{} physicalInterface:@"en0" error:&error]);
    NSData *before=[NSData dataWithContentsOfFile:journal];NSUInteger syncs=routes.syncCalls;
    __block KuroRouteOwnerState owner=KuroRouteOwnerLive;
    KuroRouteOwnership ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return owner;};
    NSArray *targets=KuroCoreAutoRouteCandidate(association);
    if(scenario==0) {
      for(NSUInteger count=0;count<targets.count;count++) {
        error=@"stale caller error";
        CHECK([routes observeReadinessForSession:session interface:association ownership:ownership error:&error]==KuroRouteObservationPending&&!error);
        CHECK([[NSData dataWithContentsOfFile:journal]isEqual:before]&&routes.syncCalls==syncs&&!routes.routesOff);
        [store.entries addObject:ObservedRoute(targets[count])];
      }
      CHECK([routes observeReadinessForSession:session interface:association ownership:ownership error:&error]==KuroRouteObservationReady);
      CHECK([[routes preparedRecord:&error][@"phase"]isEqual:@"observed"]&&[routes confirmObservedSession:session interface:association ownership:ownership error:&error]);
      continue;
    }
    // The first target remains missing while later keys expose hard failures.
    if(scenario>=1&&scenario<=4) {
      NSMutableDictionary *last=[ObservedRoute(targets.lastObject)mutableCopy];
      if(scenario==1)last[@"gateway"]=@"fdfe:dcba:9876::2";
      if(scenario==2)last[@"interfaceIndex"]=@99;
      if(scenario==3)last[@"flags"]=@([last[@"flags"]unsignedIntValue]|RTF_LLINFO);
      [store.entries addObject:last];if(scenario==4)[store.entries addObject:last];
    }
    if(scenario==5)store.failRead=YES;
    if(scenario==6)store.onSnapshot=^(KuroFakeRouteStore *value){(void)value;owner=KuroRouteOwnerUnknown;};
    if(scenario==7)store.onSnapshot=^(KuroFakeRouteStore *value){(void)value;NSMutableDictionary *changed=[KuroDecodeJSON(before,MessageLimit,NULL)mutableCopy];changed[@"physicalInterface"]=@"en1";Put(journal,JSONData(changed),0600);};
    if(scenario==8){RouteFixtureCoreAppears(store);routes.refuseSync=YES;}
    if(scenario==9){RouteFixtureCoreAppears(store);CHECK([routes observeForSession:session interface:association ownership:ownership error:&error]);[store.entries removeLastObject];CHECK(![routes confirmObservedSession:session interface:association ownership:ownership error:&error]);}
    KuroCoreInterface value=association;if(scenario==10)value.process.startMicros++;
    CHECK([routes observeReadinessForSession:session interface:value ownership:ownership error:&error]==KuroRouteObservationInvalid&&error&&!routes.routesOff);
    if(scenario!=7&&scenario!=8&&scenario!=9)CHECK([[NSData dataWithContentsOfFile:journal]isEqual:before]);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native route readiness: 11 typed pending/late-complete/later-conflict/duplicate/read-error/identity/journal/durability/disappeared-route cases PASS; missing-only pending grants no observation");
}
static void RouteAbsenceTests(void) {
  char temporary[]="/tmp/kuro-route-absence-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<15;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];
    KuroFakeRouteStore *store=[KuroFakeRouteStore new];store.entries=[RouteFixtureBaseline()mutableCopy];KuroRouteDurabilityFixture *routes=[[KuroRouteDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:store];
    if(scenario!=10&&scenario!=11)CHECK([routes prepareForSession:session binding:RouteFixtureBinding() baselineRoutes:RouteFixtureBaseline() baselineDNS:@{} physicalInterface:@"en0" error:&error]);
    if(scenario==1){RouteFixtureCoreAppears(store);KuroRouteOwnership live=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return KuroRouteOwnerLive;};CHECK([routes observeForSession:session interface:association ownership:live error:&error]);}
    if(scenario>=2&&scenario<=5){NSMutableDictionary *target=[ObservedRoute(KuroCoreAutoRouteCandidate(association)[0])mutableCopy];if(scenario==3)target[@"gateway"]=@"192.0.2.99";if(scenario==4)target[@"interfaceIndex"]=@9;[store.entries addObject:target];if(scenario==5)[store.entries addObject:target];}
    if(scenario==6)store.failRead=YES;
    if(scenario==7)store.onSnapshot=^(KuroFakeRouteStore *value){if(value.snapshots==2)RouteFixtureCoreAppears(value);};
    if(scenario==8)routes.refuseSync=YES;
    if(scenario==9)Put(journal,Bytes(@"{\"format\":2,\"format\":2}"),0600);
    if(scenario==11)RouteFixtureCoreAppears(store);
    if(scenario==12){NSMutableDictionary *legacy=[KuroCoreAutoRouteCandidate(association)[0]mutableCopy];legacy[@"gateway"]=@"link";Put(journal,JSONData(@{@"format":@1,@"kind":@"routes-v1",@"session":session,@"interface":KuroRouteAssociation(association),@"routes":@[legacy],@"applied":@1}),0600);}
    if(scenario==13){NSMutableDictionary *legacy=[KuroCoreAutoRouteCandidate(association)[0]mutableCopy];legacy[@"gateway"]=@"link";Put(journal,JSONData(@{@"format":@1,@"kind":@"routes-v1",@"session":session,@"interface":KuroRouteAssociation(association),@"routes":@[legacy],@"applied":@1}),0600);[store.entries addObject:ObservedRoute(legacy)];}
    if(scenario==14){NSMutableDictionary *extra=[ObservedRoute(KuroCoreAutoRouteCandidate(association)[0])mutableCopy];extra[@"destination"]=@"203.0.113.0";extra[@"prefix"]=@24;extra[@"flags"]=@(RTF_UP|RTF_PROTO2);[store.entries addObject:extra];}
    NSData *prior=Exists(journal)?[NSData dataWithContentsOfFile:journal]:nil;NSUInteger count=store.entries.count;
    BOOL retired=[routes recoverRecordedAbsence:&error];BOOL expected=scenario==0||scenario==10||scenario==12;
    if(retired!=expected||routes.routesOff!=expected)fprintf(stderr,"absence case %lu expected %d actual %d: %s\n",(unsigned long)scenario,expected,retired,error.UTF8String);
    CHECK(retired==expected&&routes.routesOff==expected&&store.entries.count==count+(scenario==7?5:0));
    if(expected)CHECK(!Exists(journal));else if(scenario!=8&&prior)CHECK([[NSData dataWithContentsOfFile:journal]isEqual:prior]);
    if(scenario==8){CHECK(!Exists(journal));CHECK(![routes recoverRecordedAbsence:&error]&&!routes.routesOff);RouteFixtureCoreAppears(store);routes.refuseSync=NO;CHECK(![routes recoverRecordedAbsence:&error]&&!routes.routesOff);store.entries=[RouteFixtureBaseline()mutableCopy];CHECK([routes recoverRecordedAbsence:&error]&&routes.routesOff);}
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native route absence: 15 prepared/observed/legacy/no-journal/foreign/duplicate/read-failure/two-snapshot/unlink-sync retry cases PASS; no route deletion method exists");
}
static void RouteTests(void) {RouteKernelDumpTests();RouteObservationTests();RouteReadinessTests();RouteAbsenceTests();}
