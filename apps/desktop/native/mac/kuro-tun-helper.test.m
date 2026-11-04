#define KURO_TESTING 1
#import "kuro-tun-helper.m"
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); exit(1); } } while (0)
static NSData *Bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static void FixtureDirectory(NSString *path) { CHECK([[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]); }
static void Put(NSString *path, NSData *bytes, mode_t mode) {
  FixtureDirectory(path.stringByDeletingLastPathComponent);
  CHECK([bytes writeToFile:path atomically:NO]); CHECK(!chmod(path.fileSystemRepresentation, mode));
}
static NSDictionary *Payload(NSString *prefix) {
  NSString *release = @"v1.19.33-0.1.0-test";
#if defined(__arm64__)
  NSString *target = @"darwin-arm64";
#else
  NSString *target = @"darwin-x64";
#endif
  uint32_t header[8] = {0xfeedfacf,
#if defined(__arm64__)
    0x0100000c,
#else
    0x01000007,
#endif
    0, 2, 0, 0, 0, 0};
  NSData *helper = [NSData dataWithContentsOfFile:Executable()];
  CHECK(helper);
  NSMutableData *core = [[NSData dataWithBytes:header length:sizeof(header)] mutableCopy]; [core appendData:Bytes(@"core")];
  NSDictionary *manifest = @{@"format":@1, @"label":Label, @"release":release, @"target":target, @"protocol":@1, @"activationAllowed":@NO,
    @"core":@{@"file":@"mihomo", @"version":@"v1.19.33", @"sha256":Hash(core), @"archiveSha256":Hash(Bytes(@"archive"))},
    @"helper":@{@"file":@"helper", @"version":@"0.1.0", @"sha256":Hash(helper)}};
  NSDictionary *plist = @{@"Label":Label, @"ProgramArguments":@[[[Tools stringByAppendingPathComponent:@"versions"] stringByAppendingPathComponent:[release stringByAppendingPathComponent:@"helper"]], @"--serve"], @"Disabled":@YES, @"RunAtLoad":@NO, @"KeepAlive":@NO, @"AbandonProcessGroup":@NO};
  NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
  Put([inbox stringByAppendingPathComponent:@"helper"], helper, 0755);
  Put([inbox stringByAppendingPathComponent:@"mihomo"], core, 0755);
  Put([inbox stringByAppendingPathComponent:@"manifest.json"], JSONData(manifest), 0600);
  Put([inbox stringByAppendingPathComponent:@"dev.kuro.tun.plist"], [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL], 0644);
  Put([At(prefix, Tools) stringByAppendingPathComponent:@"installer"], helper, 0755);
  Put(At(prefix, Recovery), helper, 0755);
  return manifest;
}
#import "tun-session.test.m"
#import "tun-config.test.m"
#import "tun-peer.test.m"
#import "tun-network.test.m"
#import "tun-interface.test.m"
#import "tun-install.test.m"
#import "tun-client.test.m"
#import "tun-auth.test.m"
#import "tun-service.test.m"
int main(int argc, const char **argv) {
  @autoreleasepool {
    int authFixture=AuthFixtureMain(argc,argv); if(authFixture>=0)return authFixture;
    if(argc==2 && !strcmp(argv[1],"--auth-tests")) { CHECK(geteuid()!=0); alarm(20); AuthTests(); return 0; }
    int fixture = ServiceFixtureMain(argc, argv); if (fixture >= 0) return fixture;
    if (argc == 3 && !strcmp(argv[1], "--inspect-client-fixture")) {
      CHECK(geteuid() != 0);
      char canonical[PATH_MAX]; CHECK(realpath(argv[2], canonical));
      NSString *bundle = [NSString stringWithUTF8String:canonical], *error = nil;
      NSDictionary *pin = KuroClientSnapshot(bundle, bundle, geteuid(), &error);
      if (!pin) { fprintf(stderr, "%s\n", error.UTF8String); return 1; }
      NSData *json = JSONData(pin); fwrite(json.bytes, 1, json.length, stdout); puts(""); return 0;
    }
    if (argc >= 2 && !strcmp(argv[1], "--session-child")) {
      if (argc >= 3) signal(SIGTERM, SIG_IGN);
      for (;;) pause();
    }
    if (argc == 3 && !strcmp(argv[1], "--resume-fixture")) {
      NSString *prefix = [NSString stringWithUTF8String:argv[2]];
      NSString *error = nil;
      CHECK(geteuid() != 0);
      CHECK([Executable() isEqual:At(prefix, Recovery)]);
      CHECK(Uninstall(prefix, geteuid(), NO, Executable(), &error));
      return 0;
    }
    CHECK(geteuid() != 0); alarm(40);
    SessionTests();
    ConfigTests();
    PeerIdentityTests();
    NetworkTests();
    InterfaceTests();
    ClientPinTests();
    FreshInstallTests();
    AuthTests();
    ServiceTests();
    NSString *error = nil;
    for (NSString *op in @[@"status", @"recover", @"start", @"stop"]) {
      NSString *json = [NSString stringWithFormat:@"{\"version\":1,\"operation\":\"%@\"}\n", op];
      CHECK([ParseRequest(Bytes(json), &error) isEqual:op]);
    }
    for (NSString *bad in @[@"{}", @"{\"version\":true,\"operation\":\"status\"}", @"{\"version\":1.0,\"operation\":\"status\"}",
      @"{\"version\":1,\"operation\":\"status\",\"path\":\"/tmp/x\"}", @"{\"version\":1,\"version\":1,\"operation\":\"status\"}",
      @"{\"version\":1,\"operation\":\"exec\"}", @"[]", @"{\"operation\":\"status\",\"version\":2}"]) CHECK(!ParseRequest(Bytes(bad), &error));
    CHECK(!ParseRequest([NSMutableData dataWithLength:MessageLimit + 1], &error));
    CHECK(![ProcessRequest(Bytes(@"{\"version\":1,\"operation\":\"start\"}"), -1, @"", geteuid())[@"ok"] boolValue]);
    SecCodeRef peer = NULL; CHECK(!PeerCode(-1, &peer, &error));
    int sockets[2]; CHECK(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets));
    CHECK(PeerCode(sockets[0], &peer, &error)); CFRelease(peer); peer = NULL;
    CHECK(!Authorize(sockets[0], &error)); close(sockets[0]); close(sockets[1]);
    struct stat meta = {.st_uid=geteuid(), .st_mode=S_IFREG | 0755, .st_nlink=1};
    CHECK(SafeMetadata(meta, geteuid(), NO)); meta.st_mode |= S_ISUID; CHECK(!SafeMetadata(meta, geteuid(), NO));
    meta.st_mode = S_IFREG | 02755; CHECK(!SafeMetadata(meta, geteuid(), NO));
    char directory[] = "/tmp/kuro-native-install-XXXXXX"; CHECK(mkdtemp(directory));
    char canonical[PATH_MAX]; CHECK(realpath(directory, canonical));
    NSString *prefix = [NSString stringWithUTF8String:canonical];
    CHECK([Status(prefix, geteuid())[@"status"][@"state"] isEqual:@"unknown"]);
    CHECK(PreflightInstall(prefix, geteuid(), NO, &error));
    NSString *shared = At(prefix, @"/Library/Application Support"); FixtureDirectory(shared);
    CHECK(!chmod(shared.fileSystemRepresentation, 0777)); CHECK(!PreflightInstall(prefix, geteuid(), NO, &error)); CHECK(!chmod(shared.fileSystemRepresentation, 0755));
    NSString *alias = [shared stringByAppendingPathComponent:@"Clash Kuro"];
    CHECK(!symlink(prefix.fileSystemRepresentation, alias.fileSystemRepresentation)); CHECK(!PreflightInstall(prefix, geteuid(), NO, &error)); CHECK(!unlink(alias.fileSystemRepresentation));
    NSDictionary *manifest = Payload(prefix);
    CHECK(!PreflightInstall(prefix, geteuid(), NO, &error));
    NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
    NSString *helper = [inbox stringByAppendingPathComponent:@"helper"];
    BOOL safe = SafeChain(prefix, helper, geteuid(), NO, &error);
    if (!safe) fprintf(stderr, "path check: %s\n", error.UTF8String);
    CHECK(safe);
    CHECK(!chmod(helper.fileSystemRepresentation, 0777)); CHECK(!Install(prefix, geteuid(), NO, &error)); CHECK(!chmod(helper.fileSystemRepresentation, 0755));
    NSData *original = [NSData dataWithContentsOfFile:helper]; Put(helper, Bytes(@"tampered"), 0755);
    CHECK(!Install(prefix, geteuid(), NO, &error)); Put(helper, original, 0755);
    NSString *saved = [inbox stringByAppendingPathComponent:@"saved"];
    CHECK(!rename(helper.fileSystemRepresentation, saved.fileSystemRepresentation)); CHECK(!symlink(saved.fileSystemRepresentation, helper.fileSystemRepresentation));
    CHECK(!Install(prefix, geteuid(), NO, &error)); CHECK(!unlink(helper.fileSystemRepresentation)); CHECK(!rename(saved.fileSystemRepresentation, helper.fileSystemRepresentation));
    CHECK(Install(prefix, geteuid(), NO, &error));
    CHECK([Status(prefix, geteuid())[@"status"][@"state"] isEqual:@"off"]);
    CHECK(!Install(prefix, geteuid(), NO, &error));
    for (NSString *name in @[@"owner.json", @"network.json", @"network-dns.json"]) {
      NSString *network = At(prefix, [State stringByAppendingPathComponent:name]);
      Put(network, Bytes(@"{}"), 0600);
      CHECK([Status(prefix, geteuid())[@"status"][@"state"] isEqual:@"unknown"]);
      CHECK(!PreflightInstall(prefix, geteuid(), NO, &error));
      CHECK(!Uninstall(prefix, geteuid(), NO, [At(prefix, Tools) stringByAppendingPathComponent:@"installer"], &error)); CHECK(!unlink(network.fileSystemRepresentation));
    }
    NSString *unknown = At(prefix, [State stringByAppendingPathComponent:@"keep-user-file"]);
    Put(unknown, Bytes(@"preserve"), 0600);
    CHECK(!Uninstall(prefix, geteuid(), NO, [At(prefix, Tools) stringByAppendingPathComponent:@"installer"], &error));
    CHECK(Exists(unknown)); CHECK(!unlink(unknown.fileSystemRepresentation));
    NSData *approved = [NSData dataWithContentsOfFile:At(prefix, RecoveryRecord)]; CHECK(approved);
    NSData *recoveryBytes = [NSData dataWithContentsOfFile:At(prefix, Recovery)]; CHECK(recoveryBytes);
    // Approval was persisted before the unknown file was detected; retry tolerates one already removed payload.
    NSString *version = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:manifest[@"release"]]];
    CHECK(!unlink([version stringByAppendingPathComponent:@"mihomo"].fileSystemRepresentation));
    CHECK(!unlink([At(prefix, Tools) stringByAppendingPathComponent:@"installer"].fileSystemRepresentation));
    pid_t child;
    char *arguments[] = {(char *)At(prefix, Recovery).fileSystemRepresentation, "--resume-fixture", (char *)prefix.fileSystemRepresentation, NULL};
    CHECK(!posix_spawn(&child, arguments[0], NULL, NULL, arguments, NULL));
    int status = 0; CHECK(waitpid(child, &status, 0) == child); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(!Exists(At(prefix, Tools))); CHECK(!Exists(At(prefix, State))); CHECK(!Exists(At(prefix, SocketDirectory)));
    CHECK(!Exists(At(prefix, Recovery))); CHECK(!Exists(At(prefix, RecoveryRecord)));
    // Late interruption: main directories are already gone, but fixed recovery and approved record survived.
    Put(At(prefix, Recovery), recoveryBytes, 0755); Put(At(prefix, RecoveryRecord), approved, 0600);
    CHECK(!posix_spawn(&child, arguments[0], NULL, NULL, arguments, NULL));
    CHECK(waitpid(child, &status, 0) == child); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(!Exists(At(prefix, Recovery))); CHECK(!Exists(At(prefix, RecoveryRecord)));
    // Final two-file window: malformed record never permits self-removal; absent record only permits pure fixed self cleanup.
    Put(At(prefix, Recovery), recoveryBytes, 0755); Put(At(prefix, RecoveryRecord), Bytes(@"{}"), 0600);
    CHECK(!Uninstall(prefix, geteuid(), NO, At(prefix, Recovery), &error)); CHECK(Exists(At(prefix, Recovery)));
    CHECK(!unlink(At(prefix, RecoveryRecord).fileSystemRepresentation));
    CHECK(!posix_spawn(&child, arguments[0], NULL, NULL, arguments, NULL));
    CHECK(waitpid(child, &status, 0) == child); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(!Exists(At(prefix, Recovery)));
    CHECK(!Exists(At(prefix, Plist)));
    CHECK(!Exists([At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:manifest[@"release"]]]));
    CHECK([Status(prefix, geteuid())[@"status"][@"state"] isEqual:@"unknown"]);
    CHECK([[NSFileManager defaultManager] removeItemAtPath:prefix error:NULL]);
    puts("PASS native protocol, audit-token identity rejection, protected paths/metadata and isolated install/uninstall");
    return 0;
  }
}
