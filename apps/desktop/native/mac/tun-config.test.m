static void NativeCoreSyntaxTest(NSData *candidate) {
  NSString *source = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
#if defined(__arm64__)
  NSString *target = @"darwin-arm64";
#else
  NSString *target = @"darwin-x64";
#endif
  NSString *desktop = [[[source stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByStandardizingPath];
  NSString *core = [desktop stringByAppendingPathComponent:[NSString stringWithFormat:@"resources/core/%@/mihomo", target]];
  if (access(core.fileSystemRepresentation, X_OK)) { CHECK(!getenv("KURO_REQUIRE_CORE")); puts("SKIP native candidate Core -t: fixed resource has not been fetched"); return; }
  char directory[] = "/tmp/kuro-native-syntax-XXXXXX"; CHECK(mkdtemp(directory));
  NSString *base = [NSString stringWithUTF8String:directory], *config = [base stringByAppendingPathComponent:@"config.json"];
  CHECK([candidate writeToFile:config options:NSDataWritingWithoutOverwriting error:NULL]);
  char *arguments[] = {(char *)core.fileSystemRepresentation, "-t", "-d", (char *)base.fileSystemRepresentation, "-f", (char *)config.fileSystemRepresentation, NULL};
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL}; pid_t child; CHECK(!posix_spawn(&child, arguments[0], NULL, NULL, arguments, environment));
  uint64_t deadline = KuroMonotonicMilliseconds() + 5000; int status = 0; pid_t done = 0;
  while (!done && KuroMonotonicMilliseconds() < deadline) { done = waitpid(child, &status, WNOHANG); if (done < 0 && errno == EINTR) done = 0; if (!done) { struct timespec pause = {.tv_nsec=5000000}; nanosleep(&pause, NULL); } }
  if (!done) { CHECK(!kill(child, SIGKILL)); CHECK(waitpid(child, &status, 0) == child); }
  CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  CHECK(done == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  puts("PASS native JSON candidate accepted by fixed Core -t (syntax only; no TUN activation)");
}
static NSMutableDictionary *ValidTunConfig(void) {
  return [@{@"version":@1,@"template":@"macos-dual-stack-v1",@"mode":@"rule",@"proxies":@[],@"groups":@[],@"rules":@[@{@"type":@"MATCH",@"value":@"",@"target":@"DIRECT",@"noResolve":@NO}],@"dns":@{@"nameservers":@[@"192.0.2.53"],@"bootstrap":@[@"2001:db8::53"],@"proxyNameservers":@[@"192.0.2.54"],@"policies":@[]}} mutableCopy];
}
static void ConfigTests(void) {
  NSString *error = nil; NSMutableDictionary *config = ValidTunConfig();
  CHECK(KuroValidateTunConfig(JSONData(config), &error));
  NSData *candidate = KuroTunRuntimeJSON(JSONData(config), &error);
  CHECK([[[NSString alloc] initWithData:candidate encoding:NSUTF8StringEncoding] rangeOfString:@"\\/"].location == NSNotFound);
  NSDictionary *runtime = KuroDecodeJSON(candidate, 128 * 1024, &error);
  CHECK([runtime[@"tun"][@"auto-route"] isEqual:@NO] && [runtime[@"tun"][@"dns-mode"] isEqual:@"disabled"]);
  CHECK([runtime[@"tun"][@"stack"] isEqual:@"mips"]); CHECK([runtime[@"rules"] isEqual:@[@"MATCH,DIRECT"]]);
  CHECK(!runtime[@"external-controller"] && !runtime[@"external-controller-unix"] && !runtime[@"proxy-providers"]);
  for (NSString *extra in @[@"path", @"external-controller", @"external-controller-unix", @"script", @"proxy-providers", @"tun", @"profile"]) {
    config = ValidTunConfig(); config[extra] = @"/tmp/untrusted"; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  }
  for (id bad in @[@YES, @2, @"1", NSNull.null]) { config = ValidTunConfig(); config[@"version"] = bad; CHECK(!KuroValidateTunConfig(JSONData(config), &error)); }
  for (id bad in @[@[], @{}, @1, @"", NSNull.null]) { config = ValidTunConfig(); config[@"dns"] = bad; CHECK(!KuroValidateTunConfig(JSONData(config), &error)); }
  for (NSString *bad in @[@"https://dns.example/dns-query", @"system", @"8.8.8.8:53", @"::ffff:192.0.2.1", @"fe80::1%en0", @"0.0.0.0", @"224.0.0.1", @"ff02::1", @"198.18.0.2", @"fdfe:dcba:9876::2"]) {
    config = ValidTunConfig(); NSMutableDictionary *dns = [config[@"dns"] mutableCopy]; dns[@"nameservers"] = @[bad]; config[@"dns"] = dns; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  }
  NSArray *proxies = @[@{@"type":@"ss",@"name":@"ss",@"server":@"example.org",@"port":@443,@"cipher":@"aes-128-gcm",@"password":@"secret"},@{@"type":@"socks5",@"name":@"socks",@"server":@"192.0.2.2",@"port":@1080,@"username":@"u",@"password":@"p",@"tls":@NO},@{@"type":@"http",@"name":@"http",@"server":@"2001:db8::1",@"port":@8080},@{@"type":@"trojan",@"name":@"trojan",@"server":@"example.org",@"port":@443,@"password":@"p",@"sni":@"example.org",@"skip-cert-verify":@NO}];
  config = ValidTunConfig(); config[@"proxies"] = proxies; config[@"groups"] = @[@{@"name":@"select",@"type":@"select",@"proxies":@[@"ss",@"socks",@"http",@"trojan",@"DIRECT"]}]; CHECK(KuroTunRuntimeJSON(JSONData(config), &error));
  NSMutableDictionary *unicodeProxy = [proxies[0] mutableCopy];
  unicodeProxy[@"password"] = [NSString stringWithFormat:@"a%Cb%Cc", (unichar)0x85, (unichar)0x2028];
  config = ValidTunConfig(); config[@"proxies"] = @[unicodeProxy];
  NSData *unicodeCandidate = KuroTunRuntimeJSON(JSONData(config), &error);
  NSDictionary *unicodeRuntime = KuroDecodeJSON(unicodeCandidate, 128 * 1024, &error);
  CHECK([unicodeRuntime[@"proxies"][0][@"password"] isEqual:unicodeProxy[@"password"]]);
  CHECK([[[NSString alloc] initWithData:unicodeCandidate encoding:NSUTF8StringEncoding] containsString:@"\\u0085"]);
  NativeCoreSyntaxTest(unicodeCandidate);
  for (NSString *key in @[@"path", @"plugin", @"dialer-proxy", @"client-fingerprint"]) { NSMutableDictionary *proxy = [proxies[0] mutableCopy]; proxy[key] = @"x"; config = ValidTunConfig(); config[@"proxies"] = @[proxy]; CHECK(!KuroValidateTunConfig(JSONData(config), &error)); }
  for (id bad in @[@YES,@0,@65536,@1.5,@"443"]) { NSMutableDictionary *proxy = [proxies[0] mutableCopy]; proxy[@"port"] = bad; config = ValidTunConfig(); config[@"proxies"] = @[proxy]; CHECK(!KuroValidateTunConfig(JSONData(config), &error)); }
  config = ValidTunConfig(); config[@"groups"] = @[@{@"name":@"loop",@"type":@"select",@"proxies":@[@"loop"]}]; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  config = ValidTunConfig(); config[@"rules"] = @[@{@"type":@"MATCH",@"value":@"",@"target":@"missing",@"noResolve":@NO}]; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  config = ValidTunConfig(); config[@"rules"] = @[@{@"type":@"DOMAIN",@"value":@"example.org",@"target":@"DIRECT",@"noResolve":@NO}]; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  config = ValidTunConfig(); config[@"rules"] = @[@{@"type":@"IP-CIDR6",@"value":@"2001:db8::/129",@"target":@"DIRECT",@"noResolve":@YES},[config[@"rules"] lastObject]]; CHECK(!KuroValidateTunConfig(JSONData(config), &error));
  CHECK(!KuroDecodeJSON(Bytes(@"{\"a\":1,\"a\":2}"), 65536, &error));
  CHECK(!KuroDecodeJSON(Bytes(@"{\"a\":{\"b\":1,\"\\u0062\":2}}"), 65536, &error));
  CHECK(!KuroDecodeJSON(Bytes(@"{\"a\":1}{}"), 65536, &error));
  CHECK(!KuroValidateTunConfig([NSMutableData dataWithLength:65537], &error));
  CHECK(![ProcessRequest(Bytes(@"{\"version\":2,\"operation\":\"open\",\"config\":{}}"), -1, @"", geteuid())[@"ok"] boolValue]);
  CHECK([ProcessRequest(Bytes(@"{\"version\":2,\"operation\":\"open\",\"config\":{}}"), -1, @"", geteuid())[@"version"] isEqual:@2]);
  puts("native TUN config: closed schema, references, DNS, duplicate keys, limits and JSON candidate passed");
}
