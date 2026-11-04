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
static void ProductionNetworkTests(void) {
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
  CHECK(!KuroPreservedEndpoint(@"fd00:0000:0000:0000:0000:0000:0000:0001",ProductionBaseline(),@"en0",YES,&error));
  CHECK(!KuroPreservedEndpoint(@"::ffff:c0a8:101",ProductionBaseline(),@"en0",YES,&error));
  CHECK(KuroPreservedEndpoint(@"192.168.1.53",ProductionBaseline(),@"en0",YES,&error));
  NSArray *specificLast=@[ProductionRoute(4,@"192.168.0.0",16,@"link",@"en0",2,RTF_UP),ProductionRoute(4,@"192.168.0.0",16,@"link",@"en1",3,RTF_UP),ProductionBaseline()[2]];
  CHECK(KuroPreservedEndpoint(@"192.168.1.53",specificLast,@"en0",YES,&error));
  CHECK(!KuroPreservedEndpoint(@"192.168.2.53",specificLast,@"en0",YES,&error));
  NSMutableArray *wrongAddresses=[ProductionInterfaces(YES)mutableCopy]; NSMutableDictionary *wrong=[wrongAddresses.lastObject mutableCopy]; wrong[@"prefix"]=@64; wrongAddresses[wrongAddresses.count-1]=wrong;
  CHECK(!KuroCoreAddressesReady(association,wrongAddresses,&error));
  char temporary[]="/tmp/kuro-production-network-XXXXXX"; CHECK(mkdtemp(temporary)); char canonical[PATH_MAX]; CHECK(realpath(temporary,canonical)); NSString *base=@(canonical);
  for (NSUInteger scenario=0;scenario<13;scenario++) {
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
    if (scenario==1) { [routeBackend.entries removeLastObject]; [routeBackend.entries removeLastObject]; }
    if (scenario==2) { NSMutableDictionary *changed=[routeBackend.entries[1]mutableCopy]; changed[@"interfaceName"]=@"en1"; routeBackend.entries[1]=changed; }
    if (scenario==1 || scenario==2) {
      CHECK(![network preflightConfig:ProductionConfig() error:&error] && !network.runtimeInterfaceName && !routeBackend.additions && !dnsBackend.additions);
      CHECK([error containsString:scenario==1?@"more-specific":@"common observable"]); continue;
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
      CHECK(![restarted recoverSession:nil error:&error] && !routeBackend.deletions && !dnsBackend.removals);
      NSIndexSet *own=[routeBackend.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop) { (void)index;(void)stop; return ([entry[@"flags"]unsignedIntValue]&RTF_PROTO2)!=0; }]; [routeBackend.entries removeObjectsAtIndexes:own];
      if (scenario==8) { CHECK(![restarted recoverSession:nil error:&error] && !dnsBackend.removals); }
      [dnsBackend.records removeObjectForKey:KuroDNSKey(session)];
      CHECK([restarted recoverSession:nil error:&error] && restarted.networkOff && !routeBackend.deletions && !dnsBackend.removals); continue;
    }
    if (scenario==9) {
      owner=KuroRouteOwnerExitedInterfaceGone;
      NSIndexSet *own=[routeBackend.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop) { (void)index;(void)stop; return [entry[@"interfaceName"]isEqual:@"utun7"]; }]; [routeBackend.entries removeObjectsAtIndexes:own];
    }
    CHECK([network recoverSession:session error:&error] && network.networkOff && [dnsBackend.records isEqual:baselineDNS]);
    CHECK(routeBackend.deletions==(scenario==9?0:scenario==11?3:4) && dnsBackend.removals==1 && !network.runtimeInterfaceName);
    CHECK(!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]) && !Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("production network: inert construction, local-only DNS packets, baseline admission, dual-stack apply, partial failure, held-owner and restart absence fixtures passed (no system network calls)");
}
