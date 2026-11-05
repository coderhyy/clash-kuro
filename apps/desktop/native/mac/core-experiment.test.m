// Ordinary-user fixtures only: this code never locates or launches mihomo.
static NSUInteger ExperimentAssertions=0;
#define EXP_CHECK(value) do { ExperimentAssertions++; if(!(value)) { fprintf(stderr,"experiment fixture failed line %d: %s\n",__LINE__,#value);return 1; } }while(0)
static int ExperimentFixtureCore(const char *directory,const char *configuration) {
  NSString *work=@(directory),*path=@(configuration),*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
  if(geteuid()==0 || ![work hasPrefix:@"/private/tmp/kuro-core-"] || ![path isEqual:[work stringByAppendingPathComponent:@"config.json"]])return 91;
  NSDictionary *value=ReadJSON(work,path,geteuid(),NULL);
  if(!value || ![value isEqual:ExperimentConfig(socketPath,value[@"secret"])])return 92;
  struct sockaddr_un address;if(!KuroUnixSocketAddress(socketPath,&address,NULL))return 93;
  int listener=socket(AF_UNIX,SOCK_STREAM,0);
  if(listener<0 || bind(listener,(struct sockaddr *)&address,sizeof(address)) || listen(listener,4))return 94;
  NSString *mode=@"direct",*selection=@"DIRECT";
  for(;;) @autoreleasepool {
    struct pollfd ready={.fd=listener,.events=POLLIN};if(poll(&ready,1,1000)<=0)continue;
    int peer=accept(listener,NULL,NULL);if(peer<0)continue;
    struct timeval timeout={.tv_sec=1};setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    NSMutableData *request=[NSMutableData data];NSString *text=nil;NSRange delimiter=NSMakeRange(NSNotFound,0);
    while(request.length<8192) {
      char bytes[1024];ssize_t used=recv(peer,bytes,sizeof(bytes),0);if(used<=0)break;
      [request appendBytes:bytes length:(NSUInteger)used];text=[[NSString alloc]initWithData:request encoding:NSUTF8StringEncoding];
      delimiter=[text rangeOfString:@"\r\n\r\n"];if(delimiter.location==NSNotFound)continue;
      NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"Content-Length: ([0-9]+)\\r\\n" options:0 error:NULL];
      NSTextCheckingResult *match=[pattern firstMatchInString:text options:0 range:NSMakeRange(0,delimiter.location+2)];
      NSUInteger body=match?[[text substringWithRange:[match rangeAtIndex:1]]integerValue]:0;
      if(request.length>=NSMaxRange(delimiter)+body)break;
    }
    id payload=nil;BOOL accepted=[text containsString:[NSString stringWithFormat:@"Authorization: Bearer %@\r\n",value[@"secret"]]];
    NSDictionary *body=delimiter.location==NSNotFound?nil:KuroDecodeJSON([[text substringFromIndex:NSMaxRange(delimiter)]dataUsingEncoding:NSUTF8StringEncoding],1024,NULL);
    if(accepted&&[text hasPrefix:@"GET /version HTTP/1.1\r\n"])payload=@{@"version":@"fixture-1"};
    else if(accepted&&[text hasPrefix:@"GET /configs HTTP/1.1\r\n"])payload=@{@"mode":mode};
    else if(accepted&&[text hasPrefix:@"GET /proxies/Kuro-Experiment HTTP/1.1\r\n"])payload=@{@"now":selection};
    else if(accepted&&[text hasPrefix:@"PATCH /configs HTTP/1.1\r\n"]&&Keys(body,@[@"mode"])&&[@[@"rule",@"direct"]containsObject:body[@"mode"]]) {mode=body[@"mode"];payload=NSNull.null;}
    else if(accepted&&[text hasPrefix:@"PUT /proxies/Kuro-Experiment HTTP/1.1\r\n"]&&Keys(body,@[@"name"])&&[@[@"DIRECT",@"REJECT"]containsObject:body[@"name"]]) {selection=body[@"name"];payload=NSNull.null;}
    NSData *encoded=nil;
    if(payload==NSNull.null)encoded=[@"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    else if(payload) { NSData *json=JSONData(payload);NSMutableData *reply=[[[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Length: %lu\r\n\r\n",(unsigned long)json.length]dataUsingEncoding:NSUTF8StringEncoding]mutableCopy];[reply appendData:json];encoded=reply; }
    else encoded=[@"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"dataUsingEncoding:NSUTF8StringEncoding];
    (void)send(peer,encoded.bytes,encoded.length,MSG_NOSIGNAL);close(peer);
  }
}
static int ExperimentSelfTests(void) {
  EXP_CHECK(geteuid()!=0);
  NSDictionary *config=ExperimentConfig(@"/private/tmp/test/core.sock",@"fixture-secret");
  EXP_CHECK([config[@"tun"][@"enable"]isEqual:@NO]&&[config[@"dns"][@"enable"]isEqual:@NO]);
  EXP_CHECK([config[@"dns"][@"default-nameserver"]isEqual:@[@"127.0.0.1"]]);
  for(NSString *key in @[@"port",@"socks-port",@"mixed-port",@"redir-port",@"tproxy-port"])EXP_CHECK([config[key]isEqual:@0]);
  EXP_CHECK([config[@"proxies"]count]==0&&[config[@"listeners"]count]==0&&[config[@"tunnels"]count]==0&&[config[@"proxy-providers"]count]==0&&[config[@"rule-providers"]count]==0);
  EXP_CHECK([config[@"rules"]isEqual:@[@"MATCH,DIRECT"]]);
  EXP_CHECK(KuroSessionTemplate(@"core-control-experiment-v1")&&!KuroSessionTemplate(@"macos-dual-stack-v1"));
  NSDictionary *manifest=ExperimentFixtureManifest();
  for(NSString *stage in @[@"normal",@"eof"]) {
    NSString *error=nil;NSDictionary *result=ExperimentGuardian(stage,manifest,YES,&error);
    if(![result[@"status"]isEqual:@"passed"])fprintf(stderr,"fixture result %s error %s\n",result.description.UTF8String,error.UTF8String);
    EXP_CHECK([result[@"status"]isEqual:@"passed"]);
    EXP_CHECK([result[@"groupAbsent"]isEqual:@YES]);
    EXP_CHECK([result[@"worker"][@"termination"][@"observed"]isEqual:@YES]);
    EXP_CHECK(!Exists(result[@"base"]));
  }
  // The worker exits unexpectedly after reporting its exact Core identity.
  // The live outer guardian must reclaim its anchored group, not a stored PID.
  NSString *crashError=nil;NSDictionary *crashed=ExperimentGuardian(@"fixture-worker-exit",manifest,YES,&crashError);
  EXP_CHECK([crashed[@"status"]isEqual:@"blocked"]);
  EXP_CHECK([crashed[@"groupAbsent"]isEqual:@YES]);
  EXP_CHECK(ExperimentAbsent(crashed[@"coreIdentity"]));
  // A crash retains owner/work evidence; do not pretend file cleanup succeeded.
  EXP_CHECK(Exists([crashed[@"base"]stringByAppendingPathComponent:@"owner.json"]));
  NSDictionary *success=@{@"format":@1,@"epoch":manifest[@"epoch"],@"stage":@"normal",@"status":@"passed",@"coreSHA256":manifest[@"coreSHA256"],@"runnerSHA256":manifest[@"runnerSHA256"],@"session":NSUUID.UUID.UUIDString,@"configSHA256":manifest[@"coreSHA256"],@"coreVersion":@"fixture-1",@"coreAbsent":@YES,@"ownerAbsent":@YES,@"workAbsent":@YES,@"groupAbsent":@YES,@"termination":@{@"request":@"SIGTERM",@"observed":@YES,@"exitCode":NSNull.null,@"signal":@15},@"coreStdIO":@"discarded-to-dev-null",@"noIPReadbacks":@2};
  EXP_CHECK(ExperimentSuccess(success,manifest,@"normal"));
  for(NSString *key in @[@"epoch",@"coreSHA256",@"runnerSHA256",@"coreAbsent",@"ownerAbsent",@"workAbsent",@"groupAbsent",@"extra"]) {
    NSMutableDictionary *changed=[success mutableCopy];changed[key]=[key hasSuffix:@"Absent"]?@NO:@"changed";
    EXP_CHECK(!ExperimentSuccess(changed,manifest,@"normal"));
  }
  printf("fixture abnormal-exit retained evidence: %s\n",[crashed[@"base"]fileSystemRepresentation]);
  // An unknown Core write is evidence, never an implicitly authorized deletion.
  char temporary[]="/private/tmp/kuro-core-XXXXXX";EXP_CHECK(mkdtemp(temporary));NSString *base=@(temporary),*work=[base stringByAppendingPathComponent:@"session-work"];
  EXP_CHECK(!mkdir(work.fileSystemRepresentation,0700));NSString *unknown=[work stringByAppendingPathComponent:@"cache.db"];
  EXP_CHECK(WriteNew(unknown,[NSData data],0600,NULL));
  EXP_CHECK(!ExperimentRemoveWork(base,Hash([NSData data]),nil,NULL)&&Exists(unknown));
  EXP_CHECK(!unlink(unknown.fileSystemRepresentation)&&!rmdir(work.fileSystemRepresentation)&&!rmdir(base.fileSystemRepresentation));
  EXP_CHECK(!ExperimentSuccess(@{},manifest,@"normal"));
  printf("core experiment: %lu fixture assertions passed; no real Core, Core -t, install or network mutation\n",(unsigned long)ExperimentAssertions);return 0;
}
#undef EXP_CHECK
