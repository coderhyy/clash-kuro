// Deterministic observer: explicit ESRCH means only the recorded process is
// absent. It does not establish descendant/process-group exit or signal any PID.
static NSUInteger RestartObservation,RestartMode,RestartReappearAt;
static int RestartReader(int pid,int flavor,uint64_t arg,void *buffer,int size) {
  CHECK(pid==12345 && flavor==PROC_PIDTBSDINFO && arg==0 && size==sizeof(struct proc_bsdinfo));
  RestartObservation++;
  NSUInteger mode=RestartReappearAt && RestartObservation>=RestartReappearAt ? 2 : RestartMode;
  if(mode==0) { errno=ESRCH;return 0; }
  if(mode==3) { errno=EPERM;return 0; }
  if(mode==4) { errno=0;return 1; }
  struct proc_bsdinfo *value=buffer; memset(value,0,sizeof(*value));
  value->pbi_pid=(uint32_t)pid;value->pbi_start_tvsec=100;value->pbi_start_tvusec=mode==2?21:20;
  return sizeof(*value);
}
static NSMutableDictionary *RestartRecord(void) {
  NSString *digest=Hash(Bytes(@"fixture executable"));
  return [@{@"format":@1,@"session":@"00000000-0000-4000-8000-000000000001",@"pid":@12345,@"parent":@12344,@"startSeconds":@100,@"startMicros":@20,@"executableSHA256":digest,@"phase":@"prepared",@"processGroup":@12344,
    @"launch":@{@"configSHA256":Hash(Bytes(@"app config")),@"coreSHA256":digest,@"template":@"macos-dual-stack-v1"}} mutableCopy];
}
static void RestartOwnerTests(void) {
  for(NSUInteger scenario=0;scenario<10;scenario++) {
    char temporary[]="/tmp/kuro-restart-owner-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
    NSString *directory=[NSString stringWithUTF8String:canonical],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
    NSMutableDictionary *record=RestartRecord();
    if(scenario==1)record[@"extra"]=@YES;
    if(scenario==2)FixtureDirectory([directory stringByAppendingPathComponent:@"session-work"]);
    Put(journal,JSONData(record),0600);
    NSData *original=[NSData dataWithContentsOfFile:journal];
    RestartObservation=0;RestartMode=scenario>=3&&scenario<=6?scenario-2:0;RestartReappearAt=scenario==7?3:0;
    KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;
    __block NSUInteger network=0,work=0;
    BOOL ok=[observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure) {
      network++;if(scenario==8)return Fail(failure,@"fixture network receipt remains");
      if(scenario==9)Put([directory stringByAppendingPathComponent:@"network-dns.json"],Bytes(@"retained DNS"),0600);
      return YES;
    } workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook stillAbsent,NSString **failure) { CHECK([owner isEqual:record]);work++;return stillAbsent(failure); } error:&error];
    CHECK(ok==(scenario==0));CHECK(observed.off==ok);CHECK(observed.child==0);
    if(ok)CHECK(!Exists(journal));
    else { CHECK(error.length>0);CHECK([[NSData dataWithContentsOfFile:journal]isEqual:original]); }
    if(scenario>=1&&scenario<=6)CHECK(network==0&&work==0);
    if(scenario==7||scenario==8)CHECK(network==1&&work==0);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);
  }
  RestartReappearAt=0;RestartMode=0;
  puts("native restart owner: strict/legacy receipts, present/reused/denied/incomplete PID observations, changing observation and retained DNS preserve ownership; ESRCH never proves descendants exited");
}
static void SessionTests(void) {
  RestartOwnerTests();
  char temporary[] = "/tmp/kuro-session-XXXXXX"; CHECK(mkdtemp(temporary));
  char canonical[PATH_MAX]; CHECK(realpath(temporary, canonical));
  NSString *base = [NSString stringWithUTF8String:canonical];
  NSString *binary = [base stringByAppendingPathComponent:@"child"];
  Put(binary, [NSData dataWithContentsOfFile:Executable()], 0755);
  NSString *error = nil;
  for (NSUInteger scenario = 0; scenario < 10; scenario++) {
    NSString *directory = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"run%lu", (unsigned long)scenario]];
    FixtureDirectory(directory);
    NSString *child = [directory stringByAppendingPathComponent:@"child"]; Put(child, [NSData dataWithContentsOfFile:binary], 0755);
    KuroOwnedSession *session = [[KuroOwnedSession alloc] initWithDirectory:directory owner:geteuid()];
    CHECK(![session completedStopEvidence:&error]);
    CHECK(![session setLaunchEvidence:@{@"template":@"arbitrary"} error:&error]);
    NSDictionary *evidence=@{@"configSHA256":Hash(Bytes(@"config")),@"coreSHA256":Hash([NSData dataWithContentsOfFile:child]),@"template":@"macos-dual-stack-v1"};
    CHECK([session setLaunchEvidence:evidence error:&error]);
    __block BOOL cleanupAllowed = scenario != 5; __block NSUInteger cleanups = 0;
    CHECK(([session spawnExecutable:child arguments:@[@"--session-child", @"ignore-term"] beforeResume:^BOOL(NSString **failure) {
      (void)failure;
      NSDictionary *record = ReadJSON(directory, [directory stringByAppendingPathComponent:@"owner.json"], geteuid(), NULL);
      CHECK([record[@"pid"] intValue] == session.child); CHECK([record[@"session"] isEqual:session.identifier]);
      CHECK([record[@"phase"] isEqual:@"prepared"]); CHECK([record[@"launch"] isEqual:evidence]); CHECK([record[@"processGroup"] intValue]==getpgrp()); return YES;
    } afterReap:^BOOL(NSString **failure) { (void)failure; cleanups++; return cleanupAllowed; } error:&error]));
    CHECK(![session setLaunchEvidence:evidence error:&error]);
    pid_t owned = session.child; CHECK(owned > 0 && !session.off);CHECK(![session completedStopEvidence:&error]);
    int pair[2]; CHECK(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
    pid_t writer = 0;
    if (scenario == 0) { close(pair[1]); pair[1] = -1; }
    if (scenario == 2 || scenario == 3 || scenario == 6 || scenario == 7 || scenario == 8 || scenario == 9) {
      NSString *frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"%@\",\"session\":\"%@\",\"sequence\":1}\n", scenario == 6 ? @"stop" : @"heartbeat", session.identifier];
      if (scenario == 7) frame = [NSString stringWithFormat:@"{\"sequence\":1,\"session\":\"%@\",\"operation\":\"heartbeat\",\"version\":2}\n", session.identifier];
      if (scenario == 8) frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"heartbeat\",\"session\":\"%@\",\"sequence\":1,\"sequence\":1}\n", session.identifier];
      if (scenario == 9) frame = [NSString stringWithFormat:@"{\"version\":2,\"operation\":\"heartbeat\",\"session\":\"%@\",\"sequence\":1,\"path\":\"/tmp/x\"}\n", session.identifier];
      NSData *bytes = Bytes(frame);
      writer = fork(); CHECK(writer >= 0);
      if (!writer) {
        close(pair[0]);
        if (write(pair[1], bytes.bytes, bytes.length) != (ssize_t)bytes.length) _exit(2);
        if (scenario != 8 && scenario != 9) {
          char reply[1024]; ssize_t count = read(pair[1], reply, sizeof(reply)); if (count <= 0) _exit(3);
          if (scenario == 6) { reply[MIN((size_t)count, sizeof(reply) - 1)] = 0; if (!strstr(reply, "\"state\":\"off\"")) _exit(5); }
          if (scenario == 3 && write(pair[1], bytes.bytes, bytes.length) != (ssize_t)bytes.length) _exit(4);
        }
        close(pair[1]); _exit(0);
      }
      close(pair[1]); pair[1] = -1;
    }
    BOOL stopped = [session superviseSocket:pair[0] leaseMilliseconds:80 identityValid:^BOOL { return scenario != 4; } error:&error];
    close(pair[0]); if (pair[1] >= 0) close(pair[1]);
    if (writer) { int result; CHECK(waitpid(writer, &result, 0) == writer && WIFEXITED(result) && WEXITSTATUS(result) == 0); }
    if (session.child) fprintf(stderr, "scenario %lu child %d stop %d error %s\n", (unsigned long)scenario, session.child, stopped, error.UTF8String);
    CHECK(session.child == 0); CHECK(waitpid(owned, NULL, WNOHANG) == -1 && errno == ECHILD);
    CHECK(cleanups == 1);
    if (scenario == 5) { CHECK(!stopped && !session.off); CHECK(Exists([directory stringByAppendingPathComponent:@"owner.json"])); cleanupAllowed = YES; CHECK([session stop:&error]); CHECK(cleanups == 2); }
    else CHECK(stopped);
    CHECK(session.off && !Exists([directory stringByAppendingPathComponent:@"owner.json"]));
    CHECK([session stop:&error]); CHECK(cleanups == (scenario == 5 ? 2 : 1));
    NSDictionary *proof=[session completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(proof)&&[proof[@"owner"][@"pid"]intValue]==owned);
    KuroOwnedSession *fresh=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];CHECK(fresh.off&&![fresh completedStopEvidence:&error]);
  }
  NSString *failedDirectory = [base stringByAppendingPathComponent:@"prepare-failed"]; FixtureDirectory(failedDirectory);
  NSString *child = [failedDirectory stringByAppendingPathComponent:@"child"]; Put(child, [NSData dataWithContentsOfFile:binary], 0755);
  KuroOwnedSession *failed = [[KuroOwnedSession alloc] initWithDirectory:failedDirectory owner:geteuid()];
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:failedDirectory beforeResume:^BOOL(NSString **failure) { (void)failure; return YES; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(failed.off && !failed.child);
  __block NSUInteger resumeGates=0,deniedCleanup=0;
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] workingDirectory:nil beforeResume:^BOOL(NSString **failure) { (void)failure;return YES; } afterReap:^BOOL(NSString **failure) { (void)failure;deniedCleanup++;return YES; } resumeGate:^BOOL(KuroSessionHook resume,NSString **failure) { CHECK(resume!=nil);resumeGates++;return Fail(failure,@"test cancellation before SIGCONT"); } error:&error]);
  CHECK(resumeGates==1 && deniedCleanup==1 && failed.off && !failed.child);
  CHECK([error containsString:@"resume refused"]);
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return NO; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(failed.off && !failed.child);
  Put([failedDirectory stringByAppendingPathComponent:@"owner.json"], Bytes(@"foreign-owner"), 0600);
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return YES; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(!failed.child && !failed.off); CHECK([[NSData dataWithContentsOfFile:[failedDirectory stringByAppendingPathComponent:@"owner.json"]] isEqual:Bytes(@"foreign-owner")]);
  CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  puts("native owner/session: EOF, lease, heartbeat, replay, peer exit, cleanup retry, stop, preparation refusal passed");
}
