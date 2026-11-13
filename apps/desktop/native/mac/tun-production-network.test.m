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
  environment.interfaces=^NSArray *(NSString **error){(void)error;return ProductionInterfaces(NO);};
  environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *value,NSString **error){(void)child;(void)value;(void)error;CHECK(NO);return NO;};
  environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **error){(void)value;(void)error;CHECK(NO);return KuroRouteOwnerUnknown;};
  environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **error){(void)value;(void)error;CHECK(NO);return NO;};return environment;
}

static NSDictionary *ProductionBinding(KuroCoreInterface a) {
  return @{@"configSHA256":Hash(Bytes(@"admitted")),@"runtimeSHA256":Hash(Bytes(@"runtime")),@"coreSHA256":Hash(Bytes(@"core")),@"template":@"macos-dual-stack-v1",@"process":@{@"pid":@(a.process.pid),@"startSeconds":@(a.process.startSeconds),@"startMicros":@(a.process.startMicros)}};
}
static NSDictionary *ProductionOwner(NSString *session,KuroCoreInterface a) {
  NSDictionary *binding=ProductionBinding(a);
  return @{@"format":@1,@"session":session,@"pid":@(a.process.pid),@"parent":@1234,@"startSeconds":@(a.process.startSeconds),@"startMicros":@(a.process.startMicros),@"executableSHA256":binding[@"coreSHA256"],@"phase":@"prepared",@"processGroup":@1234,
    @"launch":@{@"configSHA256":binding[@"configSHA256"],@"runtimeSHA256":binding[@"runtimeSHA256"],@"coreSHA256":binding[@"coreSHA256"],@"template":binding[@"template"]}};
}
static NSArray *ProductionCoreRoutes(KuroCoreInterface a) {
  NSMutableArray *observed=[NSMutableArray array];
  for(NSDictionary *entry in KuroCoreAutoRouteCandidate(a))[observed addObject:ObservedRoute(entry)];
  // Darwin P2P creates only the own IPv4 HOST route; the /30 via .1 above is
  // the separate fixed Core auto-route, never an invented connected route.
  [observed addObject:ProductionRoute(4,@"198.18.0.1",32,@"link",@(a.interfaceName),a.interfaceIndex,RTF_UP|RTF_HOST)];
  [observed addObject:ProductionRoute(6,@"fdfe:dcba:9876::",126,@"link",@(a.interfaceName),a.interfaceIndex,RTF_UP)];return observed;
}
static void ProductionCoreGone(KuroFakeRouteStore *routes) {
  NSIndexSet *own=[routes.entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger i,BOOL *stop){(void)i;(void)stop;return [entry[@"interfaceName"]isEqual:@"utun7"];}];[routes.entries removeObjectsAtIndexes:own];
}
@interface KuroPrepareSyncFailure:KuroOwnedRoutes
@property(nonatomic)BOOL failSync;
@end
@implementation KuroPrepareSyncFailure
- (BOOL)syncDirectory:(NSString **)error{return self.failSync?Fail(error,@"injected prepared intent directory sync failure"):[super syncDirectory:error];}
@end
static NSArray *ProductionMulticastCompanions(KuroCoreInterface association) {
  NSString *gateway=[NSString stringWithFormat:@"fe80::1234%%%u",association.interfaceIndex];NSMutableArray *routes=[NSMutableArray array];
  for(NSArray *value in @[@[@"ff00::",@8],@[@"ff01::",@32],@[@"ff02::",@32]])[routes addObject:ProductionRoute(6,[NSString stringWithFormat:@"%@%%%u",value[0],association.interfaceIndex],[value[1]intValue],gateway,@(association.interfaceName),association.interfaceIndex,RTF_UP|RTF_CLONING|RTF_MULTICAST|RTF_IFSCOPE)];return routes;
}
static void IPv4UpstreamTests(void);
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
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};
    environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];
    BOOL admitted=[network preflightConfig:ProductionConfig() error:&error];CHECK(admitted==(scenario!=1&&scenario!=2));
    if(!admitted){CHECK([error containsString:scenario==1?@"unavailable":@"original interface"]);CHECK(!dns.additions);continue;}
    CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);
    NSDictionary *journal=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroDNSJournal],geteuid(),&error);CHECK([journal[@"baseline"]isEqual:original]);
    CHECK([network confirmSession:session error:&error]);
    if(scenario==3){NSMutableDictionary *global=[dns.records[@"State:/Network/Global/DNS"]mutableCopy];global[@"__ORDER__"]=@1;dns.records[@"State:/Network/Global/DNS"]=global;CHECK(![network confirmSession:session error:&error]&&[error containsString:@"DNS baseline changed"]);dns.records[@"State:/Network/Global/DNS"]=original[@"State:/Network/Global/DNS"];}
    ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);CHECK([network recoverSession:session error:&error]&&network.networkOff&&[dns.records isEqual:original]);CHECK(dns.removals==1);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 4 production DNS metadata cases: effective interface admission, preserved scoped path, exact journal/baseline and mutation refusal, UUID-only recovery");
}

static void ProductionActiveDNSDerivedTests(void) {
  char temporary[]="/tmp/kuro-dns-derived-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF",*globalKey=@"State:/Network/Global/DNS";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<19;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];
    NSMutableDictionary *baselineGlobal=[dns.records[globalKey]mutableCopy];
    if(scenario>=15)baselineGlobal[@"__FLAGS__"]=@((scenario-15)*2);
    if(scenario==10)baselineGlobal[@"SearchDomains"]=@[@"example.invalid"];
    if(scenario==11)baselineGlobal[@"__ORDER__"]=@1;
    dns.records[globalKey]=baselineGlobal;NSDictionary *original=[dns.records copy];
    __block NSArray *interfaces=ProductionInterfaces(NO);KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};
    environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];
    CHECK([network preflightConfig:ProductionConfig() error:&error]);CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];CHECK([network readyChild:association.process.pid session:session error:&error]);
    __weak KuroFakeDNSStore *weakDNS=dns;__block BOOL injected=NO;
    dns.onValueRead=^{KuroFakeDNSStore *value=weakDNS;if(!value.additions||injected)return;injected=YES;
      // Sanitized real configd promotion: no private interface in Supplemental Global.
      NSMutableDictionary *derived=[@{@"ServerAddresses":@[@"198.18.0.2",@"fdfe:dcba:9876::2"],@"SearchOrder":@1,@"__CONFIGURATION_ID__":[NSString stringWithFormat:@"Supplemental: dev.kuro.tun.%@ 0",session],@"__ORDER__":@0,@"__FLAGS__":@([baselineGlobal[@"__FLAGS__"]unsignedIntValue]|0x4000)}mutableCopy];
      if(scenario==1)derived[@"__CONFIGURATION_ID__"]=@"Supplemental: dev.kuro.tun.11112233-4455-6677-8899-AABBCCDDEEFF 0";
      if(scenario==2)derived[@"unknown"]=@0;
      if(scenario==3)derived[@"__FLAGS__"]=@0x5002;
      if(scenario==4){NSString *key=@"State:/Network/Service/00112233-4455-6677-8899-AABBCCDDEEFF/DNS";value.records[key]=@{@"ServerAddresses":@[@"192.0.2.99"]};}
      if(scenario==5)derived[@"__IF_INDEX__"]=@2;
      if(scenario==6)derived[@"ServerAddresses"]=@[@"192.168.1.1"];
      if(scenario==7)derived[@"__ORDER__"]=@1;
      if(scenario==8)derived[@"SearchOrder"]=@2;
      if(scenario==9)derived[@"SearchOrder"]=@YES;
      if(scenario==12)derived[@"__FLAGS__"]=@YES;
      if(scenario==13)derived[@"__ORDER__"]=@NO;
      if(scenario==14)value.records[KuroDNSKey(session)]=@{@"ServerAddresses":@[@"192.0.2.99"]};
      value.records[globalKey]=derived;
    };
    BOOL accepted=[network applyChild:association.process.pid session:session error:&error];BOOL expected=scenario==0||scenario>=15;
    if(accepted!=expected)fprintf(stderr,"derived scenario=%lu accepted=%d expected=%d error=%s\n",(unsigned long)scenario,accepted,expected,error.UTF8String?:"none");
    CHECK(injected&&accepted==expected);CHECK(dns.additions==1&&dns.removals==0&&Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
    NSDictionary *journal=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroDNSJournal],geteuid(),NULL);CHECK([journal[@"baseline"]isEqual:original]);
    if(expected)CHECK([network confirmSession:session error:&error]);else CHECK(error.length&&[error containsString:scenario==14?@"stage=readback-value":@"DNS baseline changed"]);
    // Active-only test: restore the fake OS projection before ordinary recovery.
    dns.onValueRead=nil;dns.records=[original mutableCopy];dns.records[KuroDNSKey(session)]=KuroDNSValue();ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);error=nil;
    CHECK([network recoverSession:session error:&error]&&network.networkOff&&[dns.records isEqual:original]&&dns.removals==1);
    printf("PASS active DNS derived scenario=%lu accepted=%d exact baseline retained\n",(unsigned long)scenario,accepted);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}

static void ProductionDNSDifferenceTests(void) {
  char temporary[]="/tmp/kuro-dns-diff-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<2;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];NSDictionary *original=[dns.records copy];
    __block NSArray *interfaces=ProductionInterfaces(NO);KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];CHECK([network readyChild:association.process.pid session:session error:&error]);
    __weak KuroFakeDNSStore *weakDNS=dns;__block BOOL injected=NO;
    dns.onValueRead=^{KuroFakeDNSStore *value=weakDNS;if(!value.additions||injected)return;injected=YES;
      value.records[@"State:/Network/Global/DNS"]=@{@"ServerAddresses":scenario?@[@"203.0.113.77"]:KuroDNSValue()[@"ServerAddresses"],@"__CONFIGURATION_ID__":scenario?@"Supplemental: private-service-marker 0":[NSString stringWithFormat:@"Supplemental: dev.kuro.tun.%@ 0",session],@"__ORDER__":@0,@"__FLAGS__":@16390,@"SearchOrder":@1};
      if(scenario)value.records[@"State:/Network/Service/private-service-marker/DNS"]=@{@"DomainName":@"private-domain-marker"};
    };
    CHECK(![network applyChild:association.process.pid session:session error:&error]&&injected);
    CHECK([error containsString:@"stage=post-write-admission; reason=DNS baseline changed; preserving existing resolvers and stopping this session"]);
    CHECK([error containsString:scenario?@"keys=+1/-0/~1":@"keys=+0/-0/~1"]&&[error containsString:@"global=changed"]&&[error containsString:@"fields=cid,if,flags,servers,searchOrder"]);
    CHECK([error containsString:scenario?@"Supplemental/self0":@"Supplemental/self1"]&&[error containsString:scenario?@"servers=0/0":@"servers=0/1"]);
    CHECK(![error containsString:@"private-service-marker"]&&![error containsString:@"private-domain-marker"]&&![error containsString:@"203.0.113.77"]&&![error containsString:session]);
    NSRange summary=[error rangeOfString:@"dnsDiff "];CHECK(summary.location!=NSNotFound&&[[error substringFromIndex:summary.location]lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=512&&error.length<1024);
    CHECK(dns.additions==1&&dns.removals==0&&[dns.records[KuroDNSKey(session)]isEqual:KuroDNSValue()]&&Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
    printf("PASS DNS post-write refusal scenario=%lu: %s\n",(unsigned long)scenario,error.UTF8String);
    // Restore only the injected fake OS derivation; production never rewrites Global.
    dns.onValueRead=nil;dns.records=[original mutableCopy];dns.records[KuroDNSKey(session)]=KuroDNSValue();ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);CHECK([network recoverSession:session error:&error]&&network.networkOff&&[dns.records isEqual:original]&&dns.removals==1);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}

static void ProductionRecoveryDNSDerivedTests(void) {
  char temporary[]="/tmp/kuro-dns-recover-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<11;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];NSDictionary *original=[dns.records copy];
    __block NSArray *interfaces=ProductionInterfaces(NO);__block BOOL refuseExit=NO;KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return refuseExit?KuroRouteOwnerUnknown:interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];CHECK([network readyChild:association.process.pid session:session error:&error]);
    NSString *global=@"State:/Network/Global/DNS",*journal=[directory stringByAppendingPathComponent:KuroRouteJournal];
    __weak KuroFakeDNSStore *activeDNS=dns;__block BOOL activeDerived=NO;
    if(scenario==0)dns.onValueRead=^{KuroFakeDNSStore *value=activeDNS;if(!value.additions||activeDerived)return;activeDerived=YES;
      value.records[global]=@{@"ServerAddresses":@[@"198.18.0.2",@"fdfe:dcba:9876::2"],@"SearchOrder":@1,@"__CONFIGURATION_ID__":[NSString stringWithFormat:@"Supplemental: dev.kuro.tun.%@ 0",session],@"__ORDER__":@0,@"__FLAGS__":@16386};
    };
    CHECK([network applyChild:association.process.pid session:session error:&error]);
    if(scenario==0)CHECK(activeDerived&&[network confirmSession:session error:&error]);dns.onValueRead=nil;
    ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);
    NSData *routeBytes=ReadProtected(directory,journal,geteuid(),NULL);
    if(scenario!=0)dns.records[global]=scenario>=9?original[global]:KuroDNSDerivedGlobal(original[global],session);CHECK(dns.records[global]);
    if(scenario==2){NSMutableDictionary *foreign=[dns.records[global]mutableCopy];foreign[@"__CONFIGURATION_ID__"]=@"Supplemental: private-service-marker 0";dns.records[global]=foreign;}
    if(scenario==3)dns.records[@"State:/Network/Service/private-service-marker/DNS"]=@{@"DomainName":@"private-domain-marker"};
    NSDictionary *extra=ProductionRoute(4,@"198.18.0.2",32,@"link",@"en0",2,RTF_UP);if(scenario==4)[routes.entries addObject:extra];
    if(scenario==5)routes.failRead=YES;if(scenario==7)refuseExit=YES;
    if(scenario==8){NSMutableDictionary *record=[ReadJSON(directory,journal,geteuid(),NULL)mutableCopy],*binding=[record[@"binding"]mutableCopy];binding[@"runtimeSHA256"]=Hash(Bytes(@"other runtime"));record[@"binding"]=binding;Put(journal,JSONData(record),0600);}
    KuroDNSDurabilityFixture *sync=nil;if(scenario==9){sync=[[KuroDNSDurabilityFixture alloc]initWithDirectory:directory owner:geteuid() backend:dns];sync.refuseSync=YES;[network setValue:sync forKey:@"dns"];}
    __weak KuroFakeDNSStore *weakDNS=dns;__block NSUInteger postRemovalReads=0;
    dns.onSnapshot=^{KuroFakeDNSStore *value=weakDNS;if(!value.removals)return;postRemovalReads++;if(scenario==0){CHECK(!value.records[KuroDNSKey(session)]&&Exists(journal));if(postRemovalReads<3)CHECK(KuroDNSOwnDerivedBaseline(original,value.records,session));if(postRemovalReads==3)value.records[global]=original[global];}if(scenario==10&&postRemovalReads==2){NSMutableDictionary *changed=[original[global]mutableCopy];changed[@"__ORDER__"]=@1;value.records[global]=changed;}if(scenario==6)value.failSnapshot=YES;};
    uint64_t started=KuroMonotonicMilliseconds();BOOL recovered=[network recoverSession:session error:&error];uint64_t elapsed=KuroMonotonicMilliseconds()-started;
    if(recovered!=(scenario==0))fprintf(stderr,"recovery fixture scenario=%lu expected=%d actual=%d journalPreserved=%d error=%s\n",(unsigned long)scenario,scenario==0,recovered,Exists(journal),error.UTF8String);
    CHECK(recovered==(scenario==0));CHECK(dns.removals==1&&!Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
    if(scenario==0){CHECK(postRemovalReads==4&&elapsed>=20&&network.networkOff&&[dns.records isEqual:original]&&!Exists(journal));}
    else {
      NSArray *stages=@[@"",@"dns-derived-pending-timeout",@"dns-changed",@"dns-changed",@"route-owned-absence",@"route-read",@"dns-read",@"owner-exit",@"owner-binding",@"dns-retirement",@"dns-changed"];
      CHECK([error containsString:[@"stage="stringByAppendingString:stages[scenario]]]&&!network.networkOff&&Exists(journal));
      CHECK(![error containsString:@"private-service-marker"]&&![error containsString:@"private-domain-marker"]&&![error containsString:session]&&error.length<1024);
      if(scenario==1)CHECK(postRemovalReads>=2&&elapsed>=200);if(scenario==2||scenario==3||scenario==6)CHECK(postRemovalReads==1);if(scenario>=4&&scenario!=6&&scenario<9)CHECK(postRemovalReads==0);if(scenario==10)CHECK(postRemovalReads==2);if(scenario==9)CHECK(postRemovalReads==2&&[ReadProtected(directory,journal,geteuid(),NULL)isEqual:routeBytes]);
      printf("PASS recovery refusal scenario=%lu dnsReads=%lu: %s\n",(unsigned long)scenario,(unsigned long)postRemovalReads,error.UTF8String);
      // Explicit fixture restoration, never production repair of foreign DNS/routes.
      dns.onSnapshot=nil;dns.failSnapshot=NO;sync.refuseSync=NO;dns.records=[original mutableCopy];routes.failRead=NO;[routes.entries removeObject:extra];refuseExit=NO;if(scenario==8)Put(journal,routeBytes,0600);
      CHECK([network recoverSession:session error:&error]&&network.networkOff&&!Exists(journal));
    }
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 11 recovery readback cases: exact derived pending only, complete baseline retirement, foreign/read/owner refusal; fake OS backends only");
}

static void UnexpectedRouteEvidenceTests(void) {
  char temporary[]="/tmp/kuro-route-evidence-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<3;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    __block NSArray *interfaces=ProductionInterfaces(NO);__block NSUInteger probes=0;KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;probes++;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);
    CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    NSDictionary *extra=ProductionRoute(4,scenario==2?@"198.18.0.1":@"203.0.113.0",scenario==2?32:24,@"link",scenario==2?@"en1":@"utun7",scenario==2?3:7,RTF_UP);
    if(scenario==1){CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);}
    [routes.entries addObject:extra];BOOL accepted=scenario==1?[network confirmSession:session error:&error]:[network readyChild:association.process.pid session:session error:&error];CHECK(!accepted);
    CHECK([error containsString:@"unexpected route appeared"]&&[error containsString:scenario==1?@"phase=active verification":@"phase=Core startup"]&&[error containsString:@"owned-interface=utun7/7"]);
    NSRange marker=[error rangeOfString:@"observed="];CHECK(marker.location!=NSNotFound);NSData *encoded=[[error substringFromIndex:NSMaxRange(marker)]dataUsingEncoding:NSUTF8StringEncoding];CHECK(encoded.length<=1024);CHECK([KuroDecodeJSON(encoded,1024,NULL)isEqual:extra]);
    if(scenario==1)CHECK(dns.additions==1);else CHECK(!dns.additions&&!probes);
    [routes.entries removeObject:extra];ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);CHECK([network recoverSession:session error:&error]);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 3 unexpected-route diagnostic cases: exact closed entry and stage retained, original startup/active and wrong-interface refusal unchanged; fake backend only");
}

static void HeldMulticastCompanionTests(void) {
  char temporary[]="/tmp/kuro-multicast-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<15;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    __block NSArray *interfaces=ProductionInterfaces(NO);__block NSUInteger probes=0;KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface expected,NSString **failure){(void)expected;(void)failure;probes++;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);
    CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);
    NSDictionary *linklocal=@{@"family":@6,@"name":@"utun7",@"index":@7,@"flags":@(IFF_UP|IFF_RUNNING|IFF_POINTOPOINT),@"address":@"fe80::1234",@"prefix":@64};
    interfaces=[ProductionInterfaces(YES)arrayByAddingObject:linklocal];
    if(scenario==5)interfaces=ProductionInterfaces(YES);
    if(scenario==6)interfaces=[interfaces arrayByAddingObject:linklocal];
    if(scenario==11||scenario==12){NSMutableDictionary *changed=[linklocal mutableCopy];changed[scenario==11?@"index":@"prefix"]=scenario==11?@8:@128;interfaces=[ProductionInterfaces(YES)arrayByAddingObject:changed];}
    [routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    NSMutableArray *companions=[ProductionMulticastCompanions(association)mutableCopy];NSMutableDictionary *changed=[companions[0]mutableCopy];
    if(scenario==1)changed[@"flags"]=@([changed[@"flags"]unsignedIntValue]|RTF_STATIC);
    if(scenario==2)changed[@"destination"]=@"ff00::%8";
    if(scenario==3)changed[@"gateway"]=@"fe80::4321%7";
    if(scenario==4){changed[@"interfaceName"]=@"utun8";changed[@"interfaceIndex"]=@8;}
    if(scenario==7)changed[@"prefix"]=@16;
    if(scenario==8)changed[@"destination"]=@"ff03::%7";
    if(scenario==13)changed[@"gateway"]=@"fdfe:dcba:9876::1%7";
    companions[0]=changed;[routes.entries addObjectsFromArray:companions];
    if(scenario==10){NSMutableDictionary *baseline=[routes.entries[0]mutableCopy];baseline[@"gateway"]=@"192.168.1.2";routes.entries[0]=baseline;}
    BOOL accepted=[network readyChild:association.process.pid session:session error:&error];CHECK(accepted==(scenario==0||scenario==9||scenario==14));
    if(!accepted){CHECK(!dns.additions&&!probes);CHECK([error containsString:@"unexpected route"]||[error containsString:@"baseline changed"]||[error containsString:@"utun index/flags"]);continue;}
    CHECK([network applyChild:association.process.pid session:session error:&error]);CHECK([network confirmSession:session error:&error]);
    NSDictionary *journal=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),&error);CHECK(journal&&[journal[@"routes"]count]==5&&dns.additions==1);
    CHECK(![[[NSString alloc]initWithData:JSONData(journal) encoding:NSUTF8StringEncoding]containsString:@"ff00"]);
    if(scenario==9){NSMutableDictionary *newAddress=[linklocal mutableCopy];newAddress[@"address"]=@"fe80::4321";interfaces=[ProductionInterfaces(YES)arrayByAddingObject:newAddress];}
    if(scenario==14)interfaces=ProductionInterfaces(YES);
    if(scenario==9||scenario==14)CHECK(![network confirmSession:session error:&error]&&[error containsString:@"unexpected route"]);
    ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);CHECK([network recoverSession:session error:&error]&&network.networkOff&&dns.removals==1);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 15 held multicast cases: exact three XNU companion routes, independent unique current link-local, interface/zone/flags/prefix/gateway/active changes reject, baseline pinned and Core teardown simulated before absence-only retirement; snapshot-only route store");
}

static NSUInteger ProbeScenario,ProbeCloses,ProbeOpens,ProbeWaits;static int ProbeFamily;static NSData *ProbeQuestion;
static KuroFakeRouteStore *ProbeRouteBackend;static KuroCoreInterface ProbeAssociation;
static int ProbeSocket(int family,int kind,int protocol){CHECK(kind==SOCK_DGRAM&&!protocol);ProbeFamily=family;ProbeOpens++;if(ProbeScenario==1){errno=EPERM;return -1;}return 123;}
static int ProbeControl(int fd,int operation,int value){CHECK(fd==123);if((ProbeScenario==2&&operation==F_GETFL)||(ProbeScenario==3&&operation==F_SETFD)||(ProbeScenario==4&&operation==F_SETFL)){errno=EACCES;return -1;}CHECK(operation==F_GETFL||(operation==F_SETFD&&value==FD_CLOEXEC)||(operation==F_SETFL&&(value&O_NONBLOCK)));return 0;}
static int ProbeOption(int fd,int level,int option,const void *value,socklen_t size){CHECK(fd==123&&size==sizeof(unsigned int)&&*(const unsigned int *)value==7);CHECK(level==(ProbeFamily==AF_INET?IPPROTO_IP:IPPROTO_IPV6)&&option==(ProbeFamily==AF_INET?IP_BOUND_IF:IPV6_BOUND_IF));if(ProbeScenario==5){errno=EINVAL;return -1;}return 0;}
static int ProbeConnect(int fd,const struct sockaddr *address,socklen_t size){CHECK(fd==123);if(ProbeFamily==AF_INET){const struct sockaddr_in *v4=(const void *)address;CHECK(size==sizeof(*v4)&&v4->sin_port==htons(53)&&v4->sin_addr.s_addr==inet_addr("198.18.0.2"));}else{const struct sockaddr_in6 *v6=(const void *)address;struct in6_addr expected={0};CHECK(inet_pton(AF_INET6,"fdfe:dcba:9876::2",&expected)==1);CHECK(size==sizeof(*v6)&&v6->sin6_port==htons(53)&&!memcmp(&v6->sin6_addr,&expected,16));}if(ProbeScenario==6||(ProbeScenario==19&&ProbeFamily==AF_INET6)){errno=ENETUNREACH;return -1;}return 0;}
static ssize_t ProbeSend(int fd,const void *bytes,size_t length,int flags){CHECK(fd==123&&!flags);ProbeQuestion=[NSData dataWithBytes:bytes length:length];if(ProbeRouteBackend){NSString *endpoint=ProbeFamily==AF_INET?@"198.18.0.2":@"fdfe:dcba:9876::2";NSUInteger matches=0;for(NSDictionary *route in ProbeRouteBackend.entries)for(NSDictionary *target in KuroCoreAutoRouteCandidate(ProbeAssociation))if(KuroCoreAutoRouteEqual(route,target)&&KuroRouteContainsIP(route,endpoint))matches++;if(!matches){errno=EHOSTUNREACH;return -1;}}if(ProbeScenario==7){errno=EAGAIN;return -1;}if(ProbeScenario==8){errno=EIO;return (ssize_t)length-1;}return (ssize_t)length;}
static int ProbePoll(struct pollfd *ready,nfds_t count,int timeout){CHECK(count==1&&ready->fd==123&&ready->events==POLLIN&&timeout>0&&timeout<=400);ProbeWaits++;if(ProbeScenario==9){errno=EIO;return -1;}if(ProbeScenario==10){errno=EIO;return 0;}if(ProbeScenario==11){ready->revents=POLLHUP;return 1;}if(ProbeScenario==20&&ProbeWaits==1){errno=EINTR;return -1;}ready->revents=POLLIN;return 1;}
static ssize_t ProbeReceive(int fd,void *bytes,size_t length,int flags){CHECK(fd==123&&length==513&&!flags);if(ProbeScenario==12){errno=ECONNREFUSED;return -1;}if(ProbeScenario==13){errno=EIO;return 0;}NSMutableData *answer=[ReadinessReply(ProbeQuestion,ProbeFamily==AF_INET6)mutableCopy];if(ProbeScenario==14)answer=[NSMutableData dataWithLength:5];if(ProbeScenario==15)answer=[NSMutableData dataWithLength:513];if(ProbeScenario==16)((unsigned char *)answer.mutableBytes)[3]=3;if(ProbeScenario==17)((unsigned char *)answer.mutableBytes)[0]^=1;if(ProbeScenario==18)((unsigned char *)answer.mutableBytes)[answer.length-1]^=1;if(ProbeScenario==21)((unsigned char *)answer.mutableBytes)[13]^=1;memcpy(bytes,answer.bytes,answer.length);return (ssize_t)answer.length;}
static int ProbeClose(int fd){CHECK(fd==123);ProbeCloses++;errno=EBADF;return -1;}
static void InternalDNSProbeDiagnosticTests(void){
  const KuroDNSProbeIO io={ProbeSocket,ProbeControl,ProbeOption,ProbeConnect,ProbeSend,ProbePoll,ProbeReceive,ProbeClose};
  NSArray *stages=@[@"",@"socket",@"fcntl-getfl",@"fcntl-cloexec",@"fcntl-nonblock",@"setsockopt-bound-interface",@"connect",@"send",@"send",@"poll",@"poll",@"poll",@"recv",@"recv",@"response-validation",@"response-validation",@"response-validation",@"response-validation",@"response-validation",@"connect",@"",@"response-validation"];
  for(ProbeScenario=0;ProbeScenario<stages.count;ProbeScenario++){
    ProbeCloses=ProbeOpens=ProbeWaits=0;ProbeQuestion=nil;NSString *error=nil;BOOL ok=KuroProbeInternalDNSWithIO(RouteFixtureInterface(),&error,&io);
    CHECK(ok==(ProbeScenario==0||ProbeScenario==20));CHECK(ProbeCloses==(ProbeScenario==1?0:ProbeScenario==0||ProbeScenario==19||ProbeScenario==20?2:1));
    if(ok){CHECK(!error&&ProbeOpens==2);continue;}CHECK([error containsString:[@"stage="stringByAppendingString:stages[ProbeScenario]]]);CHECK([error containsString:ProbeScenario==19?@"IPv6":@"IPv4"]);CHECK(error.length<400&&![error containsString:KuroReadinessDomain]);
    int expected=ProbeScenario==1?EPERM:ProbeScenario>=2&&ProbeScenario<=4?EACCES:ProbeScenario==5?EINVAL:ProbeScenario==6||ProbeScenario==19?ENETUNREACH:ProbeScenario==7?EAGAIN:ProbeScenario==9?EIO:ProbeScenario==12?ECONNREFUSED:0;
    CHECK(([error containsString:[NSString stringWithFormat:@"errno=%d;",expected]]));if(ProbeScenario==11)CHECK([error containsString:@"revents=0x10;"]);
    if(ProbeScenario==14)CHECK([error containsString:@"reason=short-header"]);if(ProbeScenario==15)CHECK([error containsString:@"received=513;"]&&[error containsString:@"reason=oversized-datagram"]);
    if(ProbeScenario==16)CHECK([error containsString:@"reason=response-rcode"]);if(ProbeScenario==17)CHECK([error containsString:@"reason=transaction-id"]);if(ProbeScenario==18)CHECK([error containsString:@"reason=fixed-answer-record-or-address"]);if(ProbeScenario==21)CHECK([error containsString:@"reason=fixed-question-mismatch"]);
    NSRange start=[error rangeOfString:@"header="];NSRange end=[error rangeOfString:@"; reason="];CHECK(start.location!=NSNotFound&&end.location!=NSNotFound&&end.location-NSMaxRange(start)<=24);
  }
  ProbeQuestion=nil;puts("PASS internal DNS probe diagnostics: real control flow with injected socket/fcntl/bind/connect/send/poll/recv/response failures, exact errno survives close, short/timeout uses no stale errno, EINTR and both-family success; no real network operations");
}


static void ProductionAutoRouteTests(void) {
  char tmp[]="/tmp/kuro-auto-network-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(tmp)&&realpath(tmp,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  const KuroDNSProbeIO io={ProbeSocket,ProbeControl,ProbeOption,ProbeConnect,ProbeSend,ProbePoll,ProbeReceive,ProbeClose};
  for(NSUInteger scenario=0;scenario<23;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"s%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[ProductionBaseline()mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];NSDictionary *baselineDNS=[dns.records copy];
    __block NSArray *interfaces=ProductionInterfaces(NO);__block KuroRouteOwnerState owner=KuroRouteOwnerLive;__block NSUInteger probes=0;
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];environment.interfaces=^NSArray *(NSString **e){(void)e;return interfaces;};environment.observeChild=^BOOL(pid_t pid,KuroCoreInterface *a,NSString **e){(void)e;CHECK(pid==association.process.pid);*a=association;return YES;};environment.ownership=^KuroRouteOwnerState(KuroCoreInterface a,NSString **e){(void)a;(void)e;return owner;};
    environment.probeDNS=^BOOL(KuroCoreInterface a,NSString **e){probes++;ProbeRouteBackend=routes;ProbeAssociation=a;ProbeScenario=scenario==4?12:0;ProbeCloses=ProbeOpens=ProbeWaits=0;BOOL ok=KuroProbeInternalDNSWithIO(a,e,&io);ProbeRouteBackend=nil;return ok;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);
    if(scenario==1){CHECK(![network readyChild:association.process.pid session:session error:&error]&&!probes&&!dns.additions);continue;}
    if(scenario==2){[routes.entries addObject:ProductionRoute(4,@"203.0.113.0",24,@"link",@"en0",2,RTF_UP)];CHECK(![network prepareSession:session binding:ProductionBinding(association) error:&error]&&!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));continue;}
    KuroPrepareSyncFailure *sync=nil;if(scenario==3){sync=[[KuroPrepareSyncFailure alloc]initWithDirectory:directory owner:geteuid() backend:routes];sync.failSync=YES;[network setValue:sync forKey:@"routes"];}
    BOOL prepared=[network prepareSession:session binding:ProductionBinding(association) error:&error];
    if(scenario==3){CHECK(!prepared&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal])&&!dns.additions);sync.failSync=NO;owner=KuroRouteOwnerExitedInterfaceGone;CHECK([network recoverSession:session error:&error]&&network.networkOff);continue;}CHECK(prepared);
    NSDictionary *intent=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),NULL);CHECK([intent[@"phase"]isEqual:@"prepared"]&&[intent[@"binding"]isEqual:ProductionBinding(association)]&&[intent[@"baselineDNS"]isEqual:baselineDNS]);
    if(scenario==5){owner=KuroRouteOwnerExitedInterfaceGone;CHECK([network recoverSession:session error:&error]&&network.networkOff&&!dns.additions);continue;}
    interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    if(scenario==6)[routes.entries removeObjectAtIndex:ProductionBaseline().count];
    if(scenario==22){
      NSDictionary *late=routes.entries[ProductionBaseline().count];[routes.entries removeObjectAtIndex:ProductionBaseline().count];__block NSUInteger pendingReads=0;
      routes.onSnapshot=^(KuroFakeRouteStore *store){if(++pendingReads<3){NSDictionary *record=ReadJSON(directory,[directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),NULL);CHECK([record[@"phase"]isEqual:@"prepared"]&&!dns.additions);}else if(pendingReads==3)[store.entries addObject:late];};
    }
    if(scenario==7){NSMutableDictionary *changed=[routes.entries[ProductionBaseline().count]mutableCopy];changed[@"gateway"]=@"198.18.0.2";routes.entries[ProductionBaseline().count]=changed;}
    if(scenario==8)[routes.entries addObject:routes.entries[ProductionBaseline().count]];
    if(scenario==9)[routes.entries addObject:ProductionRoute(4,@"203.0.113.0",24,@"link",@"utun7",7,RTF_UP)];
    if(scenario==10)owner=KuroRouteOwnerUnknown;
    BOOL ready=[network readyChild:association.process.pid session:session error:&error];CHECK(ready==!(scenario==4||(scenario>=6&&scenario<=10)));
    if(!ready){CHECK(!dns.additions&&![network applyChild:association.process.pid session:session error:NULL]);if(scenario!=4)CHECK(!probes);CHECK(![network recoverSession:session error:NULL]&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));owner=KuroRouteOwnerExitedInterfaceGone;interfaces=ProductionInterfaces(NO);ProductionCoreGone(routes);CHECK([network recoverSession:session error:&error]&&network.networkOff);continue;}
    routes.onSnapshot=nil;
    CHECK(probes&&![network readyChild:association.process.pid session:session error:NULL]&&!dns.additions);
    if(scenario==11){ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);owner=KuroRouteOwnerExitedInterfaceGone;CHECK([network recoverSession:session error:&error]&&network.networkOff&&!dns.additions);continue;}
    if(scenario==12){dns.failAdd=dns.addThenFail=YES;}
    if(scenario==13){NSMutableDictionary *changed=[routes.entries[0]mutableCopy];changed[@"gateway"]=@"192.168.1.2";routes.entries[0]=changed;}
    BOOL applied=[network applyChild:association.process.pid session:session error:&error];CHECK(applied==(scenario!=12&&scenario!=13));
    if(applied)CHECK([network confirmSession:session error:&error]);
    if(scenario==14){NSMutableDictionary *changed=[dns.records[@"State:/Network/Global/DNS"]mutableCopy];changed[@"__ORDER__"]=@1;dns.records[@"State:/Network/Global/DNS"]=changed;CHECK(![network confirmSession:session error:&error]);dns.records[@"State:/Network/Global/DNS"]=baselineDNS[@"State:/Network/Global/DNS"];}
    NSDictionary *recordedOwner=ProductionOwner(session,association);Put([directory stringByAppendingPathComponent:@"owner.json"],JSONData(recordedOwner),0600);
    if(scenario>=15&&scenario<=20){
      KuroProductionNetwork *fresh=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];CHECK(![fresh recoverSession:nil error:NULL]&&!fresh.networkOff&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
      ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);owner=KuroRouteOwnerExitedInterfaceGone;
      if(scenario>=16){NSMutableDictionary *changed=[recordedOwner mutableCopy],*launch=[changed[@"launch"]mutableCopy];if(scenario==16)launch[@"configSHA256"]=Hash(Bytes(@"other"));if(scenario==17)launch[@"runtimeSHA256"]=Hash(Bytes(@"other"));if(scenario==18){launch[@"coreSHA256"]=Hash(Bytes(@"other"));changed[@"executableSHA256"]=launch[@"coreSHA256"];}if(scenario==19)changed[@"startMicros"]=@999;if(scenario==20)changed[@"session"]=@"11112233-4455-6677-8899-AABBCCDDEEFF";changed[@"launch"]=launch;Put([directory stringByAppendingPathComponent:@"owner.json"],JSONData(changed),0600);CHECK(![fresh recoverRecordedOwner:changed writerAbsent:^BOOL(NSString **failure){(void)failure;return YES;} error:NULL]&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));Put([directory stringByAppendingPathComponent:@"owner.json"],JSONData(recordedOwner),0600);}
      CHECK(![fresh recoverRecordedOwner:recordedOwner error:NULL]&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
      CHECK(![fresh recoverRecordedOwner:recordedOwner writerAbsent:^BOOL(NSString **failure){return Fail(failure,@"fixture writer proof unavailable");} error:NULL]&&Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
      CHECK([fresh recoverRecordedOwner:recordedOwner writerAbsent:^BOOL(NSString **failure){(void)failure;return owner==KuroRouteOwnerExitedInterfaceGone;} error:&error]&&fresh.networkOff&&![fresh stoppedEvidenceForSession:session error:NULL]);continue;
    }
    CHECK(![network recoverSession:@"11112233-4455-6677-8899-AABBCCDDEEFF" error:NULL]);
    ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);owner=KuroRouteOwnerExitedInterfaceGone;if(scenario==13)routes.entries=[ProductionBaseline()mutableCopy];
    CHECK([network recoverSession:session error:&error]&&network.networkOff&&[dns.records isEqual:baselineDNS]);CHECK([network stoppedEvidenceForSession:session error:&error]);CHECK(!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));
    if(scenario==21){
      KuroProductionNetwork *fresh=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:RecoveryFixtureEnvironment()];
      NSMutableDictionary *changed=[recordedOwner mutableCopy];changed[@"startMicros"]=@999;Put([directory stringByAppendingPathComponent:@"owner.json"],JSONData(changed),0600);CHECK(![fresh recoverRecordedOwner:recordedOwner error:NULL]);
      CHECK(!unlink([directory stringByAppendingPathComponent:@"owner.json"].fileSystemRepresentation));CHECK([fresh recoverRecordedOwner:recordedOwner error:&error]&&fresh.networkOff);
    }
  }
  ProbeRouteBackend=nil;ProbeQuestion=nil;CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 23 Core auto-route coordinator cases (including delayed complete route observation within original readiness deadline): protected pre-CONT intent/binding/baseline, independently observed five upstream routes, original dual-stack probe, DNS-only helper writes, partial startup/prepare-sync recovery and full-owner restart joins; simulated Core/kernel, no system calls");
}
static void ProductionRouteBaselineDifferenceTests(void) {
  char temporary[]="/tmp/kuro-route-diff-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<5;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    NSDictionary *old=ProductionRoute(4,@"192.168.1.61",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC),*changed=ProductionRoute(4,@"192.168.1.132",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[[ProductionBaseline()arrayByAddingObject:old]mutableCopy];NSArray *original=[routes.entries copy];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;__block NSArray *interfaces=ProductionInterfaces(NO);KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];
    environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *result,NSString **failure){(void)failure;CHECK(child==association.process.pid);*result=association;return YES;};
    environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return interfaces.count==ProductionInterfaces(NO).count?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];
    CHECK([network preflightConfig:ProductionConfig() error:&error]);CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    if(scenario){CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);if(scenario!=4){ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);}}
    if(scenario<2||scenario==4){[routes.entries removeObject:old];[routes.entries insertObject:changed atIndex:0];}
    if(scenario==2)[routes.entries addObject:changed];if(scenario==3)[routes.entries addObject:old];
    NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];NSData *record=ReadProtected(directory,journal,geteuid(),NULL);NSArray *mutated=[routes.entries copy];
    BOOL accepted=scenario==4?[network confirmSession:session error:&error]:scenario?[network recoverSession:session error:&error]:[network readyChild:association.process.pid session:session error:&error];
    if(scenario>0&&scenario<4) {
      CHECK(accepted&&network.networkOff&&!Exists(journal)&&[routes.entries isEqual:mutated]);
      NSDictionary *observation=network.recoveryObservation;CHECK([observation[@"kind"]isEqual:@"current-owned-absence"]&&[observation[@"systemRouteBaselineRestored"]isEqual:@NO]);
      error=observation[@"routeDifference"];
    } else CHECK(!accepted);
    printf("route baseline observation scenario=%lu: %s\n",(unsigned long)scenario,error.UTF8String);fflush(stdout);
    CHECK([error hasPrefix:scenario>0&&scenario<4?@"routeDiff=":@"route baseline changed; preserve all existing routing"]);
    if(scenario==0||scenario==4)CHECK(([error containsString:[NSString stringWithFormat:@"dnsPublished=%d",scenario==4]]));
    NSRange marker=[error rangeOfString:@"routeDiff="];CHECK(marker.location!=NSNotFound);NSData *encoded=[[error substringFromIndex:NSMaxRange(marker)]dataUsingEncoding:NSUTF8StringEncoding];CHECK(encoded.length<=768&&error.length<1024);
    NSDictionary *difference=KuroDecodeJSON(encoded,768,NULL);CHECK([difference[@"missing"]isEqual:scenario<2||scenario==4?@1:@0]&&[difference[@"examplesOmitted"]isEqual:@NO]);
    CHECK([difference[@"firstMissing"]isEqual:scenario<2||scenario==4?old:NSNull.null]);CHECK([difference[@"firstUnmatched"]isEqual:scenario==3?old:changed]);
    CHECK([routes.entries isEqual:mutated]);
    if(scenario==0||scenario==4)CHECK(!network.networkOff&&Exists(journal));
    if(scenario==4)CHECK([ReadProtected(directory,journal,geteuid(),NULL)isEqual:record]);
    else if(scenario==0)CHECK([ReadJSON(directory,journal,geteuid(),NULL)[@"baselineRoutes"]isEqual:original]);
    // Explicit fake OS restoration only; production never rewrites en0 routes.
    routes.entries=[original mutableCopy];interfaces=ProductionInterfaces(NO);CHECK([network recoverSession:session error:&error]&&network.networkOff&&!Exists(journal));
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}

static void ProductionOwnRouteAbsenceTests(void) {
  char temporary[]="/tmp/kuro-own-absence-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for(NSUInteger scenario=0;scenario<13;scenario++) {
    BOOL fresh=scenario==1||scenario>=9;NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    NSDictionary *old=ProductionRoute(4,@"192.168.1.61",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC),*replacement=ProductionRoute(4,@"192.168.1.132",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[[ProductionBaseline()arrayByAddingObject:old]mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    __block NSArray *interfaces=ProductionInterfaces(NO);__block KuroRouteOwnerState owner=KuroRouteOwnerLive;__block BOOL interfaceReadFail=NO,writerGone=YES;__block NSUInteger interfaceReads=0;
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];environment.interfaces=^NSArray *(NSString **failure){interfaceReads++;if(interfaceReadFail){Fail(failure,@"injected interface read denial");return nil;}return interfaces;};
    environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *value,NSString **failure){(void)child;(void)failure;*value=association;return YES;};environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return owner;};environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return YES;};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionInterfaces(YES);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];CHECK([network readyChild:association.process.pid session:session error:&error]);CHECK([network applyChild:association.process.pid session:session error:&error]);
    ProductionCoreGone(routes);interfaces=ProductionInterfaces(NO);owner=KuroRouteOwnerExitedInterfaceGone;if(scenario!=12){[routes.entries removeObject:old];[routes.entries addObject:replacement];}
    NSMutableDictionary *extra=[ProductionRoute(4,@"203.0.113.1",32,@"link",@"en0",2,RTF_UP)mutableCopy];
    if(scenario==2||scenario==3){extra=[ObservedRoute(KuroCoreAutoRouteCandidate(association)[0])mutableCopy];if(scenario==3){extra[@"gateway"]=@"192.0.2.1";extra[@"flags"]=@0;}}
    if(scenario==4){extra[@"destination"]=@"198.18.0.2";extra[@"flags"]=@(RTF_UP|RTF_HOST|RTF_LLINFO);}
    if(scenario==5)extra[@"interfaceName"]=@"utun7";if(scenario==6)extra[@"interfaceIndex"]=@7;if(scenario==7)extra[@"flags"]=@(RTF_UP|RTF_PROTO2);
    if(scenario>=2&&scenario<=7)[routes.entries addObject:extra];if(scenario==8)owner=KuroRouteOwnerUnknown;
    if(scenario==9)interfaces=ProductionInterfaces(YES);if(scenario==10)interfaceReadFail=YES;if(scenario==11)writerGone=NO;
    NSDictionary *recordedOwner=ProductionOwner(session,association);NSString *journal=[directory stringByAppendingPathComponent:KuroRouteJournal];NSData *recordBytes=ReadProtected(directory,journal,geteuid(),NULL);NSArray *unchanged=[routes.entries copy];
    if(fresh){Put([directory stringByAppendingPathComponent:@"owner.json"],JSONData(recordedOwner),0600);network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];}
    interfaceReads=0;__block NSUInteger writerChecks=0;KuroSessionHook writer=^BOOL(NSString **failure){writerChecks++;return writerGone||Fail(failure,@"injected writer not absent");};
    BOOL accepted=fresh?[network recoverRecordedOwner:recordedOwner writerAbsent:writer error:&error]!=nil:[network recoverSession:session error:&error];BOOL expected=scenario<2||scenario==12;
    if(accepted!=expected)fprintf(stderr,"ownabsence case=%lu expected=%d actual=%d error=%s\n",(unsigned long)scenario,expected,accepted,error.UTF8String);CHECK(accepted==expected&&[routes.entries isEqual:unchanged]);
    if(expected){CHECK(network.networkOff&&!Exists(journal));NSDictionary *report=network.recoveryObservation;CHECK([report[@"kind"]isEqual:@"current-owned-absence"]&&[report[@"systemRouteBaselineRestored"]isEqual:@(scenario==12)]&&(scenario==12?[report[@"routeDifference"]isEqual:@""]:[report[@"routeDifference"]hasPrefix:@"routeDiff="])&&[report[@"routeDifference"]length]<1024);if(fresh){CHECK(writerChecks>=4&&interfaceReads>=3);NSDictionary *again=[network recoverRecordedOwner:recordedOwner writerAbsent:writer error:&error];CHECK(again&&[network.recoveryObservation isEqual:report]&&!Exists(journal));}else CHECK([network stoppedEvidenceForSession:session error:NULL]);}
    else {CHECK(!network.networkOff&&!network.recoveryObservation&&[ReadProtected(directory,journal,geteuid(),NULL)isEqual:recordBytes]);
      [routes.entries removeObject:extra];interfaces=ProductionInterfaces(NO);owner=KuroRouteOwnerExitedInterfaceGone;interfaceReadFail=NO;writerGone=YES;
      CHECK(fresh?[network recoverRecordedOwner:recordedOwner writerAbsent:writer error:&error]!=nil:[network recoverSession:session error:&error]);}
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);puts("PASS 13 held/fresh own-route-absence coordinator cases: external change preserved/reported, own keys/pool/utun/marked/unknown owner/interface/writer rejected before retirement; fake backends only");
}

// Anonymous actual Darwin snapshot shapes: Ethernet local /32 is
// UP|STATIC|CLONING with gateway=link (not necessarily HOST); scoped IPv6
// multicast/link-local parents have separate interface/address evidence.
static NSArray *ProductionLocalInterfaces(BOOL tun,NSString *address,BOOL auxiliary) {
  NSMutableArray *result=[NSMutableArray array];
  for (NSDictionary *entry in ProductionInterfaces(tun)) {
    if ([entry[@"family"]isEqual:@4] && [entry[@"name"]isEqual:@"en0"]) { NSMutableDictionary *value=[entry mutableCopy];value[@"address"]=address;[result addObject:value]; }
    else [result addObject:entry];
  }
  if (auxiliary) [result addObjectsFromArray:@[
    @{@"family":@0,@"name":@"en8",@"index":@8,@"flags":@(IFF_UP|IFF_RUNNING),@"linkType":@(IFT_ETHER)},
    @{@"family":@4,@"name":@"en8",@"index":@8,@"flags":@(IFF_UP|IFF_RUNNING),@"address":@"169.254.7.12",@"prefix":@16},
    @{@"family":@6,@"name":@"en8",@"index":@8,@"flags":@(IFF_UP|IFF_RUNNING),@"address":@"fe80::1234",@"prefix":@64}]];
  return result;
}
static NSArray *ProductionLocalRoutes(BOOL ipv6) {
  if (!ipv6) return @[ProductionRoute(4,@"169.254.0.0",16,@"link",@"en8",8,RTF_UP|RTF_STATIC|RTF_CLONING),ProductionRoute(4,@"169.254.7.12",32,@"link",@"en8",8,RTF_UP|RTF_STATIC|RTF_CLONING)];
  NSMutableArray *routes=[@[ProductionRoute(6,@"fe80::%8",64,@"link",@"en8",8,RTF_UP|RTF_CLONING|RTF_IFSCOPE)]mutableCopy];
  for (NSArray *entry in @[@[@"ff00::%8",@8],@[@"ff01::%8",@32],@[@"ff02::%8",@32]]) [routes addObject:ProductionRoute(6,entry[0],[entry[1]intValue],@"link",@"en8",8,RTF_UP|RTF_CLONING|RTF_IFSCOPE|RTF_MULTICAST)];
  return routes;
}
static void ProductionLocalRouteChangeTests(void) {
  char temporary[]="/tmp/kuro-local-routes-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*session=@"00112233-4455-6677-8899-AABBCCDDEEFF";KuroCoreInterface association=RouteFixtureInterface();
  for (NSUInteger scenario=0;scenario<25;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]],*error=nil;FixtureDirectory(directory);
    NSDictionary *old=ProductionRoute(4,@"192.168.1.61",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC),*changed=ProductionRoute(4,@"192.168.1.132",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[[ProductionBaseline()arrayByAddingObject:old]mutableCopy];
    if(scenario==14)[routes.entries addObjectsFromArray:ProductionLocalRoutes(YES)];
    KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;dns.records=[DarwinDNSMetadataFixture()mutableCopy];NSDictionary *originalDNS=[dns.records copy];
    __block NSArray *interfaces=ProductionLocalInterfaces(NO,scenario==2?@"192.168.1.10":@"192.168.1.61",scenario==14);__block KuroRouteOwnerState owner=KuroRouteOwnerLive;__block BOOL probe=YES;
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *value,NSString **failure){(void)failure;CHECK(child==association.process.pid);*value=association;return YES;};environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return owner;};environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **failure){(void)value;return probe || Fail(failure,@"controlled probe failure");};
    KuroProductionNetwork *network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];CHECK([network preflightConfig:ProductionConfig() error:&error]);
    if(scenario==23){[routes.entries removeObject:old];[routes.entries addObject:changed];interfaces=ProductionLocalInterfaces(NO,@"192.168.1.132",NO);CHECK(![network prepareSession:session binding:ProductionBinding(association) error:&error]&&[error containsString:@"before Core resume"]&&!Exists([directory stringByAppendingPathComponent:KuroRouteJournal]));continue;}
    CHECK([network prepareSession:session binding:ProductionBinding(association) error:&error]);interfaces=ProductionLocalInterfaces(YES,scenario==2?@"192.168.1.10":@"192.168.1.61",scenario==14);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];
    if(!scenario){[routes.entries removeObject:old];[routes.entries addObject:changed];interfaces=ProductionLocalInterfaces(YES,@"192.168.1.132",NO);}
    BOOL ready=[network readyChild:association.process.pid session:session error:&error];if(!ready)fprintf(stderr,"local readiness scenario=%lu refused: %s\n",(unsigned long)scenario,error.UTF8String?:"none");CHECK(ready);CHECK([network applyChild:association.process.pid session:session error:&error]);
    NSData *journal=ReadProtected(directory,[directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),NULL);
    if(scenario==1||scenario==2||scenario==3||scenario==4||scenario==5||scenario==6){[routes.entries removeObject:old];[routes.entries addObject:changed];if(scenario!=3)interfaces=ProductionLocalInterfaces(YES,@"192.168.1.132",NO);}
    if(scenario==4){NSMutableArray *bad=[interfaces mutableCopy];NSMutableDictionary *entry=[bad[1]mutableCopy];entry[@"index"]=@9;bad[1]=entry;interfaces=bad;}
    if(scenario==5||scenario==6){NSMutableDictionary *entry=[changed mutableCopy];entry[scenario==5?@"flags":@"gateway"]=scenario==5?@(RTF_UP|RTF_STATIC|RTF_CLONING|RTF_BLACKHOLE):@"192.168.1.1";[routes.entries removeObject:changed];[routes.entries addObject:entry];}
    if(scenario==7){NSMutableDictionary *entry=[routes.entries[0]mutableCopy];entry[@"gateway"]=@"192.168.1.2";routes.entries[0]=entry;}
    if(scenario==8||scenario==9){NSMutableArray *bad=[interfaces mutableCopy];NSMutableDictionary *entry=[bad[0]mutableCopy];entry[scenario==8?@"index":@"flags"]=scenario==8?@9:@0;bad[0]=entry;interfaces=bad;}
    if(scenario==10)[routes.entries removeObject:ProductionBaseline()[2]];
    if(scenario==11){[routes.entries addObject:ProductionRoute(4,@"192.168.1.1",32,@"link",@"en0",2,RTF_UP|RTF_STATIC|RTF_CLONING)];interfaces=ProductionLocalInterfaces(YES,@"192.168.1.1",NO);}
    if(scenario==12||scenario==13||scenario==15){interfaces=ProductionLocalInterfaces(YES,@"192.168.1.61",YES);[routes.entries addObjectsFromArray:ProductionLocalRoutes(scenario!=12)];if(scenario==15)[routes.entries addObject:ProductionRoute(6,@"ff00::%9",8,@"link",@"en8",8,RTF_UP|RTF_CLONING|RTF_IFSCOPE|RTF_MULTICAST)];}
    if(scenario==14){[routes.entries removeObjectsInArray:ProductionLocalRoutes(YES)];interfaces=ProductionLocalInterfaces(YES,@"192.168.1.61",NO);}
    if(scenario==16)[routes.entries addObject:ProductionRoute(4,@"203.0.113.0",24,@"link",@"en8",8,RTF_UP)];
    if(scenario==17){NSMutableDictionary *entry=[routes.entries[ProductionBaseline().count+1]mutableCopy];entry[@"gateway"]=@"198.18.0.2";routes.entries[ProductionBaseline().count+1]=entry;}
    if(scenario==18)[routes.entries removeObject:ObservedRoute(KuroCoreAutoRouteCandidate(association)[0])];
    if(scenario==19){NSMutableDictionary *entry=[dns.records[@"State:/Network/Global/DNS"]mutableCopy];entry[@"__ORDER__"]=@1;dns.records[@"State:/Network/Global/DNS"]=entry;}
    if(scenario==20)owner=KuroRouteOwnerUnknown;if(scenario==21)probe=NO;
    if(scenario==22)[routes.entries addObjectsFromArray:@[changed,changed]];
    if(scenario==24)interfaces=[interfaces arrayByAddingObject:@{@"family":@4,@"name":@"en8",@"index":@8,@"flags":@(IFF_UP|IFF_RUNNING),@"address":@"198.18.0.2",@"prefix":@32}];
    NSArray *before=[routes.entries copy];BOOL accepted=[network confirmSession:session error:&error];BOOL expected=scenario==0||scenario==1||scenario==12||scenario==13||scenario==14;
    if(accepted!=expected)fprintf(stderr,"local route scenario=%lu accepted=%d expected=%d error=%s\n",(unsigned long)scenario,accepted,expected,error.UTF8String?:"none");CHECK(accepted==expected);CHECK([routes.entries isEqual:before]&&[ReadProtected(directory,[directory stringByAppendingPathComponent:KuroRouteJournal],geteuid(),NULL)isEqual:journal]&&dns.additions==1&&!dns.removals);
    if(!expected)CHECK(error.length);owner=KuroRouteOwnerExitedInterfaceGone;probe=YES;ProductionCoreGone(routes);interfaces=ProductionLocalInterfaces(NO,@"192.168.1.132",NO);dns.records=[originalDNS mutableCopy];dns.records[KuroDNSKey(session)]=KuroDNSValue();CHECK([network recoverSession:session error:&error]&&network.networkOff&&dns.removals==1);
    printf("PASS local route dynamics scenario=%lu accepted=%d\n",(unsigned long)scenario,accepted);
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}

// Existing harmless-child transport fixture is defined later in the shared TU.
static KuroTunServiceHooks *ServiceHooks(void);
static NSDictionary *ServiceRead(int peer);
static void ServiceSend(int peer,NSDictionary *value);
static void ServiceWait(dispatch_semaphore_t event);
static void ProductionLocalRouteServiceTests(void) {
  for(NSUInteger scenario=0;scenario<2;scenario++) {
    char temporary[]="/tmp/klrs-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *directory=@(canonical),*core=[directory stringByAppendingPathComponent:@"child"],*error=nil;Put(core,[NSData dataWithContentsOfFile:Executable()],0755);
    NSDictionary *old=ProductionRoute(4,@"192.168.1.61",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC),*replacement=ProductionRoute(4,@"192.168.1.132",32,@"link",@"en0",2,RTF_UP|RTF_CLONING|RTF_STATIC);
    KuroFakeRouteStore *routes=[KuroFakeRouteStore new];routes.directory=directory;routes.entries=[[ProductionBaseline()arrayByAddingObject:old]mutableCopy];KuroFakeDNSStore *dns=[KuroFakeDNSStore new];dns.directory=directory;
    __block NSArray *interfaces=ProductionLocalInterfaces(NO,@"192.168.1.61",NO);__block KuroCoreInterface association=RouteFixtureInterface();__block KuroProductionNetwork *network=nil;__block BOOL reaped=NO;__block NSUInteger checks=0,proofs=0;
    KuroNetworkEnvironment *environment=[KuroNetworkEnvironment new];environment.interfaces=^NSArray *(NSString **failure){(void)failure;return interfaces;};environment.observeChild=^BOOL(pid_t child,KuroCoreInterface *value,NSString **failure){(void)failure;CHECK(child==association.process.pid);*value=association;return YES;};environment.ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return reaped?KuroRouteOwnerExitedInterfaceGone:KuroRouteOwnerLive;};environment.probeDNS=^BOOL(KuroCoreInterface value,NSString **failure){(void)value;(void)failure;return YES;};
    KuroTunServiceHooks *hooks=ServiceHooks();
    hooks.preflight=^BOOL(NSDictionary *config,NSString **failure){network=[[KuroProductionNetwork alloc]initWithDirectory:directory owner:geteuid() routes:routes dns:dns environment:environment];return [network preflightConfig:config error:failure];};
    hooks.prepareNetwork=^BOOL(NSString *session,NSDictionary *binding,NSString **failure){association.process.pid=[binding[@"process"][@"pid"]intValue];association.process.startSeconds=[binding[@"process"][@"startSeconds"]unsignedLongLongValue];association.process.startMicros=[binding[@"process"][@"startMicros"]unsignedIntValue];return [network prepareSession:session binding:binding error:failure];};
    hooks.ready=^BOOL(pid_t child,NSString *session,NSString **failure){struct proc_bsdinfo info={0};CHECK(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&info.pbi_ppid==(uint32_t)getpid());interfaces=ProductionLocalInterfaces(YES,@"192.168.1.61",NO);[routes.entries addObjectsFromArray:ProductionCoreRoutes(association)];return [network readyChild:child session:session error:failure];};
    hooks.applyNetwork=^BOOL(pid_t child,NSString *session,NSString **failure){if(![network applyChild:child session:session error:failure])return NO;[routes.entries removeObject:old];[routes.entries addObject:replacement];interfaces=ProductionLocalInterfaces(YES,@"192.168.1.132",NO);if(scenario){NSMutableDictionary *changed=[routes.entries[0]mutableCopy];changed[@"gateway"]=@"192.168.1.2";routes.entries[0]=changed;}return YES;};
    hooks.verifyNetwork=^BOOL(NSString *session,NSString **failure){checks++;return [network confirmSession:session error:failure];};
    hooks.recoverNetwork=^BOOL(NSString *session,NSString **failure){errno=0;CHECK(waitpid(association.process.pid,NULL,WNOHANG)==-1&&errno==ECHILD);reaped=YES;ProductionCoreGone(routes);interfaces=ProductionLocalInterfaces(NO,@"192.168.1.132",NO);return [network recoverSession:session error:failure];};
    hooks.confirmStopped=^BOOL(NSDictionary *proof,NSString **failure){CHECK(KuroCompletedStopEvidence(proof));proofs++;return [network stoppedEvidenceForSession:proof[@"session"] error:failure]!=nil;};
    KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:core hooks:hooks];__weak KuroTunService *weak=service;service.fixtureRetained=^{[weak requestShutdown];};
    int peers[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,peers));int peer=peers[0];dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL result=NO;__block NSString *failure=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{NSString *problem=nil;result=[service serveOpenFrame:JSONData(@{@"version":@2,@"operation":@"open",@"config":ProductionConfig()}) peer:peer error:&problem];failure=problem;close(peer);dispatch_semaphore_signal(done);});
    NSDictionary *opened=ServiceRead(peers[1]);if(![opened[@"ok"]boolValue])fprintf(stderr,"local service startup: %s\n",opened.description.UTF8String);CHECK([opened[@"ok"]boolValue]&&[opened[@"status"][@"state"]isEqual:@"on"]);
    if(!scenario){ServiceSend(peers[1],@{@"version":@2,@"operation":@"heartbeat",@"session":opened[@"session"],@"sequence":@1});CHECK([ServiceRead(peers[1])[@"ok"]boolValue]);ServiceSend(peers[1],@{@"version":@2,@"operation":@"stop",@"session":opened[@"session"],@"sequence":@2});CHECK([ServiceRead(peers[1])[@"ok"]boolValue]);}
    ServiceWait(done);close(peers[1]);CHECK(checks&&reaped&&proofs==1&&[service.statusSnapshot[@"state"]isEqual:@"off"]&&!Exists([directory stringByAppendingPathComponent:@"owner.json"])&&!Exists([directory stringByAppendingPathComponent:@"session-work"])&&!Exists([directory stringByAppendingPathComponent:KuroRouteJournal])&&dns.additions==1&&dns.removals==1);
    // superviseSocket returns successful held cleanup even for a failed tick.
    // The original gate failure is retained in its unexpected-stop diagnostics.
    CHECK(result);if(scenario) {
      CHECK([failure isEqual:@"session owner requested stop or control gate failed"]);
      NSString *path=[[service valueForKey:@"diagnosticDirectory"]stringByAppendingPathComponent:@"diagnostics.json"];
      NSDictionary *summary=ReadJSON(directory,path,geteuid(),NULL);
      CHECK([summary[@"stopContext"][@"unexpected"]isEqual:@YES] && [summary[@"stopContext"][@"reason"]containsString:@"route baseline changed"] && [summary[@"error"]containsString:@"route baseline changed"] && [summary[@"networkRecovery"][@"restored"]isEqual:@YES]);
    }
    CHECK([network.recoveryObservation[@"systemRouteBaselineRestored"]isEqual:@NO]);CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
    printf("PASS actual service local-route case=%lu: local rotation %s; held child reaped and owned network/work retired\n",(unsigned long)scenario,scenario?"followed by changed-default automatic stop":"keeps heartbeat and normal stop");
    (void)error;
  }
}

static void ProductionNetworkTests(void) {
  ProductionLocalRouteChangeTests();ProductionLocalRouteServiceTests();
  ProductionOwnRouteAbsenceTests();ProductionRouteBaselineDifferenceTests();ProductionAutoRouteTests();InternalDNSProbeDiagnosticTests();IPv4UpstreamTests();ProductionDNSMetadataTests();ProductionActiveDNSDerivedTests();ProductionDNSDifferenceTests();ProductionRecoveryDNSDerivedTests();UnexpectedRouteEvidenceTests();HeldMulticastCompanionTests();
  NSString *error=nil;CHECK(KuroCoreAddressesReady(RouteFixtureInterface(),ProductionInterfaces(YES),&error));CHECK(!KuroCoreAddressesReady(RouteFixtureInterface(),ProductionInterfaces(NO),&error));
  CHECK(!KuroPreservedEndpoint(@"fd00::1",ProductionBaseline(),@"en0",YES,NO,&error));CHECK(KuroPreservedEndpoint(@"192.168.1.53",ProductionBaseline(),@"en0",YES,NO,&error));
}
// No external IPv6 reachability is claimed: both local TUN families stay required.
static void IPv4UpstreamTests(void) {
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
    CHECK(!dns.additions&&!probes);
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
  }
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("PASS 18 IPv4-upstream admission cases: dual-stack template preserved, physical/LAN/scopedDNS paths and endpoint ambiguity remain guarded");
}
