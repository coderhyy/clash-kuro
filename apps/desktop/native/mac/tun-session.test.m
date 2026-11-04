static void SessionTests(void) {
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
    __block BOOL cleanupAllowed = scenario != 5; __block NSUInteger cleanups = 0;
    CHECK(([session spawnExecutable:child arguments:@[@"--session-child", @"ignore-term"] beforeResume:^BOOL(NSString **failure) {
      (void)failure;
      NSDictionary *record = ReadJSON(directory, [directory stringByAppendingPathComponent:@"owner.json"], geteuid(), NULL);
      CHECK([record[@"pid"] intValue] == session.child); CHECK([record[@"session"] isEqual:session.identifier]);
      CHECK([record[@"phase"] isEqual:@"prepared"]); return YES;
    } afterReap:^BOOL(NSString **failure) { (void)failure; cleanups++; return cleanupAllowed; } error:&error]));
    pid_t owned = session.child; CHECK(owned > 0 && !session.off);
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
  }
  NSString *failedDirectory = [base stringByAppendingPathComponent:@"prepare-failed"]; FixtureDirectory(failedDirectory);
  NSString *child = [failedDirectory stringByAppendingPathComponent:@"child"]; Put(child, [NSData dataWithContentsOfFile:binary], 0755);
  KuroOwnedSession *failed = [[KuroOwnedSession alloc] initWithDirectory:failedDirectory owner:geteuid()];
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return NO; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(failed.off && !failed.child);
  Put([failedDirectory stringByAppendingPathComponent:@"owner.json"], Bytes(@"foreign-owner"), 0600);
  CHECK(![failed spawnExecutable:child arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) { (void)failure; return YES; } afterReap:^BOOL(NSString **failure) { (void)failure; return YES; } error:&error]);
  CHECK(!failed.child && !failed.off); CHECK([[NSData dataWithContentsOfFile:[failedDirectory stringByAppendingPathComponent:@"owner.json"]] isEqual:Bytes(@"foreign-owner")]);
  CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  puts("native owner/session: EOF, lease, heartbeat, replay, peer exit, cleanup retry, stop, preparation refusal passed");
}
