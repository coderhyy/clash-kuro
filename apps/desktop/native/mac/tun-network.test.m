#import "tun-network.m"
#import "tun-routes.test.m"

@interface KuroFakeDNSStore : NSObject <KuroDNSStore>
@property(nonatomic) NSMutableDictionary *records;
@property(nonatomic) NSString *directory;
@property(nonatomic) NSUInteger additions;
@property(nonatomic) NSUInteger removals;
@property(nonatomic) NSUInteger snapshots;
@property(nonatomic) BOOL failRead;
@property(nonatomic) BOOL failSnapshot;
@property(nonatomic) BOOL failAdd;
@property(nonatomic) BOOL addThenFail;
@property(nonatomic) BOOL failRemove;
@property(nonatomic) BOOL lieRemove;
@property(nonatomic) BOOL replaceAfterAdd;
@property(nonatomic) BOOL changeOnSecondSnapshot;
@property(nonatomic,copy) void (^onSnapshot)(void);
@end
@implementation KuroFakeDNSStore
- (instancetype)init {
  if ((self = [super init])) _records = [@{@"State:/Network/Service/default/DNS": @{@"ServerAddresses": @[@"192.168.1.1"]}} mutableCopy];
  return self;
}
- (NSDictionary *)dnsRecords:(NSString **)error {
  _snapshots++;
  if (_onSnapshot) _onSnapshot();
  if (_failSnapshot) { Fail(error, @"snapshot failure"); return nil; }
  if (_changeOnSecondSnapshot && _snapshots == 2) _records[@"State:/Network/Service/default/DNS"] = @{@"ServerAddresses": @[@"192.168.1.2"]};
  return [_records copy];
}
- (id)valueForDNSKey:(NSString *)key error:(NSString **)error {
  if (_failRead) { Fail(error, @"read failure"); return nil; }
  return _records[key];
}
- (BOOL)addTemporaryDNSValue:(NSDictionary *)value key:(NSString *)key error:(NSString **)error {
  _additions++;
  // The real protected journal must exist and contain the intended write before
  // even the injected backend is permitted to simulate a network mutation.
  NSDictionary *journal = ReadJSON(_directory, [_directory stringByAppendingPathComponent:KuroDNSJournal], geteuid(), NULL);
  CHECK([journal[@"key"] isEqual:key] && [journal[@"after"] isEqual:value]);
  if (_records[key]) return Fail(error, @"key occupied");
  if (!_failAdd || _addThenFail) _records[key] = value;
  if (_replaceAfterAdd) _records[key] = @{@"ServerAddresses": @[@"203.0.113.53"]};
  return !_failAdd || Fail(error, @"insertion failed");
}
- (BOOL)removeDNSKey:(NSString *)key error:(NSString **)error {
  _removals++;
  if (_failRemove) return Fail(error, @"remove failed");
  if (!_lieRemove) [_records removeObjectForKey:key];
  return YES;
}
@end

#import "tun-production-network.test.m"

static void NetworkTests(void) {
  CHECK(geteuid() != 0);
  RouteTests();
  ProductionNetworkTests();
  char temporary[] = "/tmp/kuro-dns-owner-XXXXXX"; CHECK(mkdtemp(temporary));
  char canonical[PATH_MAX]; CHECK(realpath(temporary, canonical));
  NSString *base = [NSString stringWithUTF8String:canonical];
  NSString *session = @"00112233-4455-6677-8899-AABBCCDDEEFF", *key = KuroDNSKey(session), *error = nil;
  CHECK(key && !KuroDNSKey(@"../untrusted"));
  CHECK(!KuroNetworkRoutesReady(&error) && [error containsString:@"exact live utun"]);
  CHECK(!KuroNetworkCoreDNSReady(&error) && [error containsString:@"not proven"]);
  for (NSUInteger scenario = 0; scenario < 10; scenario++) {
    NSString *directory = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"run%lu", (unsigned long)scenario]];
    FixtureDirectory(directory);
    NSString *journal = [directory stringByAppendingPathComponent:KuroDNSJournal];
    KuroFakeDNSStore *backend = [KuroFakeDNSStore new]; backend.directory = directory;
    KuroOwnedDNS *dns = [[KuroOwnedDNS alloc] initWithDirectory:directory owner:geteuid() backend:backend];
    CHECK(!dns.dnsOff);
    if (scenario == 0) {
      CHECK([dns recoverDNS:&error] && dns.dnsOff);
      CHECK([dns installForSession:session error:&error] && !dns.dnsOff);
      CHECK(backend.records.count == 2 && backend.additions == 1 && [backend.records[key] isEqual:KuroDNSValue()]);
      CHECK(![dns installForSession:session error:&error] && backend.additions == 1);
      CHECK([dns recoverDNS:&error] && dns.dnsOff && backend.removals == 1 && !Exists(journal));
      CHECK(backend.records.count == 1 && [backend.records[@"State:/Network/Service/default/DNS"] isEqual:@{@"ServerAddresses": @[@"192.168.1.1"]}]);
    } else if (scenario == 1 || scenario == 2) {
      backend.failAdd = YES; backend.addThenFail = scenario == 2;
      CHECK(![dns installForSession:session error:&error] && Exists(journal) && !dns.dnsOff);
      CHECK([dns recoverDNS:&error] && dns.dnsOff && !Exists(journal));
      CHECK(backend.removals == (scenario == 2 ? 1 : 0));
    } else if (scenario == 3) {
      backend.replaceAfterAdd = YES;
      CHECK(![dns installForSession:session error:&error] && Exists(journal));
      NSDictionary *foreign = backend.records[key];
      CHECK(![dns recoverDNS:&error] && !dns.dnsOff && backend.removals == 0 && [backend.records[key] isEqual:foreign] && Exists(journal));
    } else if (scenario == 4 || scenario == 5) {
      CHECK([dns installForSession:session error:&error]);
      backend.failRemove = scenario == 4; backend.lieRemove = scenario == 5;
      CHECK(![dns recoverDNS:&error] && !dns.dnsOff && Exists(journal));
      backend.failRemove = NO; backend.lieRemove = NO;
      CHECK([dns recoverDNS:&error] && dns.dnsOff && !Exists(journal));
    } else if (scenario == 6) {
      CHECK([dns installForSession:session error:&error]);
      // A helper/store death can remove its temporary key automatically. Only
      // this DNS component is reconciled; no assertion about Core or routes.
      [backend.records removeObjectForKey:key];
      KuroOwnedDNS *restarted = [[KuroOwnedDNS alloc] initWithDirectory:directory owner:geteuid() backend:backend];
      CHECK([restarted recoverDNS:&error] && restarted.dnsOff && backend.removals == 0 && !Exists(journal));
    } else if (scenario == 7) {
      backend.changeOnSecondSnapshot = YES;
      CHECK(![dns installForSession:session error:&error] && Exists(journal) && backend.additions == 0);
      CHECK([dns recoverDNS:&error] && !Exists(journal) && backend.removals == 0);
      CHECK([backend.records[@"State:/Network/Service/default/DNS"] isEqual:@{@"ServerAddresses": @[@"192.168.1.2"]}]);
    } else if (scenario == 8) {
      CHECK([dns installForSession:session error:&error]);
      backend.failRead = YES;
      CHECK(![dns recoverDNS:&error] && Exists(journal) && backend.removals == 0 && !dns.dnsOff);
      backend.failRead = NO;
      CHECK([dns recoverDNS:&error] && dns.dnsOff);
    } else {
      CHECK([dns installForSession:session error:&error]);
      NSString *other = KuroDNSKey(@"11112233-4455-6677-8899-AABBCCDDEEFF");
      backend.records[other] = KuroDNSValue();
      CHECK(![dns recoverDNS:&error] && backend.removals == 0 && Exists(journal));
    }
  }
  NSArray *unsupported = @[
    @{}, @{@"SupplementalMatchDomains": @[@""]}, @{@"SearchDomains": @[@"bad domain"]},
    @{@"DomainName": @"bad/domain"}, @{@"Options": @"mdns"}, @{@"ServerPort": @5353},
    @{@"SearchOrder": @YES}, @{@"ServerAddresses": @[@"fe80::1%en0"]}, @{@"ServerAddresses": @[]},
  ];
  for (NSUInteger index = 0; index < unsupported.count + 3; index++) {
    NSString *directory = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"preflight%lu", (unsigned long)index]]; FixtureDirectory(directory);
    KuroFakeDNSStore *backend = [KuroFakeDNSStore new]; backend.directory = directory;
    NSMutableDictionary *value = [@{@"ServerAddresses": @[@"192.168.1.1"]} mutableCopy];
    if (index < unsupported.count) { [value addEntriesFromDictionary:unsupported[index]]; if (index == 0) [value removeAllObjects]; }
    backend.records[@"State:/Network/Service/default/DNS"] = value;
    if (index == unsupported.count) backend.records[@"State:/Network/Unsupported/utun7/DNS"] = value;
    if (index == unsupported.count + 1) [backend.records removeAllObjects];
    if (index == unsupported.count + 2) backend.failSnapshot = YES;
    KuroOwnedDNS *dns = [[KuroOwnedDNS alloc] initWithDirectory:directory owner:geteuid() backend:backend];
    CHECK(![dns installForSession:session error:&error] && backend.additions == 0 && !Exists([directory stringByAppendingPathComponent:KuroDNSJournal]));
  }
  // Preserve supported LAN search and more-specific split resolver records byte-for-byte.
  {
    NSString *directory=[base stringByAppendingPathComponent:@"split-supported"]; FixtureDirectory(directory);
    KuroFakeDNSStore *backend=[KuroFakeDNSStore new]; backend.directory=directory;
    backend.records[@"State:/Network/Service/corp/DNS"]=@{@"ServerAddresses":@[@"192.168.1.53"],@"SearchDomains":@[@"corp.example"],@"DomainName":@"corp.example",@"SupplementalMatchDomains":@[@"corp.example"],@"SupplementalMatchOrders":@[@100],@"SupplementalMatchDomainsNoSearch":@1};
    NSDictionary *before=[backend.records copy]; KuroOwnedDNS *dns=[[KuroOwnedDNS alloc]initWithDirectory:directory owner:geteuid() backend:backend];
    CHECK([dns installForSession:session error:&error]); CHECK(![dns recoverDNSAbsence:&error] && !backend.removals);
    CHECK([dns recoverDNS:&error] && [backend.records isEqual:before]);
  }
  for (NSUInteger scenario = 0; scenario < 7; scenario++) {
    NSString *directory = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"invalid%lu", (unsigned long)scenario]]; FixtureDirectory(directory);
    NSString *journal = [directory stringByAppendingPathComponent:KuroDNSJournal];
    KuroFakeDNSStore *backend = [KuroFakeDNSStore new]; backend.directory = directory;
    KuroOwnedDNS *dns = [[KuroOwnedDNS alloc] initWithDirectory:directory owner:geteuid() backend:backend];
    if (scenario == 0) { backend.records[key] = KuroDNSValue(); CHECK(![dns recoverDNS:&error]); }
    else if (scenario == 1) { Put(journal, Bytes(@"{}"), 0600); CHECK(![dns recoverDNS:&error] && Exists(journal)); }
    else if (scenario == 2) {
      NSString *foreign = [directory stringByAppendingPathComponent:@"foreign"]; Put(foreign, Bytes(@"retained"), 0600);
      CHECK(!symlink(foreign.fileSystemRepresentation, journal.fileSystemRepresentation));
      CHECK(![dns installForSession:session error:&error] && ![dns recoverDNS:&error]);
      CHECK([[NSData dataWithContentsOfFile:foreign] isEqual:Bytes(@"retained")]);
    } else if (scenario == 3) {
      CHECK([dns installForSession:session error:&error]);
      CHECK(!chmod(journal.fileSystemRepresentation, 0777));
      CHECK(![dns recoverDNS:&error] && Exists(journal));
    } else if (scenario == 4) {
      Put(journal, Bytes(@"{\"format\":1,\"format\":1}"), 0600);
      CHECK(![dns recoverDNS:&error] && Exists(journal));
    } else if (scenario == 5) {
      CHECK([dns installForSession:session error:&error]);
      NSMutableDictionary *record = [ReadJSON(directory, journal, geteuid(), NULL) mutableCopy];
      record[@"session"] = NSNull.null; Put(journal, JSONData(record), 0600);
      CHECK(![dns recoverDNS:&error] && Exists(journal));
    } else {
      Put(journal, [NSMutableData dataWithLength:MessageLimit + 1], 0600);
      CHECK(![dns recoverDNS:&error] && Exists(journal));
    }
    CHECK(!dns.dnsOff && backend.removals == 0);
  }
  // Production DNS entry cannot skip route proof, a failed local probe, or an
  // owner disappearing while the DNS adapter is taking its baseline snapshot.
  for (NSUInteger scenario=0;scenario<5;scenario++) {
    NSString *directory=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"route-gate%lu",(unsigned long)scenario]]; FixtureDirectory(directory);
    KuroCoreInterface association=RouteFixtureInterface(); __block KuroRouteOwnerState owner=KuroRouteOwnerLive;
    KuroRouteOwnership ownership=^KuroRouteOwnerState(KuroCoreInterface value,NSString **failure) { (void)value; (void)failure; return owner; };
    KuroFakeRouteStore *routeStore=[KuroFakeRouteStore new]; routeStore.directory=directory;
    KuroOwnedRoutes *routes=[[KuroOwnedRoutes alloc]initWithDirectory:directory owner:geteuid() backend:routeStore];
    if (scenario!=0) CHECK([routes installForSession:session interface:association routes:KuroSplitRouteCandidate(association) ownership:ownership error:&error]);
    KuroFakeDNSStore *store=[KuroFakeDNSStore new]; store.directory=directory;
    KuroOwnedDNS *dns=[[KuroOwnedDNS alloc]initWithDirectory:directory owner:geteuid() backend:store];
    BOOL (^probe)(NSString **)=^BOOL(NSString **failure) { (void)failure; if (scenario==2) { owner=KuroRouteOwnerUnknown; return YES; } return scenario!=1; };
    if (scenario==4) store.onSnapshot=^{ owner=KuroRouteOwnerUnknown; };
    BOOL installed=[dns installForSession:session routes:routes interface:association ownership:ownership dnsReady:probe error:&error];
    if (scenario==3) { CHECK(installed && store.additions==1); CHECK([dns recoverDNS:&error]); }
    else {
      CHECK(!installed && !store.additions);
      CHECK(Exists([directory stringByAppendingPathComponent:KuroDNSJournal])==(scenario==4));
    }
  }
  CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  puts("native DNS ownership: 30 journal + 5 route-admission scenarios passed; no Darwin store or system network operation executed");
}
