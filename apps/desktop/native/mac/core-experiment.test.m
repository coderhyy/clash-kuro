// Ordinary-user fixtures only: this code never locates or launches mihomo.
static NSUInteger ExperimentAssertions=0;
#define EXP_CHECK(value) do { ExperimentAssertions++; if(!(value)) { fprintf(stderr,"experiment fixture failed line %d: %s\n",__LINE__,#value);return 1; } }while(0)
static int ExperimentFixtureCore(const char *directory,const char *configuration,const char *behavior) {
  NSString *work=@(directory),*path=@(configuration),*socketPath=[work stringByAppendingPathComponent:@"core.sock"];
  if(geteuid()==0 || ![work hasPrefix:@"/private/tmp/kuro-core-"] || ![path isEqual:[work stringByAppendingPathComponent:@"config.json"]])return 91;
  NSDictionary *value=ReadJSON(work,path,geteuid(),NULL);
  if(!value || ![value isEqual:ExperimentConfig(socketPath,value[@"secret"])])return 92;
  if(!strcmp(behavior,"fixture-early-exit")||!strcmp(behavior,"fixture-log-save-failure")) {
    fputs("fixture early stdout\n",stdout);fflush(stdout);NSString *secret=value[@"secret"];NSData *bytes=[secret dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(2,"fatal secret=",13);(void)write(2,bytes.bytes,bytes.length/2);usleep(1000);(void)write(2,(const char *)bytes.bytes+bytes.length/2,bytes.length-bytes.length/2);(void)write(2,"\n",1);return 37;
  }
  if(!strcmp(behavior,"fixture-timeout")) {fputs("fixture waiting without listener\n",stderr);fflush(stderr);for(;;)pause();}
  if(!strcmp(behavior,"fixture-output")) {
    NSMutableData *bytes=[NSMutableData dataWithLength:ExperimentLogLimit-8];memset(bytes.mutableBytes,'x',bytes.length);[bytes appendData:[value[@"secret"]dataUsingEncoding:NSUTF8StringEncoding]];[bytes increaseLengthBy:ExperimentLogLimit*3];
    for(int fd=1;fd<=2;fd++) {NSUInteger offset=0;while(offset<bytes.length) {ssize_t used=write(fd,(const char *)bytes.bytes+offset,MIN((NSUInteger)1024,bytes.length-offset));if(used<=0)return 95;offset+=(NSUInteger)used;}}
  }
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
    else if(accepted&&[text hasPrefix:@"PUT /proxies/Kuro-Experiment HTTP/1.1\r\n"]&&Keys(body,@[@"name"])&&[@[@"DIRECT",@"REJECT"]containsObject:body[@"name"]]) {selection=body[@"name"];payload=NSNull.null;NSString *cache=[work stringByAppendingPathComponent:@"cache.db"];if(!Exists(cache)&&!WriteNew(cache,[@"fixture cache"dataUsingEncoding:NSUTF8StringEncoding],0600,NULL))return 96;}
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
  char invalidTemporary[]="/private/tmp/kuro-core-XXXXXX";EXP_CHECK(mkdtemp(invalidTemporary));NSString *invalidBase=@(invalidTemporary),*invalidError=nil;
  KuroOwnedSession *invalidCapture=[[KuroOwnedSession alloc]initWithDirectory:invalidBase owner:geteuid()];invalidCapture.experimentStdoutDescriptor=1;invalidCapture.experimentStderrDescriptor=2;
  EXP_CHECK(![invalidCapture spawnExecutable:Executable() arguments:@[] beforeResume:^BOOL(NSString **error){(void)error;return YES;} afterReap:^BOOL(NSString **error){(void)error;return YES;} error:&invalidError]);
  EXP_CHECK([invalidError containsString:@"capture"]&&invalidCapture.child==0&&!Exists([invalidBase stringByAppendingPathComponent:@"owner.json"]));EXP_CHECK(!rmdir(invalidBase.fileSystemRepresentation));
  NSDictionary *manifest=ExperimentFixtureManifest();
  for(NSString *stage in @[@"normal",@"eof"]) {
    NSString *error=nil;NSDictionary *result=ExperimentGuardian(stage,manifest,YES,&error);
    if(![result[@"status"]isEqual:@"passed"])fprintf(stderr,"fixture result %s error %s\n",result.description.UTF8String,error.UTF8String);
    EXP_CHECK([result[@"status"]isEqual:@"passed"]);
    EXP_CHECK([result[@"groupAbsent"]isEqual:@YES]);
    EXP_CHECK([result[@"worker"][@"termination"][@"observed"]isEqual:@YES]);
    EXP_CHECK(!Exists(result[@"base"]));
  }
  for(NSString *stage in @[@"fixture-early-exit",@"fixture-output",@"fixture-timeout"]) {
    NSString *error=nil;NSDictionary *result=ExperimentGuardian(stage,manifest,YES,&error),*worker=result[@"worker"];
    printf("fixture diagnostics %s: %s\n",stage.UTF8String,[result[@"diagnosticsDirectory"]fileSystemRepresentation]);
    EXP_CHECK([result[@"groupAbsent"]isEqual:@YES]);
    EXP_CHECK([worker[@"workAbsent"]isEqual:@YES]&&[worker[@"ownerAbsent"]isEqual:@YES]);
    NSString *evidence=result[@"diagnosticsDirectory"];NSDictionary *diagnostics=ReadJSON(evidence,[evidence stringByAppendingPathComponent:@"diagnostics.json"],geteuid(),NULL),*launch=ReadJSON(evidence,[evidence stringByAppendingPathComponent:@"launch.json"],geteuid(),NULL),*saved=ReadJSON(evidence,[evidence stringByAppendingPathComponent:@"config.redacted.json"],geteuid(),NULL);
    EXP_CHECK([saved[@"secret"]isEqual:@"[REDACTED]"]);
    EXP_CHECK([Hash(ReadProtected(evidence,[evidence stringByAppendingPathComponent:@"config.redacted.json"],geteuid(),NULL))isEqual:launch[@"redactedConfigSHA256"]]);
    EXP_CHECK(![launch[@"configSHA256"]isEqual:launch[@"redactedConfigSHA256"]]);
    EXP_CHECK([launch[@"environmentKeysSet"][@"HOME"]isEqual:@NO]);
    if([stage isEqual:@"fixture-output"]) {
      EXP_CHECK([result[@"status"]isEqual:@"passed"]);
      for(NSString *stream in @[@"stdout",@"stderr"]) {EXP_CHECK([diagnostics[@"capture"][stream][@"bytesRead"]unsignedIntegerValue]>ExperimentLogLimit*3);EXP_CHECK([diagnostics[@"capture"][stream][@"retainedBytes"]unsignedIntegerValue]<=ExperimentLogLimit);EXP_CHECK([diagnostics[@"capture"][stream][@"eof"]isEqual:@YES]);}
    } else {
      EXP_CHECK([result[@"status"]isEqual:@"blocked"]);
      EXP_CHECK([worker[@"failureStage"]isEqual:@"private-version-readiness"]);
      if([stage isEqual:@"fixture-early-exit"]) {EXP_CHECK([worker[@"termination"][@"exitCode"]isEqual:@37]);NSString *log=[[NSString alloc]initWithData:ReadProtected(evidence,[evidence stringByAppendingPathComponent:@"stderr.log"],geteuid(),NULL) encoding:NSUTF8StringEncoding];EXP_CHECK([log isEqual:@"fatal secret=[REDACTED]\n"]);NSString *stdoutLog=[[NSString alloc]initWithData:ReadProtected(evidence,[evidence stringByAppendingPathComponent:@"stdout.log"],geteuid(),NULL) encoding:NSUTF8StringEncoding];EXP_CHECK([stdoutLog isEqual:@"fixture early stdout\n"]);}
      else EXP_CHECK([diagnostics[@"capture"][@"stderr"][@"bytesRead"]unsignedIntegerValue]>0);
    }
  }
  NSString *failedLogError=nil;NSDictionary *failedLog=ExperimentGuardian(@"fixture-log-save-failure",manifest,YES,&failedLogError);
  printf("fixture diagnostics log-save-failure: %s\n",[failedLog[@"diagnosticsDirectory"]fileSystemRepresentation]);
  EXP_CHECK([failedLog[@"worker"][@"termination"][@"exitCode"]isEqual:@37]);
  EXP_CHECK([failedLog[@"worker"][@"diagnosticError"]length]>0);
  EXP_CHECK([failedLog[@"worker"][@"workAbsent"]isEqual:@NO]);
  EXP_CHECK(Exists([failedLog[@"base"]stringByAppendingPathComponent:@"session-work/config.json"]));
  EXP_CHECK(!chmod([failedLog[@"diagnosticsDirectory"]fileSystemRepresentation],0700));
  puts("fixture log-save-failure: Core exit37 preserved, owner/work retained; test-only directory restored to0700 without retry");
  // Redaction works across read chunks, a retained cap and an incomplete EOF.
  NSString *known=@"known-sensitive-token";NSData *knownBytes=[known dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *chunks=[NSMutableData data];[chunks appendBytes:knownBytes.bytes length:7];[chunks appendBytes:(const char *)knownBytes.bytes+7 length:knownBytes.length-7];
  EXP_CHECK([ExperimentRedact(chunks,known)isEqual:[@"[REDACTED]"dataUsingEncoding:NSUTF8StringEncoding]]);
  NSMutableData *boundary=[NSMutableData dataWithLength:ExperimentLogLimit-3];memset(boundary.mutableBytes,'x',boundary.length);[boundary appendData:knownBytes];[boundary appendBytes:"tail" length:4];
  NSData *safeBoundary=ExperimentRedact(boundary,known);EXP_CHECK(safeBoundary.length==ExperimentLogLimit);
  EXP_CHECK(!memcmp((const char *)safeBoundary.bytes+safeBoundary.length-3,"[RE",3));
  EXP_CHECK([ExperimentRedact([@"headknown-sens"dataUsingEncoding:NSUTF8StringEncoding],known)isEqual:[@"head[REDACTED]"dataUsingEncoding:NSUTF8StringEncoding]]);
  char permissionTemporary[]="/private/tmp/kuro-core-evidence-XXXXXX";EXP_CHECK(mkdtemp(permissionTemporary));NSString *permissionDirectory=@(permissionTemporary),*permissionFile=[permissionDirectory stringByAppendingPathComponent:@"stdout.log"];NSData *empty=[NSData data];
  EXP_CHECK(ExperimentSave(permissionDirectory,@"stdout.log",empty,NULL));EXP_CHECK(!chmod(permissionDirectory.fileSystemRepresentation,0755));EXP_CHECK(!ExperimentSave(permissionDirectory,@"blocked.log",empty,NULL));EXP_CHECK(!ExperimentPublishLog(permissionDirectory,@"stdout.log",empty,empty,NULL));EXP_CHECK(!chmod(permissionDirectory.fileSystemRepresentation,0700));EXP_CHECK(!chmod(permissionFile.fileSystemRepresentation,0644));EXP_CHECK(!ExperimentSave(permissionDirectory,@"stdout.log",empty,NULL));EXP_CHECK(!ExperimentPublishLog(permissionDirectory,@"stdout.log",empty,empty,NULL));EXP_CHECK(!unlink(permissionFile.fileSystemRepresentation)&&!rmdir(permissionDirectory.fileSystemRepresentation));
  // The worker exits unexpectedly after reporting its exact Core identity.
  // The live outer guardian must reclaim its anchored group, not a stored PID.
  NSString *crashError=nil;NSDictionary *crashed=ExperimentGuardian(@"fixture-worker-exit",manifest,YES,&crashError);
  EXP_CHECK([crashed[@"status"]isEqual:@"blocked"]);
  EXP_CHECK([crashed[@"groupAbsent"]isEqual:@YES]);
  EXP_CHECK(ExperimentAbsent(crashed[@"coreIdentity"]));
  // A crash retains owner/work evidence; do not pretend file cleanup succeeded.
  EXP_CHECK(Exists([crashed[@"base"]stringByAppendingPathComponent:@"owner.json"]));
  NSDictionary *success=@{@"format":@1,@"epoch":manifest[@"epoch"],@"stage":@"normal",@"status":@"passed",@"coreSHA256":manifest[@"coreSHA256"],@"runnerSHA256":manifest[@"runnerSHA256"],@"session":NSUUID.UUID.UUIDString,@"configSHA256":manifest[@"coreSHA256"],@"coreVersion":@"fixture-1",@"coreAbsent":@YES,@"ownerAbsent":@YES,@"workAbsent":@YES,@"groupAbsent":@YES,@"termination":@{@"request":@"SIGTERM",@"observed":@YES,@"exitCode":NSNull.null,@"signal":@15},@"coreStdIO":@"bounded-redacted-capture",@"noIPReadbacks":@2};
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
  EXP_CHECK(!ExperimentRemoveWork(base,Hash([NSData data]),nil,nil,NULL)&&Exists(unknown));
  EXP_CHECK(!unlink(unknown.fileSystemRepresentation)&&!rmdir(work.fileSystemRepresentation)&&!rmdir(base.fileSystemRepresentation));
  char cacheTemporary[]="/private/tmp/kuro-core-XXXXXX";EXP_CHECK(mkdtemp(cacheTemporary));NSString *cacheBase=@(cacheTemporary),*cacheWork=[cacheBase stringByAppendingPathComponent:@"session-work"],*cachePath=[cacheWork stringByAppendingPathComponent:@"cache.db"];
  EXP_CHECK(!mkdir(cacheWork.fileSystemRepresentation,0700));EXP_CHECK(WriteNew(cachePath,[NSData data],0600,NULL));NSDictionary *cacheIdentity=ExperimentCacheIdentity(cacheBase,NULL);EXP_CHECK(cacheIdentity);
  EXP_CHECK(!chmod(cachePath.fileSystemRepresentation,0400));EXP_CHECK(!ExperimentRemoveWork(cacheBase,Hash([NSData data]),nil,cacheIdentity,NULL)&&Exists(cachePath));
  EXP_CHECK(!unlink(cachePath.fileSystemRepresentation)&&!rmdir(cacheWork.fileSystemRepresentation)&&!rmdir(cacheBase.fileSystemRepresentation));
  // A cache-shaped symlink and an unknown sibling never become cleanup rights.
  char rejectTemporary[]="/private/tmp/kuro-core-XXXXXX";EXP_CHECK(mkdtemp(rejectTemporary));NSString *rejectBase=@(rejectTemporary),*rejectWork=[rejectBase stringByAppendingPathComponent:@"session-work"],*rejectCache=[rejectWork stringByAppendingPathComponent:@"cache.db"],*unknownSibling=[rejectWork stringByAppendingPathComponent:@"foreign"];
  EXP_CHECK(!mkdir(rejectWork.fileSystemRepresentation,0700));EXP_CHECK(!symlink("/dev/null",rejectCache.fileSystemRepresentation));EXP_CHECK(!ExperimentCacheIdentity(rejectBase,NULL));EXP_CHECK(!ExperimentRemoveWork(rejectBase,Hash(empty),nil,nil,NULL)&&Exists(rejectCache));EXP_CHECK(!unlink(rejectCache.fileSystemRepresentation));EXP_CHECK(WriteNew(rejectCache,empty,0600,NULL));NSDictionary *knownCache=ExperimentCacheIdentity(rejectBase,NULL);EXP_CHECK(WriteNew(unknownSibling,empty,0600,NULL));EXP_CHECK(!ExperimentRemoveWork(rejectBase,Hash(empty),nil,knownCache,NULL)&&Exists(rejectCache)&&Exists(unknownSibling));EXP_CHECK(!unlink(rejectCache.fileSystemRepresentation)&&!unlink(unknownSibling.fileSystemRepresentation)&&!rmdir(rejectWork.fileSystemRepresentation)&&!rmdir(rejectBase.fileSystemRepresentation));
  EXP_CHECK(!ExperimentSuccess(@{},manifest,@"normal"));
  printf("core experiment: %lu fixture assertions passed; no real Core, Core -t, install or network mutation\n",(unsigned long)ExperimentAssertions);return 0;
}
#undef EXP_CHECK
