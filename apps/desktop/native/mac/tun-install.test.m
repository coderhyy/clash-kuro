// Ordinary-user fixtures only. No Installer, launchctl, real service or Core.
static NSDictionary *FixtureInventory(NSString *bundle) {
  NSMutableArray *directories=[NSMutableArray array],*files=[NSMutableArray array],*links=[NSMutableArray array];
  NSMutableArray *pending=[NSMutableArray arrayWithObject:@""];
  while(pending.count) {
    NSString *relative=pending.lastObject;[pending removeLastObject];NSString *path=relative.length?[bundle stringByAppendingPathComponent:relative]:bundle;
    struct stat info;CHECK(!lstat(path.fileSystemRepresentation,&info));
    if(S_ISLNK(info.st_mode)) {
      char target[PATH_MAX];ssize_t size=readlink(path.fileSystemRepresentation,target,sizeof(target)-1);CHECK(size>0);target[size]=0;
      [links addObject:@{@"path":relative,@"target":[NSString stringWithUTF8String:target]}];
    } else if(S_ISDIR(info.st_mode)) {
      [directories addObject:@{@"path":relative,@"mode":@(info.st_mode&0777)}];
      for(NSString *child in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL])[pending addObject:relative.length?[relative stringByAppendingPathComponent:child]:child];
    } else {NSString *hash=InstallFileHash(bundle,path,geteuid(),NULL);CHECK(hash);[files addObject:@{@"path":relative,@"mode":@(info.st_mode&0777),@"sha256":hash}];}
  }
  return @{@"format":@1,@"directories":directories,@"files":files,@"links":links};
}
static NSDictionary *FreshFixtureScripts(NSString *source,NSDictionary *client,NSDictionary *inventory) {
  NSMutableDictionary *manifest=[Payload(source) mutableCopy];manifest[@"client"]=client;manifest[@"clientInventorySHA256"]=Hash(JSONData(inventory));
  NSString *scripts=[source stringByAppendingPathComponent:@"scripts"],*inbox=At(source,[State stringByAppendingPathComponent:@"Inbox"]);
  for(NSString *name in @[@"helper",@"mihomo",@"dev.kuro.tun.plist"]) {
    NSString *to=[name isEqual:@"helper"]?@"preflight-native":name;
    Put([scripts stringByAppendingPathComponent:to],[NSData dataWithContentsOfFile:[inbox stringByAppendingPathComponent:name]],[name isEqual:@"helper"]?0755:0600);
  }
  Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);
  Put([scripts stringByAppendingPathComponent:@"client-inventory.json"],JSONData(inventory),0600);
  return manifest;
}
static void CopyFreshPayload(NSString *source,NSString *prefix,NSDictionary *manifest) {
  (void)Payload(prefix);NSString *inbox=At(prefix,[State stringByAppendingPathComponent:@"Inbox"]),*scripts=[source stringByAppendingPathComponent:@"scripts"];
  for(NSString *name in @[@"manifest.json",@"client-inventory.json"])Put([inbox stringByAppendingPathComponent:name],[NSData dataWithContentsOfFile:[scripts stringByAppendingPathComponent:name]],0600);
  CHECK([ReadJSON(prefix,[inbox stringByAppendingPathComponent:@"manifest.json"],geteuid(),NULL) isEqual:manifest]);
}
static void FreshInstallTests(void) {
  CHECK(geteuid()!=0);
  NSDictionary *minimal=@{@"format":@1,@"directories":@[@{@"path":@"",@"mode":@0755}],@"files":@[],@"links":@[]};CHECK(InventoryEntries(minimal,NULL));
  NSArray *bad=@[
    @{@"path":@"../outside",@"mode":@0644,@"sha256":Hash(Bytes(@"x"))},
    @{@"path":@"/absolute",@"mode":@0644,@"sha256":Hash(Bytes(@"x"))},
    @{@"path":@"double//slash",@"mode":@0644,@"sha256":Hash(Bytes(@"x"))},
    @{@"path":@"writable",@"mode":@0666,@"sha256":Hash(Bytes(@"x"))},
    @{@"path":@"missing-parent/file",@"mode":@0644,@"sha256":Hash(Bytes(@"x"))}];
  for(NSDictionary *entry in bad) {NSMutableDictionary *invalid=[minimal mutableCopy];invalid[@"files"]=@[entry];CHECK(!InventoryEntries(invalid,NULL));}
  NSMutableDictionary *duplicate=[minimal mutableCopy];duplicate[@"directories"]=@[minimal[@"directories"][0],minimal[@"directories"][0]];CHECK(!InventoryEntries(duplicate,NULL));
  NSMutableDictionary *escape=[minimal mutableCopy];escape[@"links"]=@[@{@"path":@"Contents/Frameworks/link",@"target":@"/etc/hosts"}];CHECK(!InventoryEntries(escape,NULL));
  for(NSUInteger scenario=0;scenario<19;scenario++) {
    char temporary[]="/tmp/kuro-fresh-XXXXXX";CHECK(mkdtemp(temporary));char real[PATH_MAX];CHECK(realpath(temporary,real));NSString *base=[NSString stringWithUTF8String:real];
    NSString *source=[base stringByAppendingPathComponent:@"source"],*prefix=[base stringByAppendingPathComponent:@"target"],*sourceBundle=[source stringByAppendingPathComponent:@"fixture.app"];
    FixtureDirectory(prefix);
    Put([sourceBundle stringByAppendingPathComponent:@"Contents/resource"],Bytes(@"approved"),0644);
    Put([sourceBundle stringByAppendingPathComponent:@"Contents/Frameworks/Fixture/Versions/A/file"],Bytes(@"framework"),0644);
    CHECK(!symlink("Versions/A/file",[sourceBundle stringByAppendingPathComponent:@"Contents/Frameworks/Fixture/link"].fileSystemRepresentation));
    NSDictionary *inventory=FixtureInventory(sourceBundle),*pin=@{@"format":@2,@"cdhash":[@"a" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0],@"executableSHA256":Hash(Bytes(@"main")),@"infoSHA256":Hash(Bytes(@"info")),@"asarSHA256":Hash(Bytes(@"asar"))};
    NSDictionary *manifest=FreshFixtureScripts(source,pin,inventory);NSString *scripts=[source stringByAppendingPathComponent:@"scripts"],*error=nil;
    if(scenario==1) {Put(At(prefix,FreshReceipt),Bytes(@"unknown"),0600);CHECK(!BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK([[NSData dataWithContentsOfFile:At(prefix,FreshReceipt)] isEqual:Bytes(@"unknown")]);}
    else if(scenario==2) {Put([At(prefix,ClientBundle) stringByAppendingPathComponent:@"unrelated"],Bytes(@"keep"),0644);CHECK(!BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK(!Exists(At(prefix,FreshReceipt)));}
    else if(scenario==3) {Put([scripts stringByAppendingPathComponent:@"client-inventory.json"],Bytes(@"{}"),0600);CHECK(!BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK(!Exists(At(prefix,FreshReceipt)));}
    else {
      CHECK(BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK(!Exists(At(prefix,State))&&!Exists(At(prefix,Tools))&&Exists(At(prefix,Recovery)));
      CHECK(!BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));
      if(scenario!=0)CopyFreshPayload(source,prefix,manifest);
      NSString *bundle=At(prefix,ClientBundle),*resource=[bundle stringByAppendingPathComponent:@"Contents/resource"];
      if(scenario!=0) {FixtureDirectory(bundle.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager] copyItemAtPath:sourceBundle toPath:bundle error:NULL]);}
      if(scenario==4)CHECK(!unlink(resource.fileSystemRepresentation));
      if(scenario==5)Put([bundle stringByAppendingPathComponent:@"unknown"],Bytes(@"keep"),0644);
      if(scenario==6)Put(resource,Bytes(@"changed"),0644);
      if(scenario==7)CHECK(!chmod(resource.fileSystemRepresentation,0666));
      if(scenario==8) {NSString *link=[bundle stringByAppendingPathComponent:@"Contents/Frameworks/Fixture/link"];CHECK(!unlink(link.fileSystemRepresentation));CHECK(!symlink("/etc/hosts",link.fileSystemRepresentation));}
      if(scenario==9)Put(At(prefix,[State stringByAppendingPathComponent:@"transaction.json"]),JSONData(@{@"format":@1,@"release":manifest[@"release"],@"stage":@"copying"}),0600);
      if(scenario==10)Put(At(prefix,[State stringByAppendingPathComponent:@"owner.json"]),Bytes(@"unknown owner"),0600);
      if(scenario==11)Put(At(prefix,[State stringByAppendingPathComponent:@"unknown"]),Bytes(@"keep"),0600);
      if(scenario==12)Put(At(prefix,Recovery),Bytes(@"changed helper"),0755);
      int auth=-1;NSString *authPath=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"auth.sock"]);
      if(scenario==13||scenario==14) {
        CHECK(EnsureDirectory(prefix,At(prefix,SocketDirectory),geteuid(),0755,&error));struct sockaddr_un address={.sun_family=AF_UNIX};strlcpy(address.sun_path,authPath.fileSystemRepresentation,sizeof(address.sun_path));auth=socket(AF_UNIX,SOCK_STREAM,0);CHECK(auth>=0&&!bind(auth,(struct sockaddr*)&address,sizeof(address)));
        struct stat value;CHECK(!lstat(authPath.fileSystemRepresentation,&value));Put(At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"]),JSONData(@{@"format":@1,@"socketDevice":@(value.st_dev),@"socketInode":@(value.st_ino+(scenario==14?1:0)),@"helperSHA256":manifest[@"helper"][@"sha256"]}),0600);
      }
      int active=-1;if(scenario==15)active=ServiceLock(prefix,geteuid(),&error);
      if(scenario==16)Put(At(prefix,FreshReceipt),Bytes(@"{}"),0600);
      if(scenario==17)Put(At(prefix,[State stringByAppendingPathComponent:@"Inbox/mihomo"]),Bytes(@"changed partial Core"),0755);
      BOOL refused=scenario==16||scenario==17||(scenario>=5&&scenario<=8)||scenario==10||scenario==11||scenario==12||scenario==14||scenario==15;
      BOOL result;
      if(scenario==18) {
        // Exercise the durable fixed recovery executable after its installer disappeared.
        CHECK(!unlink([At(prefix,Tools) stringByAppendingPathComponent:@"installer"].fileSystemRepresentation));
        pid_t child;char *arguments[]={(char *)At(prefix,Recovery).fileSystemRepresentation,"--resume-fixture",(char *)prefix.fileSystemRepresentation,NULL};
        char *environment[]={"PATH=/usr/bin:/bin","KURO_SKIP_CORE_SYNTAX=1",NULL};
        CHECK(!posix_spawn(&child,arguments[0],NULL,NULL,arguments,environment));int status;CHECK(waitpid(child,&status,0)==child);result=WIFEXITED(status)&&!WEXITSTATUS(status);
      } else result=Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error);
      if(result==refused)fprintf(stderr,"fresh scenario %lu: %s\n",(unsigned long)scenario,error.UTF8String);
      CHECK(result!=refused);
      if(refused) {CHECK(Exists(At(prefix,FreshReceipt))&&Exists(bundle));if(active>=0)close(active);}
      else {CHECK(!Exists(bundle)&&!Exists(At(prefix,Tools))&&!Exists(At(prefix,State))&&!Exists(At(prefix,SocketDirectory))&&!Exists(At(prefix,FreshReceipt))&&!Exists(At(prefix,Recovery)));}
      if(auth>=0)close(auth);
    }
    CHECK([[NSFileManager defaultManager] removeItemAtPath:base error:NULL]);
  }
  puts("native fresh install: 7 inventory rejection checks + 19 receipt, partial-copy, unknown/changed identity, active lock and exact auth socket recovery cases passed; no system install");
}
