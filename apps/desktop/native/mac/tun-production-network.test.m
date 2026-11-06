#import "tun-production-network.m"

static NSDictionary *ProductionConfig(void) {
  return @{@"version":@1,@"template":@"macos-dual-stack-v1",@"mode":@"rule",@"proxies":@[],@"groups":@[],@"rules":@[@{@"type":@"MATCH",@"value":@"",@"target":@"DIRECT",@"noResolve":@NO}],@"dns":@{@"nameservers":@[@"192.168.1.1"],@"bootstrap":@[@"2001:db8::53"],@"proxyNameservers":@[@"192.0.2.54"],@"policies":@[]}};
}
static NSDictionary *ProductionRoute(int family, NSString *destination, int prefix, NSString *gateway, NSString *name, int index, unsigned int flags) {
  return @{@"family":@(family),@"destination":destination,@"prefix":@(prefix),@"gateway":gateway,@"interfaceName":name,@"interfaceIndex":@(index),@"flags":@(flags)};
}
static NSArray *ProductionBaseline(void) {
  return @[ProductionRoute(4,@"0.0.0.0",0,@"192.168.1.1",@"en0",2,RTF_UP|RTF_GATEWAY|RTF_STATIC),
    ProductionRoute(6,@"::",0,@"fe80::1%2",@"en0",2,RTF_UP|RTF_GATEWAY|RTF_STATIC),
    ProductionRoute(4,@"192.168.1.0",24,@"link",@"en0",2,RTF_UP),
    ProductionRoute(6,@"fe80::%2",64,@"link",@"en0",2,RTF_UP)];
}
static NSArray *ProductionInterfaces(BOOL tun) {
  NSMutableArray *entries=[@[@{@"family":@0,@"name":@"en0",@"index":@2,@"flags":@(IFF_UP|IFF_RUNNING),@"linkType":@(IFT_ETHER)},
    @{@"family":@4,@"name":@"en0",@"index":@2,@"flags":@(IFF_UP|IFF_RUNNING),@"address":@"192.168.1.10",@"prefix":@24}]mutableCopy];
  if (tun) for (NSArray *address in @[@[@4,@"198.18.0.1",@30],@[@6,@"fdfe:dcba:9876::1",@126]]) [entries addObject:@{@"family":address[0],@"name":@"utun7",@"index":@7,@"flags":@(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT),@"address":address[1],@"prefix":address[2]}];
  return entries;
}
static NSData *ReadinessReply(NSData *question, BOOL ipv6) {
  NSMutableData *packet=[question mutableCopy]; unsigned char *header=packet.mutableBytes; header[2]=0x80; header[7]=1;
  unsigned char record[12]={0xc0,12,0,ipv6?28:1,0,1,0,0,0,0,0,ipv6?16:4}; [packet appendBytes:record length:sizeof(record)];
  [packet appendData:KuroRouteIP(ipv6?@"fdfe:dcba:9876::1":@"198.18.0.1",ipv6?6:4)]; return packet;
}
static KuroNetworkEnvironment *RecoveryFixtureEnvironment(void) {
  KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
  environment.interfaces=^NSArray *(NSString **error){(void)error;CHECK(NO);return nil;};
  environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *value,NSString **error){(void)child;(void)value;(void)error;CHECK(NO);return NO;};
  environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **error){(void)value;(void)error;CHECK(NO);return KuroRouteOwnerUnknown;};
  environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **error){(void)value;(void)error;CHECK(NO);return NO;};return environment;
}
static void IPv4UpstreamTests(void);
static void RecoveredNetworkReadbackTests(void) {
  char temporary[]="/tmp/krn-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*error=nil,*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  for(NSUInteger scenario=0;scenario<8;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu",(unsigned long)scenario]];FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    routes.failRead=scenario==1;dns.failSnapshot=scenario==2;
    routes.onSnapshot=^(KuroFakeRouteStore *backend){if(backend.snapshots==2) {
      if(scenario==3)[backend.entries addObject:ProductionRoute(4,@"0.0.0.0",1,@"link",@"utun7",7,RTF_UP|RTF_PROTO2)];
      if(scenario==4)[backend.entries addObject:ProductionRoute(6,@"::",1,@"link",@"utun7",7,RTF_UP)];
      if(scenario==5)[backend.entries addObject:ProductionRoute(4,@"198.18.0.0",30,@"link",@"utun7",7,RTF_UP)];
      if(scenario==7)Put([directory stringByAppendingPathComponent:KuroRouteJournal],Bytes(@"unknown journal after recovery"),0600);
    }};
    __weak KuroFakeDNSStore *weakDNS=dns;dns.onSnapshot=^{KuroFakeDNSStore *store=weakDNS;if(store.snapshots==2&&scenario==6)store.records[KuroDNSKey(session)]=KuroDNSValue();};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];
    NSDictionary *proof=[network recoverRecordedSession:session error:&error];CHECK((proof!=nil)==(scenario==0));
    if(proof)CHECK(([proof isEqual:@{@"format":@1,@"kind":@"current-owned-absence",@"session":session,@"routesOff":@YES,@"dnsOff":@YES}]));
    CHECK(![network stoppedEvidenceForSession:session error:NULL]);CHECK(!routes.deletions&&!routes.additions&&!dns.removals&&!dns.additions);
    if(scenario==6)CHECK(dns.records[KuroDNSKey(session)]);if(scenario==7)CHECK(Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
    routes.onSnapshot=nil;dns.onSnapshot=nil;
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 8 recovered backend readback cases: complete current route/DNS observations, late marked/split/internal-pool/DNS/journal conflicts reject; no held history or network writes");
}

static void ProductionDNSMetadataTests(void) {
  char temporary[]="/tmp/kuro-dns-meta-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<4;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];
    __block NSArray *interfaces=ProductionInterfaces(NO);
    if(scenario==1||scenario==2) {
      NSMutableDictionary *global=[dns.records[@"State:/Network/Global/DNS"]mutableCopy];global[@"__IF_INDEX__"]=@3;dns.records[@"State:/Network/Global/DNS"]=global;
      if(scenario==2)interfaces=[interfaces arrayByAddingObject:@{@"family":@0,@"name":@"en1",@"index":@3,@"flags":@(IFF_UP|IFF_RUNNING),@"linkType":@(IFT_ETHER)}];
    }
    NSDictionary *original=[dns.records copy];KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return KuroRouteOwnerLive;};
    environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];
    BOOL admitted=[network preflightConfig:ProductionConfig() error:&error];CHECK(admitted==(scenario!=1&&scenario!=2));
    if(!admitted){CHECK([error containsString:scenario==1?@"unavailable":@"original interface"]);CHECK(!routes.additions&&!dns.additions);continue;}
    interfaces=ProductionInterfaces(YES);[routes.entries addObject:ProductionRoute(4,@"198.18.0.0",30,@"link",@"utun7",7,RTF_UP)];[routes.entries addObject:ProductionRoute(6,@"fdfe:dcba:9876::",126,@"link",@"utun7",7,RTF_UP)];
    CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);
    NSDictionary *journal=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroDNSJournal],geteuid(),&error);CHECK([journal[@"baseline"]isEqual:original]);
    CHECK([network confirmSession:session error:&error]);
    if(scenario==3){NSMutableDictionary *global=[dns.records[@"State:/Network/Global/DNS"]mutableCopy];global[@"__ORDER__"]=@1;dns.records[@"State:/Network/Global/DNS"]=global;CHECK(![network confirmSession:session error:&error]&&[error containsString:@"DNS baseline changed"]);dns.records[@"State:/Network/Global/DNS"]=original[@"State:/Network/Global/DNS"];}
    CHECK([network recoverSession:session error:&error]&&network.networkOff&&[dns.records isEqual:original]);CHECK(routes.deletions==4&&dns.removals==1);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 4 production DNS metadata cases: effective interface admission, preserved scoped path, exact journal/baseline and mutation refusal, UUID-only recovery");
}

static void ProductionNetworkTests(void) {
  ProductionDNSMetadataTests();
  RecoveredNetworkReadbackTests();
  IPv4UpstreamTests();
  CHECK(geteuid()!=0); NSString *error=nil,*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  CHECK(([KuroProductionRuntimeFields()[@"hosts"][KuroReadinessDomain]isEqual:@[@"198.18.0.1",@"fdfe:dcba:9876::1"]]));
  for (NSNumber *family in @[@4,@6]) {
    BOOL ipv6=family.intValue==6; NSData *query=KuroReadinessQuestion(123,ipv6); NSMutableData *answer=[ReadinessReply(query,ipv6)mutableCopy];
    CHECK(KuroReadinessAnswer(answer,query,ipv6)); ((unsigned char *)answer.mutableBytes)[0]^=1; CHECK(!KuroReadinessAnswer(answer,query,ipv6));
    answer=[ReadinessReply(query,ipv6)mutableCopy]; ((unsigned char *)answer.mutableBytes)[answer.length-1]^=1; CHECK(!KuroReadinessAnswer(answer,query,ipv6));
    CHECK(!KuroReadinessAnswer([ReadinessReply(query,ipv6)subdataWithRange:NSMakeRange(0,query.length+1)],query,ipv6));
  }
  KuroCoreInterface association=RouteFixtureInterface();
  CHECK(KuroCoreAddressesReady(association,ProductionInterfaces(YES),&error));
  CHECK(!KuroCoreAddressesReady(association,ProductionInterfaces(NO),&error));
  CHECK(!KuroPreservedEndpoint(@"fd00:0000:0000:0000:0000:0000:0000:0001",ProductionBaseline(),@"en0",YES,NO,&error));
  CHECK(!KuroPreservedEndpoint(@"::ffff:c0a8:101",ProductionBaseline(),@"en0",YES,NO,&error));
  CHECK(KuroPreservedEndpoint(@"192.168.1.53",ProductionBaseline(),@"en0",YES,NO,&error));
  NSArray *specificLast=@[ProductionRoute(4,@"192.168.0.0",16,@"link",@"en0",2,RTF_UP),ProductionRoute(4,@"192.168.0.0",16,@"link",@"en1",3,RTF_UP),ProductionBaseline()[2]];
  CHECK(KuroPreservedEndpoint(@"192.168.1.53",specificLast,@"en0",YES,NO,&error));
  CHECK(!KuroPreservedEndpoint(@"192.168.2.53",specificLast,@"en0",YES,NO,&error));
  NSMutableArray *wrongAddresses=[ProductionInterfaces(YES)mutableCopy]; NSMutableDictionary *wrong=[wrongAddresses.lastObject mutableCopy]; wrong[@"prefix"]=@64; wrongAddresses[wrongAddresses.count-1]=wrong;
  CHECK(!KuroCoreAddressesReady(association,wrongAddresses,&error));
  char temporary[]="/tmp/kuro-production-network-XXXXXX"; CHECK(mkdtemp(temporary)); char canonical[PATH_MAX]; CHECK(realpath(temporary,canonical)); NSString *base=@(canonical);
  for (NSUInteger scenario=0;scenario<15;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]]; FixtureDirectory(directory);
    KuroFakeRouteStore *routeBackend=[KuroFakeRouteStore new]; routeBackend.directory=directory; routeBackend.entries=[ProductionBaseline()mutableCopy];
    KuroFakeDNSStore *dnsBackend=[KuroFakeDNSStore new]; dnsBackend.directory=directory;
    dnsBackend.records[@"State:/Network/Service/corp/DNS"]=@{@"ServerAddresses":@[@"192.168.1.53"],@"SupplementalMatchDomains":@[@"corp.example"],@"SupplementalMatchOrders":@[@100],@"SearchDomains":@[@"corp.example"]};
    NSDictionary *baselineDNS=[dnsBackend.records copy];
    __block NSArray *interfaces=ProductionInterfaces(NO); __block KuroRouteOwnerState owner=KuroRouteOwnerLive; __block BOOL dnsReady=YES; __block NSUInteger probes=0;
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure) { (void)failure; return interfaces; };
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure) { (void)failure; CHECK(child==association.process.pid); *result=association; return YES; };
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure) { (void)failure; CHECK([KuroRouteAssociation(expected)isEqual:KuroRouteAssociation(association)]); return owner; };
    environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure) { (void)expected; probes++; return dnsReady || Fail(failure,@"injected static-host probe refusal"); };
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routeBackend dns:dnsBackend environment:environment];
    CHECK(!network.runtimeInterfaceName && !routeBackend.snapshots && !dnsBackend.snapshots && !probes);
    CHECK(![network stoppedEvidenceForSession:session error:&error]);
    if (scenario==1) { [routeBackend.entries removeLastObject]; [routeBackend.entries removeLastObject]; }
    if (scenario==2) { NSMutableDictionary *changed=[routeBackend.entries[1]mutableCopy]; changed[@"interfaceName"]=@"en1"; routeBackend.entries[1]=changed; }
    if (scenario==13 || scenario==14) {
      NSUInteger index=scenario==13?0:1;NSMutableDictionary *blocked=[routeBackend.entries[index]mutableCopy];
      blocked[@"flags"]=@([blocked[@"flags"]unsignedIntValue]|(scenario==13?RTF_REJECT:RTF_BLACKHOLE));routeBackend.entries[index]=blocked;
    }
    if (scenario==1 || scenario==2 || scenario==13 || scenario==14) {
      CHECK(![network preflightConfig:ProductionConfig() error:&error] && !network.runtimeInterfaceName && !routeBackend.additions && !dnsBackend.additions);
      CHECK([error containsString:scenario==1?@"more-specific":scenario==2?@"common observable":@"reject/blackhole"]); continue;
    }
    CHECK([network preflightConfig:ProductionConfig() error:&error] && [network.runtimeInterfaceName isEqual:@"en0"]);
    interfaces=ProductionInterfaces(YES);
    [routeBackend.entries addObject:ProductionRoute(4,@"198.18.0.0",30,@"link",@"utun7",7,RTF_UP)];
    [routeBackend.entries addObject:ProductionRoute(6,@"fdfe:dcba:9876::",126,@"link",@"utun7",7,RTF_UP)];
    if (scenario==3) dnsReady=NO;
    if (scenario==3) { CHECK(![network readyChild:association.process.pid session:session error:&error] && !routeBackend.additions && !dnsBackend.additions); CHECK([network recoverSession:session error:&error]); continue; }
    CHECK([network readyChild:association.process.pid session:session error:&error]);
    if (scenario==4) { NSMutableDictionary *changed=[routeBackend.entries[0]mutableCopy]; changed[@"gateway"]=@"192.168.1.2"; routeBackend.entries[0]=changed; }
    if (scenario==4) { CHECK(![network applyChild:association.process.pid session:session error:&error] && !routeBackend.additions && !dnsBackend.additions); continue; }
    if (scenario==5) dnsBackend.failAdd=dnsBackend.addThenFail=YES;
    if (scenario==12) {
      __block BOOL changed=NO;
      routeBackend.onSnapshot=^(KuroFakeRouteStore *backend) { if (!changed && backend.additions==4 && dnsBackend.additions==1) {
        changed=YES; NSMutableDictionary *route=[backend.entries[0]mutableCopy]; route[@"gateway"]=@"192.168.1.2"; backend.entries[0]=route;
      } };
    }
    BOOL applied=[network applyChild:association.process.pid session:session error:&error];
    CHECK(applied==(scenario!=5 && scenario!=12)); CHECK(routeBackend.additions==4 && dnsBackend.additions==1);
    if (applied) CHECK([network confirmSession:session error:&error]);
    if (scenario==10) {
      NSMutableDictionary *changed=[dnsBackend.records[KuroDNSKey(session)]mutableCopy]; changed[@"ServerAddresses"]=@[@"192.0.2.99"]; dnsBackend.records[KuroDNSKey(session)]=changed;
      CHECK(![network confirmSession:session error:&error]); CHECK(![network recoverSession:session error:&error] && !routeBackend.deletions && !dnsBackend.removals);
      dnsBackend.records[KuroDNSKey(session)]=KuroDNSValue();
    }
    if (scenario==11) {
      NSUInteger index=[routeBackend.entries indexOfObject:ObservedRoute(KuroSplitRouteCandidate(association)[0])]; CHECK(index!=NSNotFound);
      [routeBackend.entries removeObjectAtIndex:index]; CHECK(![network confirmSession:session error:&error]);
    }
    CHECK(![network recoverSession:@"11112233-4455-6677-8899-AABBCCDDEEFF" error:&error] && !routeBackend.deletions && !dnsBackend.removals);
    if (scenario==6) { owner=KuroRouteOwnerUnknown; CHECK(![network recoverSession:session error:&error] && !routeBackend.deletions && !dnsBackend.removals); owner=KuroRouteOwnerLive; }
    if (scenario==7 || scenario==8) {
      KuroProductionNetwork *restarted=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routeBackend dns:dnsBackend environment:environment];
      CHECK(![restarted recoverSession:nil error:&error] && !routeBackend.deletions && dnsBackend.removals==1 && !restarted.networkOff);
      CHECK([error containsString:@"routes:"]&&[dnsBackend.records isEqual:baselineDNS]&&!Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
      NSIndexSet *own=[routeBackend.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop) { (void)index;(void)stop; return ([entry[@"flags"]unsignedIntValue]&RTF_PROTO2)!=0; }]; [routeBackend.entries removeObjectsAtIndexes:own];
      CHECK([restarted recoverSession:nil error:&error] && restarted.networkOff && !routeBackend.deletions && dnsBackend.removals==1); CHECK(![restarted stoppedEvidenceForSession:session error:&error]); continue;
    }
    if (scenario==9) {
      owner=KuroRouteOwnerExitedInterfaceGone;
      NSIndexSet *own=[routeBackend.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop) { (void)index;(void)stop; return [entry[@"interfaceName"]isEqual:@"utun7"]; }]; [routeBackend.entries removeObjectsAtIndexes:own];
    }
    CHECK([network recoverSession:session error:&error] && network.networkOff && [dnsBackend.records isEqual:baselineDNS]);
    CHECK(routeBackend.deletions==(scenario==9?0:scenario==11?3:4) && dnsBackend.removals==1 && !network.runtimeInterfaceName);
    CHECK(!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]) && !Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
    NSDictionary *stopped=[network stoppedEvidenceForSession:session error:&error];CHECK(stopped&&KuroBool(stopped[@"routesOff"])&&KuroBool(stopped[@"dnsOff"])&&[stopped[@"routesOff"]boolValue]&&[stopped[@"dnsOff"]boolValue]);
    CHECK(Match(stopped[@"routeJournalSHA256"],@"\\A[0-9a-f]{64}\\z")&&Match(stopped[@"dnsJournalSHA256"],@"\\A[0-9a-f]{64}\\z"));
    CHECK(![network stoppedEvidenceForSession:@"11112233-4455-6677-8899-AABBCCDDEEFF" error:&error]);
  }
  for(NSUInteger scenario=0;scenario<2;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"aggregate%lu",(unsigned long)scenario]];FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    KuroOwnedDNS *old=[[KuroOwnedDNS alloc]initWithDirectory:directory owner:geteuid() backend:dns];CHECK([old installForSession:session error:&error]);dns.failRemove=YES;
    KuroOwnedRoutes *oldRoutes=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:routes];KuroRouteOwnership live=^KuroRouteOwnerState(KuroCoreInterface ignored,NSString **problem){(void)ignored;(void)problem;return KuroRouteOwnerLive;};
    CHECK([oldRoutes installForSession:session interface:association routes:KuroSplitRouteCandidate(association) ownership:live error:&error]);if(scenario==1)[routes.entries removeAllObjects];
    KuroProductionNetwork *fresh=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];error=nil;
    CHECK(![fresh recoverSession:nil error:&error]&&!fresh.networkOff&&dns.removals==1&&!routes.deletions&&[error hasPrefix:@"DNS: remove failed"]);
    if(scenario==0)CHECK([error containsString:@"; routes:"]&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
    else CHECK(![error containsString:@"; routes:"]&&!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
    CHECK(![fresh stoppedEvidenceForSession:session error:NULL]);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("production network: inert construction, local-only DNS packets, baseline admission, dual-stack apply, partial failure, held-owner and restart absence fixtures passed (no system network calls)");
}

// No external IPv6 reachability is claimed: both local TUN families stay required.
static void IPv4UpstreamTests(void) {
  NSString *session=@"00112233-4455-6677-8899-AABBCCDDEEFF";
  char temporary[]="/tmp/kuro-ipv4-upstream-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));NSString *base=@(canonical);
  KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<18;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];[routes.entries removeObjectAtIndex:1];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    dns.records[@"State:/Network/Service/corp/DNS"]=@{@"ServerAddresses":@[@"192.168.1.53"],@"SupplementalMatchDomains":@[@"corp.example"],@"SupplementalMatchOrders":@[@100]};
    NSMutableDictionary *config=[ProductionConfig()mutableCopy],*settings=[config[@"dns"]mutableCopy];settings[@"bootstrap"]=@[@"192.0.2.53"];config[@"dns"]=settings;
    __block NSArray *interfaces=ProductionInterfaces(NO);__block NSUInteger probes=0;
    if(scenario>=1&&scenario<=3)settings[@[@"nameservers",@"bootstrap",@"proxyNameservers"][scenario-1]]=@[@"2001:db8::53"];
    if(scenario==4)settings[@"policies"]=@[@{@"domain":@"corp.example",@"nameservers":@[@"2001:db8::53"]}];
    if(scenario==5)config[@"proxies"]=@[@{@"type":@"http",@"name":@"edge",@"server":@"2001:db8::53",@"port":@8080}];
    if(scenario==6)dns.records[@"State:/Network/Service/default/DNS"]=@{@"ServerAddresses":@[@"2001:db8::53"]};
    if(scenario==7) {
      dns.records[@"State:/Network/Interface/en1/DNS"]=@{@"ServerAddresses":@[@"2001:db8::53"],@"InterfaceIndex":@3,@"SupplementalMatchDomains":@[@"corp.example"]};
      interfaces=[interfaces arrayByAddingObject:@{@"family":@0,@"name":@"en1",@"index":@3,@"flags":@(IFF_UP|IFF_RUNNING),@"linkType":@(IFT_ETHER)}];
      [routes.entries addObject:ProductionRoute(6,@"2001:db8::",64,@"link",@"en0",2,RTF_UP)];
    }
    if(scenario==8||scenario==12||scenario==13) {
      settings[@"bootstrap"]=@[@"2001:db8::53"];
      [routes.entries addObject:ProductionRoute(6,@"2001:db8::",64,@"link",@"en0",2,RTF_UP|(scenario==13?RTF_REJECT:0))];
      if(scenario==12)[routes.entries addObject:ProductionRoute(6,@"2001:db8::",64,@"link",@"en1",3,RTF_UP)];
    }
    if(scenario==9)[routes.entries removeObjectAtIndex:0];
    if(scenario==10||scenario==11) {NSMutableDictionary *v6=[ProductionBaseline()[1]mutableCopy];v6[scenario==10?@"interfaceName":@"interfaceIndex"]=scenario==10?(id)@"en1":@3;[routes.entries addObject:v6];}
    if(scenario==15) {
      dns.records[@"State:/Network/Interface/en1/DNS"]=@{@"ServerAddresses":@[@"fd00::53"],@"InterfaceIndex":@3,@"SupplementalMatchDomains":@[@"corp.example"]};
      interfaces=[interfaces arrayByAddingObject:@{@"family":@0,@"name":@"en1",@"index":@3,@"flags":@(IFF_UP|IFF_RUNNING),@"linkType":@(IFT_ETHER)}];
      [routes.entries addObject:ProductionRoute(6,@"fd00::",64,@"link",@"en1",3,RTF_UP)];
    }
    if(scenario==16) {NSMutableArray *changed=[interfaces mutableCopy];NSMutableDictionary *physical=[changed[0]mutableCopy];physical[@"flags"]=@(IFF_UP);changed[0]=physical;interfaces=changed;}
    if(scenario==17)config[@"proxies"]=@[@{@"type":@"http",@"name":@"edge",@"server":@"proxy.example",@"port":@8080}];
    NSData *originalConfig=JSONData(config);NSDictionary *originalDNS=[dns.records copy];NSArray *originalRoutes=[routes.entries copy];
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)failure;CHECK([KuroRouteAssociation(expected)isEqual:KuroRouteAssociation(association)]);return KuroRouteOwnerLive;};
    environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;probes++;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];
    BOOL accepted=[network preflightConfig:config error:&error],expected=scenario==0||scenario==8||scenario==14||scenario==15||scenario==17;
    CHECK(accepted==expected);CHECK([JSONData(config)isEqual:originalConfig]&&[dns.records isEqual:originalDNS]&&[routes.entries isEqual:originalRoutes]);
    CHECK(!routes.additions&&!dns.additions&&!probes);
    if(!expected) {
      CHECK(error.length&&!network.runtimeInterfaceName);
      if((scenario>=1&&scenario<=6)||scenario==13)CHECK([error containsString:@"2001:db8::53"]&&[error containsString:@"no IPv6 default"]);
      if(scenario==7)CHECK([error containsString:@"original interface"]);
      if(scenario==9)CHECK([error containsString:@"IPv4 default"]);
      if(scenario==10||scenario==11)CHECK([error containsString:@"common observable"]);
      if(scenario==12)CHECK([error containsString:@"ambiguous"]);
      if(scenario==16)CHECK([error containsString:@"verified running"]);
      continue;
    }
    CHECK([network.runtimeInterfaceName isEqual:@"en0"]);
    NSDictionary *runtime=KuroDecodeJSON(KuroTunRuntimeJSON(originalConfig,&error),128*1024,&error);
    CHECK([runtime[@"ipv6"]isEqual:@YES]&&[runtime[@"dns"][@"ipv6"]isEqual:@YES]);
    CHECK([runtime[@"dns"][@"default-nameserver"]isEqual:settings[@"bootstrap"]]);
    CHECK(([runtime[@"tun"][@"inet6-address"]isEqual:@[@"fdfe:dcba:9876::1/126"]]));
    NSMutableArray *readyInterfaces=[interfaces mutableCopy];for(NSDictionary *entry in ProductionInterfaces(YES))if([entry[@"name"]isEqual:@"utun7"])[readyInterfaces addObject:entry];interfaces=readyInterfaces;
    [routes.entries addObject:ProductionRoute(4,@"198.18.0.0",30,@"link",@"utun7",7,RTF_UP)];[routes.entries addObject:ProductionRoute(6,@"fdfe:dcba:9876::",126,@"link",@"utun7",7,RTF_UP)];
    if(scenario==14) { [routes.entries addObject:ProductionBaseline()[1]];CHECK(![network readyChild:association.process.pid session:session error:&error]);CHECK([error containsString:@"unexpected route"]&&!routes.additions&&!dns.additions);continue; }
    CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);
    CHECK(routes.additions==4&&dns.additions==1&&probes>0);
    CHECK(([dns.records[KuroDNSKey(session)][@"ServerAddresses"]isEqual:@[@"198.18.0.2",@"fdfe:dcba:9876::2"]]));
    CHECK([network confirmSession:session error:&error]);CHECK([network recoverSession:session error:&error]&&network.networkOff);
    CHECK(routes.deletions==4&&dns.removals==1&&[dns.records isEqual:originalDNS]);
    for(NSDictionary *entry in originalRoutes)CHECK([routes.entries containsObject:entry]);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("IPv4-only upstream: 18 admission/apply/recovery cases preserve dual-stack TUN, four routes, both DNS addresses and existing LAN/scoped DNS; unsafe literal paths and egress changes rejected (mock only)");
}
