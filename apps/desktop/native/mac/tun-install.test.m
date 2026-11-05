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
static void InstallerScriptsACLTests(void) {
  CHECK(geteuid()!=0);
  NSString *error=nil;
  // Read-only exercise of the exact production sticky-ancestor exception.
  // macOS commonly reports no ACL here as NULL rather than an empty acl_t.
  acl_t existing=acl_get_file("/private/tmp",ACL_TYPE_EXTENDED);
  BOOL absent=existing==NULL;if(existing)acl_free(existing);
  CHECK(InstallScriptsProtected(@"/private/tmp",0,&error));
  char temporary[]="/tmp/kuro-installer-acl-XXXXXX";CHECK(mkdtemp(temporary));
  NSString *directory=[NSString stringWithUTF8String:temporary];
  CHECK(InstallScriptsEmptyACL(directory,&error));
  CHECK(!InstallScriptsEmptyACL([directory stringByAppendingPathComponent:@"missing"],&error));
  acl_t nonempty=acl_init(1);acl_entry_t entry;acl_permset_t permissions;
  unsigned char qualifier[16]={0};qualifier[15]=1;
  CHECK(nonempty&&!acl_create_entry(&nonempty,&entry));
  CHECK(!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)&&!acl_set_qualifier(entry,qualifier));
  CHECK(!acl_get_permset(entry,&permissions)&&!acl_add_perm(permissions,ACL_READ_DATA));
  CHECK(!acl_set_permset(entry,permissions)&&!acl_valid(nonempty));
  CHECK(!acl_set_file(temporary,ACL_TYPE_EXTENDED,nonempty));acl_free(nonempty);
  CHECK(!InstallScriptsEmptyACL(directory,&error));
  CHECK([[NSFileManager defaultManager] removeItemAtPath:directory error:NULL]);
  printf("native installer ACL: production /private/tmp accepted (%s); no system mutation\n",absent?"NULL ACL absence fallback":"empty ACL object");
}
static void SocketMigrationTests(void) {
  CHECK(geteuid()!=0);NSString *error=nil;
  CHECK([SocketDirectory isEqual:@"/Library/PrivilegedHelperTools/dev.kuro.tun-run"]);
  // The exact historical host metadata remains forbidden; do not trust daemon group writes.
  struct stat legacyMetadata={.st_uid=0,.st_gid=1,.st_mode=S_IFDIR|0775,.st_nlink=1};
  CHECK(!SafeNodeMetadata(@"/private/var/run",legacyMetadata,0,YES,&error));
  CHECK([error containsString:@"/private/var/run"]&&[error containsString:@"0775"]);
  legacyMetadata.st_mode=S_IFDIR|0755;CHECK(SafeNodeMetadata(@"fixture",legacyMetadata,0,YES,&error));
  legacyMetadata.st_uid=1;CHECK(!SafeNodeMetadata(@"/fixture/owner",legacyMetadata,0,YES,&error)&&[error containsString:@"owner uid 1"]);
  legacyMetadata.st_uid=0;legacyMetadata.st_mode=S_IFLNK|0755;
  CHECK(!SafeNodeMetadata(@"/fixture/link",legacyMetadata,0,YES,&error)&&[error containsString:@"symlink"]);
  struct stat host;
  CHECK(!lstat("/private/var/run",&host));
  if(host.st_uid==0&&(host.st_mode&06022))CHECK(!SafeNode(@"/private/var/run",0,YES,&error));
  // These are metadata/ACL reads only; no root endpoint or service is created.
  CHECK(SocketAncestorsProtected(@"",0,NO,&error));
  printf("native socket host: old ancestor uid=%u gid=%u mode=%04o; new fixed ancestors pass strict ACL/metadata/search policy (read only)\n",host.st_uid,host.st_gid,(unsigned)(host.st_mode&07777));
  struct sockaddr_un address;
  for(NSString *name in @[@"control.sock",@"auth.sock"])CHECK(KuroUnixSocketAddress([SocketDirectory stringByAppendingPathComponent:name],&address,&error));
  NSString *maximum=[@"/" stringByPaddingToLength:sizeof(address.sun_path)-1 withString:@"a" startingAtIndex:0];
  CHECK(KuroUnixSocketAddress(maximum,&address,&error));
  CHECK(!KuroUnixSocketAddress([maximum stringByAppendingString:@"a"],&address,&error)&&[error containsString:@"sun_path"]);
  char pattern[]="/tmp/k-sock-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(pattern)&&realpath(pattern,canonical));
  NSString *prefix=@(canonical),*legacy=At(prefix,LegacySocketDirectory),*oldParent=legacy.stringByDeletingLastPathComponent;
  FixtureDirectory(oldParent);CHECK(!chmod(oldParent.fileSystemRepresentation,0775));
  CHECK(PreflightInstall(prefix,geteuid(),NO,&error)); // old writable parent alone is irrelevant
  FixtureDirectory(legacy);CHECK(!PreflightInstall(prefix,geteuid(),NO,&error)&&[error containsString:legacy]);
  CHECK(!rmdir(legacy.fileSystemRepresentation));CHECK(PreflightInstall(prefix,geteuid(),NO,&error));
  NSString *parent=At(prefix,SocketDirectory).stringByDeletingLastPathComponent;
  CHECK(EnsureDirectory(prefix,parent,geteuid(),0755,&error));
  CHECK(!chmod(parent.fileSystemRepresentation,0700));
  CHECK(!PreflightInstall(prefix,geteuid(),NO,&error)&&[error containsString:@"not searchable"]);
  CHECK(ServiceLock(prefix,geteuid(),&error)<0);struct stat unchanged;CHECK(!lstat(parent.fileSystemRepresentation,&unchanged)&&(unchanged.st_mode&0777)==0700);
  CHECK(!chmod(parent.fileSystemRepresentation,0755));
  NSString *run=At(prefix,SocketDirectory);CHECK(EnsureDirectory(prefix,run,geteuid(),0700,&error));
  CHECK(ServiceLock(prefix,geteuid(),&error)<0&&[error containsString:run]);
  CHECK(!lstat(run.fileSystemRepresentation,&unchanged)&&(unchanged.st_mode&0777)==0700);
  CHECK(!chmod(run.fileSystemRepresentation,0755));
  int lock=ServiceLock(prefix,geteuid(),&error);CHECK(lock>=0);
  NSString *lockPath=[run stringByAppendingPathComponent:@"service.lock"];
  CHECK(!lstat(lockPath.fileSystemRepresentation,&unchanged)&&unchanged.st_uid==geteuid()&&(unchanged.st_mode&0777)==0600);
  for(NSString *name in @[@"control.sock",@"auth.sock"]) {
    NSString *path=[run stringByAppendingPathComponent:name];CHECK(KuroUnixSocketAddress(path,&address,&error));
    int listener=socket(AF_UNIX,SOCK_STREAM,0);CHECK(listener>=0&&!bind(listener,(struct sockaddr *)&address,sizeof(address)));
    CHECK(!chmod(path.fileSystemRepresentation,0666)&&!listen(listener,1));
    struct stat owned;CHECK(!lstat(path.fileSystemRepresentation,&owned)&&S_ISSOCK(owned.st_mode)&&(owned.st_mode&0777)==0666);
    int client=socket(AF_UNIX,SOCK_STREAM,0);CHECK(client>=0&&!connect(client,(struct sockaddr *)&address,sizeof(address)));
    int peer=accept(listener,NULL,NULL);CHECK(peer>=0&&send(client,"K",1,0)==1);
    char received=0;CHECK(recv(peer,&received,1,0)==1&&received=='K');
    close(peer);close(client);close(listener);
    CHECK(!lstat(path.fileSystemRepresentation,&unchanged)&&unchanged.st_dev==owned.st_dev&&unchanged.st_ino==owned.st_ino&&!unlink(path.fileSystemRepresentation));
  }
  close(lock);CHECK([[NSFileManager defaultManager] removeItemAtPath:prefix error:NULL]);
  puts("native socket migration: legacy metadata/path rejection, public 0700 ancestor/run refusal, fixed/prefixed/overlong addresses and two protected ordinary-user endpoint connections passed; no system service");
}
static void SessionActivationTests(void) {
  CHECK(geteuid()!=0);NSString *error=nil;
  char temporary[]="/tmp/kuro-act-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical),*source=[base stringByAppendingPathComponent:@"source"],*bundle=[source stringByAppendingPathComponent:@"fixture.app"];
  Put([bundle stringByAppendingPathComponent:ClientExecutable],[NSData dataWithContentsOfFile:Executable()],0755);
  NSDictionary *info=@{@"CFBundleIdentifier":@"dev.kuro.desktop",@"CFBundleExecutable":@"Clash Kuro",@"CFBundlePackageType":@"APPL",@"CFBundleVersion":@"1"};
  Put([bundle stringByAppendingPathComponent:@"Contents/Info.plist"],[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);
  Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"inert activation fixture"),0644);
  char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime",(char *)bundle.fileSystemRepresentation,NULL},*environment[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t signer;int status;
  CHECK(!posix_spawn(&signer,sign[0],NULL,NULL,sign,environment));CHECK(waitpid(signer,&status,0)==signer&&WIFEXITED(status)&&!WEXITSTATUS(status));
  NSDictionary *pin=KuroClientSnapshot(source,bundle,geteuid(),&error),*inventory=FixtureInventory(bundle);CHECK(pin);
  NSMutableDictionary *manifest=[FreshFixtureScripts(source,pin,inventory)mutableCopy];
  CHECK([manifest[@"activationAllowed"]isEqual:@NO]);
  for(id invalid in @[@1,@0,@"true",NSNull.null]) { manifest[@"activationAllowed"]=invalid;CHECK(!ValidManifest(manifest,&error)); }
  manifest[@"activationAllowed"]=@YES;CHECK(ValidManifest(manifest,&error));
  NSMutableDictionary *unbound=[manifest mutableCopy];[unbound removeObjectForKey:@"client"];[unbound removeObjectForKey:@"clientInventorySHA256"];CHECK(!ValidManifest(unbound,&error));
  NSString *scripts=[source stringByAppendingPathComponent:@"scripts"];
  for(NSUInteger scenario=0;scenario<18;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"case%lu",(unsigned long)scenario]];FixtureDirectory(prefix);
    manifest[@"activationAllowed"]=scenario==0?@NO:@YES; // Actual completed ordinary-user installation layout.
    Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);
    BOOL began=BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error);if(!began)fprintf(stderr,"activation case %lu begin: %s\n",(unsigned long)scenario,error.UTF8String);CHECK(began);CopyFreshPayload(source,prefix,manifest);
    NSString *client=At(prefix,ClientBundle);FixtureDirectory(client.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager]copyItemAtPath:bundle toPath:client error:NULL]);
    CHECK(Install(prefix,geteuid(),NO,&error));
    NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:manifest[@"release"]]],*helper=[version stringByAppendingPathComponent:@"helper"],*executing=helper;
    NSString *installedPath=At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),*inventoryPath=At(prefix,[State stringByAppendingPathComponent:@"Inbox/client-inventory.json"]),*clientPath=At(prefix,[State stringByAppendingPathComponent:@"client.json"]),*observer=At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"]);
    if(scenario==2)executing=[At(prefix,Tools)stringByAppendingPathComponent:@"installer"];
    if(scenario==3||scenario==5) { NSMutableDictionary *installed=[ReadJSON(prefix,installedPath,geteuid(),NULL)mutableCopy];installed[scenario==3?@"release":@"helperSHA256"]=scenario==3?@"different-release":Hash(Bytes(@"different helper"));Put(installedPath,JSONData(installed),0600); }
    if(scenario==4)Put(helper,Bytes(@"changed helper"),0755);
    if(scenario==6) { NSMutableDictionary *changed=[manifest mutableCopy];changed[@"clientInventorySHA256"]=Hash(Bytes(@"other inventory"));Put([version stringByAppendingPathComponent:@"manifest.json"],JSONData(changed),0600); }
    if(scenario==7)CHECK(!unlink(inventoryPath.fileSystemRepresentation));
    if(scenario==8)Put(inventoryPath,Bytes(@"changed inventory"),0600);
    if(scenario==9)CHECK(!unlink(At(prefix,FreshReceipt).fileSystemRepresentation));
    if(scenario==10)Put(clientPath,Bytes(@"{}"),0600);
    if(scenario==11)Put(observer,Bytes(@"active or retained auth observation"),0600);
    if(scenario==12)Put(At(prefix,[State stringByAppendingPathComponent:@"transaction.json"]),Bytes(@"unfinished installation"),0600);
    if(scenario==13)CHECK(!unlink(At(prefix,Plist).fileSystemRepresentation));
    if(scenario==14)Put(At(prefix,Plist),Bytes(@"changed plist"),0644);
    if(scenario==15)CHECK(!unlink(At(prefix,Recovery).fileSystemRepresentation));
    if(scenario==16)Put(At(prefix,Recovery),Bytes(@"changed recovery"),0755);
    if(scenario==17)CHECK(!chmod(helper.fileSystemRepresentation,0777));
    BOOL allowed=KuroSessionActivationAt(prefix,geteuid(),executing,&error);
    CHECK(allowed==(scenario==1));
    if(!allowed) { CHECK(error.length>0);CHECK(!KuroMarkSessionStarted(prefix,geteuid(),executing,&error));CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@YES]); }
    if(scenario==0) {
      NSMutableDictionary *patched=[manifest mutableCopy];patched[@"activationAllowed"]=@YES;
      Put([version stringByAppendingPathComponent:@"manifest.json"],JSONData(patched),0600);
      CHECK(!KuroSessionActivationAt(prefix,geteuid(),helper,&error)); // Auth-only receipt cannot be upgraded by patching just the installed flag.
    }
    if(scenario==1) {
      CHECK(!chmod(At(prefix,State).fileSystemRepresentation,0500));
      CHECK(!KuroMarkSessionStarted(prefix,geteuid(),helper,&error));CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@YES]);
      CHECK(!chmod(At(prefix,State).fileSystemRepresentation,0700));
      CHECK(KuroMarkSessionStarted(prefix,geteuid(),helper,&error));CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
      CHECK(KuroMarkSessionStarted(prefix,geteuid(),helper,&error)&&KuroSessionActivationAt(prefix,geteuid(),helper,&error));
      NSDictionary *never=nil;CHECK(!ProveNeverStarted(prefix,geteuid(),&never,&error));
      CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(Exists(client)&&Exists(helper));
    }
    if(scenario==11) { CHECK(!unlink(observer.fileSystemRepresentation));CHECK(KuroSessionActivationAt(prefix,geteuid(),helper,&error)); }
  }
  // A harmless held native child exercises the real session -> protected
  // stopped checkpoint -> uninstall path. Route/DNS acknowledgements are mocks.
  manifest[@"activationAllowed"]=@YES;NSMutableDictionary *realCore=[manifest[@"core"]mutableCopy];realCore[@"sha256"]=Hash([NSData dataWithContentsOfFile:Executable()]);manifest[@"core"]=realCore;
  Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);
  for(NSUInteger scenario=0;scenario<11;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"stopped%lu",(unsigned long)scenario]];FixtureDirectory(prefix);
    CHECK(BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CopyFreshPayload(source,prefix,manifest);
    Put(At(prefix,[State stringByAppendingPathComponent:@"Inbox/mihomo"]),[NSData dataWithContentsOfFile:Executable()],0755);
    NSString *client=At(prefix,ClientBundle);FixtureDirectory(client.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager]copyItemAtPath:bundle toPath:client error:NULL]);CHECK(Install(prefix,geteuid(),NO,&error));
    NSString *version=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:manifest[@"release"]]],*helper=[version stringByAppendingPathComponent:@"helper"],*core=[version stringByAppendingPathComponent:@"mihomo"],*state=At(prefix,State),*installedPath=[state stringByAppendingPathComponent:@"installed.json"],*stoppedPath=[state stringByAppendingPathComponent:@"stopped.json"];
    KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:state owner:geteuid()];
    CHECK(([session setLaunchEvidence:@{@"configSHA256":Hash(Bytes(@"inert stopped fixture")),@"coreSHA256":realCore[@"sha256"],@"template":@"macos-dual-stack-v1"} error:&error]));
    NSString *fixtureChild=[state stringByAppendingPathComponent:@"fixture-child"];Put(fixtureChild,[NSData dataWithContentsOfFile:core],0755);
    CHECK([session spawnExecutable:fixtureChild arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure) {return KuroMarkSessionStarted(prefix,geteuid(),helper,failure);} afterReap:^BOOL(NSString **failure) {(void)failure;return YES;} error:&error]);
    CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);CHECK(![session completedStopEvidence:&error]);CHECK([session stop:&error]);
    NSDictionary *process=[session completedStopEvidence:&error];CHECK(KuroCompletedStopEvidence(process));CHECK(!unlink(fixtureChild.fileSystemRepresentation));
    NSMutableDictionary *network=[@{@"format":@1,@"session":session.identifier,@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null}mutableCopy];
    if(scenario==2)network[@"dnsOff"]=@NO;
    if(scenario==3)network[@"session"]=@"00000000-0000-4000-8000-000000000001";
    BOOL checkpoint=KuroMarkSessionStopped(prefix,geteuid(),helper,process,network,&error);CHECK(checkpoint==(scenario!=2&&scenario!=3));
    if(scenario==1)CHECK(!unlink(stoppedPath.fileSystemRepresentation));
    if(scenario==4) {NSMutableDictionary *installed=[ReadJSON(prefix,installedPath,geteuid(),NULL)mutableCopy];installed[@"release"]=@"other-release";Put(installedPath,JSONData(installed),0600);}
    if(scenario==5)Put([state stringByAppendingPathComponent:@"owner.json"],Bytes(@"unknown owner"),0600);
    if(scenario==6)Put([client stringByAppendingPathComponent:@"unknown"],Bytes(@"preserve"),0644);
    if(scenario==7) {CHECK(KuroMarkSessionStarted(prefix,geteuid(),helper,&error));CHECK(!Exists(stoppedPath));CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);}
    if(scenario==9) {CHECK(!unlink(stoppedPath.fileSystemRepresentation));CHECK(!symlink(installedPath.fileSystemRepresentation,stoppedPath.fileSystemRepresentation));}
    int active=scenario==10?ServiceLock(prefix,geteuid(),&error):-1;if(scenario==10)CHECK(active>=0);
    if(scenario==8)CHECK(!chmod(state.fileSystemRepresentation,0500));
    BOOL removed=Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error);
    CHECK(removed==(scenario==0));
    if(scenario==8) {
      CHECK(ReadFreshReceipt(prefix,geteuid(),&error)[@"uninstall"]);CHECK(!Exists(client));
      CHECK(!chmod(state.fileSystemRepresentation,0700));
      // Model interruption after approved State records were removed; external
      // approval still binds exact old bytes and never grants another start.
      CHECK(!unlink(installedPath.fileSystemRepresentation));CHECK(!unlink(stoppedPath.fileSystemRepresentation));
      CHECK(!KuroSessionActivationAt(prefix,geteuid(),helper,&error));
      CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));removed=YES;
    }
    if(active>=0)close(active);
    if(removed) {CHECK(!Exists(client)&&!Exists(At(prefix,Tools))&&!Exists(state)&&!Exists(At(prefix,Recovery))&&!Exists(At(prefix,FreshReceipt))&&!Exists(At(prefix,SocketDirectory)));}
    else {CHECK(Exists(client)&&Exists(helper));CHECK([ReadJSON(prefix,installedPath,geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);}
  }
  puts("native stopped uninstall: 11 held harmless child fixtures cover complete proof, missing/false/mismatched/changed/active preservation, sticky history, durable revocation and partial cleanup retry; network proofs mocked");
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
  puts("native finite activation: explicit boolean/client/inventory, completed protected install, fixed helper identity, receipt binding and temporary auth-observer refusal passed; no service/Core/network");
}
static void FreshInstallTests(void) {
  SessionActivationTests();
  CHECK(geteuid()!=0);
  InstallerScriptsACLTests();
  SocketMigrationTests();
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
        CHECK(EnsureDirectory(prefix,At(prefix,SocketDirectory),geteuid(),0755,&error));struct sockaddr_un address;CHECK(KuroUnixSocketAddress(authPath,&address,&error));auth=socket(AF_UNIX,SOCK_STREAM,0);CHECK(auth>=0&&!bind(auth,(struct sockaddr*)&address,sizeof(address)));
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

static NSDictionary *UpgradeFixtureRawTree(NSString *base) {
  NSMutableDictionary *result=[NSMutableDictionary dictionary];NSMutableArray *pending=[NSMutableArray arrayWithObject:@""];
  while(pending.count){NSString *relative=pending.lastObject;[pending removeLastObject];NSString *path=relative.length?[base stringByAppendingPathComponent:relative]:base;struct stat info;CHECK(!lstat(path.fileSystemRepresentation,&info));
    NSMutableDictionary *entry=[@{@"mode":@(info.st_mode),@"uid":@(info.st_uid),@"gid":@(info.st_gid)}mutableCopy];
    if(S_ISLNK(info.st_mode)){char target[PATH_MAX];ssize_t size=readlink(path.fileSystemRepresentation,target,sizeof(target)-1);CHECK(size>0);target[size]=0;entry[@"target"]=@(target);}
    else if(S_ISDIR(info.st_mode)){for(NSString *name in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:path error:NULL])[pending addObject:relative.length?[relative stringByAppendingPathComponent:name]:name];}
    else {CHECK(S_ISREG(info.st_mode));NSData *bytes=[NSData dataWithContentsOfFile:path];CHECK(bytes);entry[@"sha256"]=Hash(bytes);}
    result[relative]=entry;
  }return result;
}
static NSDictionary *UpgradeFixtureSource(NSString *source,NSString *release,NSString *content,NSData *helper) {
  NSString *bundle=[source stringByAppendingPathComponent:@"fixture.app"];
  Put([bundle stringByAppendingPathComponent:ClientExecutable],[NSData dataWithContentsOfFile:Executable()],0755);
  NSDictionary *info=@{@"CFBundleIdentifier":@"dev.kuro.desktop",@"CFBundleExecutable":@"Clash Kuro",@"CFBundlePackageType":@"APPL",@"CFBundleVersion":release};
  Put([bundle stringByAppendingPathComponent:@"Contents/Info.plist"],[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);
  Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(content),0644);
  char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime",(char*)bundle.fileSystemRepresentation,NULL},*environment[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t child;int status;
  CHECK(!posix_spawn(&child,sign[0],NULL,NULL,sign,environment));CHECK(waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status));
  NSString *error=nil;NSDictionary *pin=KuroClientSnapshot(source,bundle,geteuid(),&error);CHECK(pin);
  NSDictionary *inventory=FixtureInventory(bundle);NSMutableDictionary *manifest=[FreshFixtureScripts(source,pin,inventory)mutableCopy];
  manifest[@"release"]=release;manifest[@"installerProtocol"]=@2;manifest[@"activationAllowed"]=@YES;
  NSMutableDictionary *helperPin=[manifest[@"helper"]mutableCopy];helperPin[@"sha256"]=Hash(helper);manifest[@"helper"]=helperPin;
  NSMutableDictionary *corePin=[manifest[@"core"]mutableCopy];corePin[@"sha256"]=Hash([NSData dataWithContentsOfFile:Executable()]);manifest[@"core"]=corePin;
  NSString *scripts=[source stringByAppendingPathComponent:@"scripts"];
  NSDictionary *plist=@{@"Label":Label,@"ProgramArguments":@[[[Tools stringByAppendingPathComponent:@"versions"]stringByAppendingPathComponent:[release stringByAppendingPathComponent:@"helper"]],@"--serve"],@"Disabled":@YES,@"RunAtLoad":@NO,@"KeepAlive":@NO,@"AbandonProcessGroup":@NO};
  Put([scripts stringByAppendingPathComponent:@"preflight-native"],helper,0755);Put([scripts stringByAppendingPathComponent:@"mihomo"],[NSData dataWithContentsOfFile:Executable()],0755);
  Put([scripts stringByAppendingPathComponent:@"dev.kuro.tun.plist"],[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);
  Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(manifest),0600);return manifest;
}
static void UpgradeFixtureStopped(NSString *prefix,NSDictionary *manifest) {
  NSString *error=nil;
    NSString *state=At(prefix,State),*executable=[state stringByAppendingPathComponent:@"fixture-child"],*installedHelper=[At(prefix,Tools)stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:[manifest[@"release"]stringByAppendingPathComponent:@"helper"]]];
    Put(executable,[NSData dataWithContentsOfFile:Executable()],0755);KuroOwnedSession *session=[[KuroOwnedSession alloc]initWithDirectory:state owner:geteuid()];
    CHECK(([session setLaunchEvidence:@{@"configSHA256":Hash(Bytes(@"inert upgrade fixture")),@"coreSHA256":manifest[@"core"][@"sha256"],@"template":@"macos-dual-stack-v1"}error:&error]));
    CHECK([session spawnExecutable:executable arguments:@[@"--session-child"] beforeResume:^BOOL(NSString **failure){return KuroMarkSessionStarted(prefix,geteuid(),installedHelper,failure);}afterReap:^BOOL(NSString **failure){(void)failure;return YES;}error:&error]);
    CHECK([session stop:&error]);NSDictionary *process=[session completedStopEvidence:&error];CHECK(process);CHECK(!unlink(executable.fileSystemRepresentation));
    NSDictionary *network=@{@"format":@1,@"session":session.identifier,@"routesOff":@YES,@"dnsOff":@YES,@"routeJournalSHA256":NSNull.null,@"dnsJournalSHA256":NSNull.null};CHECK(KuroMarkSessionStopped(prefix,geteuid(),installedHelper,process,network,&error));
}
static void UpgradeFixtureInstall(NSString *source,NSString *prefix,NSDictionary *manifest,BOOL started) {
  NSString *error=nil,*scripts=[source stringByAppendingPathComponent:@"scripts"];
  FixtureDirectory(prefix);CHECK(BeginClientInstallFromScripts(prefix,geteuid(),NO,scripts,&error));CopyFreshPayload(source,prefix,manifest);
  NSString *inbox=At(prefix,[State stringByAppendingPathComponent:@"Inbox"]);
  for(NSString *name in @[@"helper",@"mihomo",@"dev.kuro.tun.plist"])Put([inbox stringByAppendingPathComponent:name],[NSData dataWithContentsOfFile:[scripts stringByAppendingPathComponent:[name isEqual:@"helper"]?@"preflight-native":name]],[name isEqual:@"dev.kuro.tun.plist"]?0600:0755);
  NSData *helper=[NSData dataWithContentsOfFile:[scripts stringByAppendingPathComponent:@"preflight-native"]];Put(At(prefix,Recovery),helper,0755);Put([At(prefix,Tools)stringByAppendingPathComponent:@"installer"],helper,0755);
  NSString *client=At(prefix,ClientBundle);FixtureDirectory(client.stringByDeletingLastPathComponent);CHECK([[NSFileManager defaultManager]copyItemAtPath:[source stringByAppendingPathComponent:@"fixture.app"] toPath:client error:NULL]);
  CHECK(Install(prefix,geteuid(),NO,&error));CHECK(!chmod(At(prefix,Tools).fileSystemRepresentation,0755)); // Match the package BOM.
  if(started)UpgradeFixtureStopped(prefix,manifest);
}
static void UpgradeFixturePayload(NSString *source,NSString *prefix) {
  NSString *scripts=[source stringByAppendingPathComponent:@"scripts"],*payload=[UpgradeRoot(prefix)stringByAppendingPathComponent:@"Payload"],*inbox=[payload stringByAppendingPathComponent:@"Inbox"];
  for(NSString *name in @[@"helper",@"mihomo",@"manifest.json",@"client-inventory.json",@"dev.kuro.tun.plist"])Put([inbox stringByAppendingPathComponent:name],[NSData dataWithContentsOfFile:[scripts stringByAppendingPathComponent:[name isEqual:@"helper"]?@"preflight-native":name]],[name isEqual:@"helper"]||[name isEqual:@"mihomo"]?0755:0600);
  CHECK([[NSFileManager defaultManager]copyItemAtPath:[source stringByAppendingPathComponent:@"fixture.app"]toPath:[payload stringByAppendingPathComponent:@"Client.app"]error:NULL]);
}
static BOOL UpgradeFixtureRecoverCLI(NSString *prefix) {
  NSString *entry=At(prefix,Recovery);pid_t child;char *arguments[]={(char*)entry.fileSystemRepresentation,"--upgrade-recover-fixture",(char*)prefix.fileSystemRepresentation,NULL},*environment[]={"PATH=/usr/bin:/bin","LANG=C","KURO_SKIP_CORE_SYNTAX=1",NULL};
  if(posix_spawn(&child,arguments[0],NULL,NULL,arguments,environment))return NO;int status;return waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status);
}
// Read-only bridge: consumes the real JS packager output, not a second hand-built mode fixture.
static BOOL UpgradePackageLayoutFixture(NSString *root,NSString *operation,NSString **error) {
  if(geteuid()==0||![@[@"fresh",@"upgrade"]containsObject:operation])return Fail(error,@"ordinary-user fixed package layout fixture required");
  BOOL next=[operation isEqual:@"upgrade"];NSString *container=next?[UpgradeRoot(root)stringByAppendingPathComponent:@"Payload"]:At(root,State),*inbox=[container stringByAppendingPathComponent:@"Inbox"];
  NSData *manifestBytes=ReadProtected(root,[inbox stringByAppendingPathComponent:@"manifest.json"],geteuid(),error),*inventoryBytes=ReadProtected(root,[inbox stringByAppendingPathComponent:@"client-inventory.json"],geteuid(),error),*plist=ReadProtected(root,[inbox stringByAppendingPathComponent:@"dev.kuro.tun.plist"],geteuid(),error);
  NSDictionary *manifest=manifestBytes?KuroDecodeJSON(manifestBytes,MessageLimit,error):nil,*inventory=inventoryBytes?KuroDecodeJSON(inventoryBytes,InventoryLimit,error):nil;
  if(!manifest||!inventory||!plist||!InventoryEntries(inventory,error)||!Match(manifest[@"helper"][@"sha256"],@"\\A[a-f0-9]{64}\\z")||!Match(manifest[@"core"][@"sha256"],@"\\A[a-f0-9]{64}\\z"))return Fail(error,@"complete package layout sidecars required");
  NSDictionary *receipt=@{@"manifest":manifest,@"inventory":inventory,@"manifestBytes":manifestBytes,@"inventoryBytes":inventoryBytes,@"plist":plist},*decoded=@{@"old":receipt};
  if(!UpgradeTree(root,inbox,geteuid(),UpgradeEntries(decoded,NO,@"inbox"),YES,error)||!UpgradeTree(root,next?[container stringByAppendingPathComponent:@"Client.app"]:At(root,ClientBundle),geteuid(),UpgradeEntries(decoded,NO,@"client"),YES,error))return NO;
  if(!next){for(NSString *path in @[At(root,Recovery),[At(root,Tools)stringByAppendingPathComponent:@"installer"]])if(!UpgradeTree(root,path,geteuid(),@{@"":UpgradeFile(manifest[@"helper"][@"sha256"],0755)},YES,error))return NO;}
  else if(Exists(At(root,Tools))||Exists(At(root,Recovery)))return Fail(error,@"upgrade package overwrites current protected executable");
  puts("actual packager tree accepted by native UpgradeEntries/UpgradeTree; Inbox plist0600, exact resource hashes/modes and client inventory checked; layout only, not system install");return YES;
}
static void UpgradeTests(void) {
  CHECK(geteuid()!=0);alarm(180);NSString *error=nil;
  char temporary[]="/tmp/kuro-upgrade-XXXXXX",canonical[PATH_MAX];CHECK(mkdtemp(temporary)&&realpath(temporary,canonical));NSString *base=@(canonical);
  NSString *oldSource=[base stringByAppendingPathComponent:@"old-source"],*newSource=[base stringByAppendingPathComponent:@"new-source"],*thirdSource=[base stringByAppendingPathComponent:@"third-source"];
  NSString *oldBinary=[base stringByAppendingPathComponent:@"old-helper"];Put(oldBinary,[NSData dataWithContentsOfFile:Executable()],0755);
  char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime","-i","dev.kuro.fixture.upgrade-old",(char*)oldBinary.fileSystemRepresentation,NULL},*environment[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t child;int status;
  CHECK(!posix_spawn(&child,sign[0],NULL,NULL,sign,environment));CHECK(waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status));
  NSDictionary *oldManifest=UpgradeFixtureSource(oldSource,@"upgrade-old",@"old approved App",[NSData dataWithContentsOfFile:oldBinary]);
  NSDictionary *newManifest=UpgradeFixtureSource(newSource,@"upgrade-next",@"new approved App",[NSData dataWithContentsOfFile:Executable()]);
  NSDictionary *thirdManifest=UpgradeFixtureSource(thirdSource,@"upgrade-third",@"third approved App",[NSData dataWithContentsOfFile:Executable()]);(void)thirdManifest;
  NSString *oldBlueprint=[base stringByAppendingPathComponent:@"never"],*stoppedBlueprint=[base stringByAppendingPathComponent:@"stopped"];
  UpgradeFixtureInstall(oldSource,oldBlueprint,oldManifest,NO);UpgradeFixtureInstall(oldSource,stoppedBlueprint,oldManifest,YES);
  NSString *scripts=[newSource stringByAppendingPathComponent:@"scripts"];
  // Successful real-file upgrade for both histories, exact immediate uninstall, and a second bounded upgrade.
  for(NSUInteger history=0;history<2;history++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"success%lu",(unsigned long)history]];
    CHECK([[NSFileManager defaultManager]copyItemAtPath:history?stoppedBlueprint:oldBlueprint toPath:prefix error:NULL]);
    BOOL began=BeginClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error);if(!began)fprintf(stderr,"begin: %s\n",error.UTF8String);CHECK(began);UpgradeFixturePayload(newSource,prefix);
    BOOL completed=CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error);if(!completed)fprintf(stderr,"upgrade success history%lu: %s\n",(unsigned long)history,error.UTF8String);CHECK(completed);
    NSDictionary *installed=ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL);CHECK([installed[@"release"]isEqual:newManifest[@"release"]]);CHECK([installed[@"neverStarted"]boolValue]==!history);
    CHECK(!Exists(At(prefix,RecoveryRecord))&&!Exists(UpgradeRoot(prefix))&&!Exists(UpgradeMarker(prefix)));CHECK(UpgradeFixtureRecoverCLI(prefix));
    if(history) {
      NSDictionary *receipt=ReadFreshReceipt(prefix,geteuid(),&error),*proof=ReadJSON(prefix,UpgradeCurrent(prefix,@"stopped"),geteuid(),NULL);CHECK(receipt[@"upgrade"]&&KuroStoppedBoundToReceipt(proof,receipt,installed));CHECK(!KuroCompletedStopEvidence(proof));
      for(NSString *key in @[@"transaction",@"helperSHA256",@"previousStoppedSHA256",@"newCoreNeverStarted"]) {NSMutableDictionary *bad=[proof mutableCopy];bad[key]=[key isEqual:@"newCoreNeverStarted"]?@1:@"wrong";CHECK(!KuroUpgradeOffValid(bad,receipt[@"manifest"],receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed));}
      NSString *thirdScripts=[thirdSource stringByAppendingPathComponent:@"scripts"],*nextHelper=[At(prefix,Tools)stringByAppendingPathComponent:@"versions/upgrade-next/helper"];
      CHECK(KuroMarkSessionStarted(prefix,geteuid(),nextHelper,&error));CHECK(!Exists(UpgradeCurrent(prefix,@"stopped")));CHECK([ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
      CHECK(!BeginClientUpgradeFromScripts(prefix,geteuid(),NO,thirdScripts,&error));CHECK(!Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!UpgradeFixtureRecoverCLI(prefix));
      UpgradeFixtureStopped(prefix,newManifest);CHECK([ReadJSON(prefix,UpgradeCurrent(prefix,@"stopped"),geteuid(),NULL)[@"format"]isEqual:@1]);
      CHECK(BeginClientUpgradeFromScripts(prefix,geteuid(),NO,thirdScripts,&error));UpgradeFixturePayload(thirdSource,prefix);CHECK(CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,thirdScripts,&error));
      CHECK([ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);
    }
    CHECK(Uninstall(prefix,geteuid(),NO,At(prefix,Recovery),&error));CHECK(!Exists(At(prefix,Tools))&&!Exists(At(prefix,State))&&!Exists(At(prefix,Recovery))&&!Exists(At(prefix,FreshReceipt))&&!Exists(At(prefix,ClientBundle)));
    CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
  }
  // Refuse unapproved metadata/ownership before issuing an upgrade approval.
  for(NSUInteger scenario=0;scenario<24;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"reject%lu",(unsigned long)scenario]];CHECK([[NSFileManager defaultManager]copyItemAtPath:stoppedBlueprint toPath:prefix error:NULL]);
    NSData *newManifestBytes=[NSData dataWithContentsOfFile:[scripts stringByAppendingPathComponent:@"manifest.json"]];
    if(scenario<=4){NSMutableDictionary *bad=[newManifest mutableCopy];if(!scenario)[bad removeObjectForKey:@"installerProtocol"];else bad[@"installerProtocol"]=scenario==1?@3:scenario==2?@YES:scenario==3?@"2":NSNull.null;Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(bad),0600);}
    if(scenario==5||scenario==6){
      NSMutableDictionary *raw=[KuroDecodeJSON(ReadProtected(prefix,At(prefix,FreshReceipt),geteuid(),NULL),InventoryLimit*2,NULL)mutableCopy],*old=[oldManifest mutableCopy];
      if(scenario==5)[old removeObjectForKey:@"installerProtocol"];else old[@"installerProtocol"]=@3;
      NSData *changed=JSONData(old);raw[@"manifestJSON"]=UpgradeString(changed);Put(At(prefix,FreshReceipt),JSONData(raw),0600);
      for(NSString *path in @[[[At(prefix,Tools)stringByAppendingPathComponent:@"versions/upgrade-old"]stringByAppendingPathComponent:@"manifest.json"],At(prefix,[State stringByAppendingPathComponent:@"Inbox/manifest.json"])])Put(path,changed,0600);
    }
    NSArray *footprints=@[@"owner.json",@"network.json",@"network-dns.json",@"auth-observer.json",@"session-work",@"unknown"];
    if(scenario>=7&&scenario<=12)Put(At(prefix,[State stringByAppendingPathComponent:footprints[scenario-7]]),Bytes(@"unknown preserve"),0600);
    if(scenario==13)CHECK(!unlink(UpgradeCurrent(prefix,@"stopped").fileSystemRepresentation));
    if(scenario==14)Put(UpgradeCurrent(prefix,@"stopped"),Bytes(@"{}"),0600);
    if(scenario==15)Put([UpgradeCurrent(prefix,@"tools")stringByAppendingPathComponent:@"installer"],Bytes(@"changed helper"),0755);
    if(scenario==16)Put([At(prefix,ClientBundle)stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"changed App"),0644);
    if(scenario==17)Put(At(prefix,[State stringByAppendingPathComponent:@"Inbox/client-inventory.json"]),Bytes(@"{}"),0600);
    if(scenario==18)Put(At(prefix,FreshReceipt),Bytes(@"{}"),0600);
    if(scenario==19)Put(At(prefix,[SocketDirectory stringByAppendingPathComponent:@"auth.sock"]),Bytes(@"unknown"),0600);
    if(scenario==20)CHECK(!chmod(UpgradeCurrent(prefix,@"tools").fileSystemRepresentation,0777));
    if(scenario==21) {NSMutableDictionary *bad=[newManifest mutableCopy];bad[@"release"]=oldManifest[@"release"];Put([scripts stringByAppendingPathComponent:@"manifest.json"],JSONData(bad),0600);}
    if(scenario==22) {NSString *target=[prefix stringByAppendingPathComponent:@"original-tools"];CHECK(!rename(UpgradeCurrent(prefix,@"tools").fileSystemRepresentation,target.fileSystemRepresentation));CHECK(!symlink(target.fileSystemRepresentation,UpgradeCurrent(prefix,@"tools").fileSystemRepresentation));}
    int held=scenario==23?ServiceLock(prefix,geteuid(),&error):-1;if(scenario==23)CHECK(held>=0);
    // Metadata-only snapshot tolerates a deliberately unsafe object in rejection fixtures.
    NSDictionary *before=UpgradeFixtureRawTree(prefix);
    CHECK(!BeginClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK(!Exists(At(prefix,RecoveryRecord)));CHECK([UpgradeFixtureRawTree(prefix)isEqual:before]);
    if(held>=0)close(held);Put([scripts stringByAppendingPathComponent:@"manifest.json"],newManifestBytes,0600);
    CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
  }
  // Missing whole approved files are removable subsets; truncated/changed bytes remain blocked. Unknown/link content is preserved.
  for(NSUInteger scenario=0;scenario<5;scenario++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"stage%lu",(unsigned long)scenario]];CHECK([[NSFileManager defaultManager]copyItemAtPath:stoppedBlueprint toPath:prefix error:NULL]);
    NSDictionary *oldTree=InventoryEntries(FixtureInventory(prefix),NULL);CHECK(BeginClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error));UpgradeFixturePayload(newSource,prefix);
    NSString *app=[UpgradeRoot(prefix)stringByAppendingPathComponent:@"Payload/Client.app"],*resource=[app stringByAppendingPathComponent:@"Contents/Resources/app.asar"],*unknown=[app stringByAppendingPathComponent:@"unknown"],*outside=[base stringByAppendingPathComponent:@"outside-protected"];
    Put(outside,Bytes(@"outside unchanged"),0600);NSData *original=[NSData dataWithContentsOfFile:resource];
    if(scenario==0)CHECK(!unlink(resource.fileSystemRepresentation));
    if(scenario==1)Put(unknown,Bytes(@"unknown preserve"),0600);
    if(scenario==2)Put(resource,Bytes(@"changed preserve"),0644);
    if(scenario==3){CHECK(!unlink(resource.fileSystemRepresentation));CHECK(!symlink(outside.fileSystemRepresentation,resource.fileSystemRepresentation));}
    if(scenario==4)CHECK(!chmod(resource.fileSystemRepresentation,0666));
    CHECK(!CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error));
    if(scenario){CHECK(!UpgradeFixtureRecoverCLI(prefix));CHECK([ReadProtected(base,outside,geteuid(),NULL)isEqual:Bytes(@"outside unchanged")]);
      if(scenario==1)CHECK(!unlink(unknown.fileSystemRepresentation));
      if(scenario==3)CHECK(!unlink(resource.fileSystemRepresentation));
      if(scenario!=1)Put(resource,original,0644);
    }
    CHECK(UpgradeFixtureRecoverCLI(prefix));CHECK([InventoryEntries(FixtureInventory(prefix),NULL)isEqual:oldTree]);CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
  }

  // Installer interruption inside a file is deliberately NOT an approved subset. No arbitrary bytes are deleted.
  for(NSString *name in @[@"helper",@"mihomo"]) {
    NSString *prefix=[base stringByAppendingPathComponent:[@"truncated-"stringByAppendingString:name]];CHECK([[NSFileManager defaultManager]copyItemAtPath:stoppedBlueprint toPath:prefix error:NULL]);
    CHECK(BeginClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error));UpgradeFixturePayload(newSource,prefix);
    NSString *leaf=[[UpgradeRoot(prefix)stringByAppendingPathComponent:@"Payload/Inbox"]stringByAppendingPathComponent:name];NSData *complete=[NSData dataWithContentsOfFile:leaf];CHECK(complete.length>64);
    int fd=open(leaf.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW);CHECK(fd>=0);CHECK(!ftruncate(fd,64));CHECK(!fsync(fd));close(fd);
    NSDictionary *before=UpgradeFixtureRawTree(prefix);CHECK(!CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error));CHECK(!UpgradeFixtureRecoverCLI(prefix));CHECK([UpgradeFixtureRawTree(prefix)isEqual:before]);
    CHECK(Exists(At(prefix,RecoveryRecord))&&Exists(UpgradeRoot(prefix))&&Exists(UpgradeMarker(prefix)));CHECK([[ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL)objectForKey:@"release"]isEqual:oldManifest[@"release"]]);
    fprintf(stderr,"truncated staged %s: recovery refused; entire original installation, approval and truncated payload preserved\n",name.UTF8String);
    // Test-only restoration of the known complete fixture permits subsequent exact rollback; production does not repair unknown bytes.
    Put(leaf,complete,0755);CHECK(UpgradeFixtureRecoverCLI(prefix));CHECK([InventoryEntries(FixtureInventory(prefix),NULL)isEqual:InventoryEntries(FixtureInventory(stoppedBlueprint),NULL)]);CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
  }

  // Record deterministic successful fault points once, then interrupt every point and invoke the actual fixed recovery executable.
  NSMutableArray *points=[NSMutableArray array];NSString *sample=[base stringByAppendingPathComponent:@"sample"];
  CHECK([[NSFileManager defaultManager]copyItemAtPath:stoppedBlueprint toPath:sample error:NULL]);
  UpgradeFault=^BOOL(NSString *point){[points addObject:point];return YES;};CHECK(BeginClientUpgradeFromScripts(sample,geteuid(),NO,scripts,&error));UpgradeFixturePayload(newSource,sample);CHECK(CompleteClientUpgradeFromScripts(sample,geteuid(),NO,scripts,&error));UpgradeFault=nil;
  CHECK([[NSFileManager defaultManager]removeItemAtPath:sample error:NULL]);
  NSDictionary *baseline=InventoryEntries(FixtureInventory(stoppedBlueprint),NULL);
  for(NSUInteger point=0;point<points.count;point++) {
    NSString *prefix=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"interrupt%lu",(unsigned long)point]];CHECK([[NSFileManager defaultManager]copyItemAtPath:stoppedBlueprint toPath:prefix error:NULL]);
    __block NSUInteger index=0;UpgradeFault=^BOOL(NSString *name){(void)name;return index++!=point;};
    BOOL began=BeginClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error),completed=NO;
    if(began){UpgradeFixturePayload(newSource,prefix);completed=CompleteClientUpgradeFromScripts(prefix,geteuid(),NO,scripts,&error);}CHECK(!completed);UpgradeFault=nil;
    NSDictionary *record=UpgradeRead(prefix,geteuid(),&error);CHECK(record);BOOL forward=[record[@"phase"]isEqual:@"finalizing"];
    BOOL recovered=UpgradeFixtureRecoverCLI(prefix);if(!recovered)fprintf(stderr,"recovery failed point%lu %s phase %s\n",(unsigned long)point,[points[point]UTF8String],[record[@"phase"]UTF8String]);
    CHECK(recovered);CHECK(UpgradeFixtureRecoverCLI(prefix));
    if(!forward)CHECK([InventoryEntries(FixtureInventory(prefix),NULL)isEqual:baseline]);
    else {CHECK([ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL)[@"release"]isEqual:newManifest[@"release"]]);CHECK([ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),geteuid(),NULL)[@"neverStarted"]isEqual:@NO]);}
    CHECK(!Exists(At(prefix,RecoveryRecord))&&!Exists(UpgradeRoot(prefix))&&!Exists(UpgradeMarker(prefix)));CHECK([[NSFileManager defaultManager]removeItemAtPath:prefix error:NULL]);
  }
  printf("native upgrade: both histories success, repeated upgrade and immediate uninstall; %lu deterministic approval/prepare/rename/sync/forward-cleanup/retirement interruptions recovered via exact protected executable; no Core/system/network\n",(unsigned long)points.count);
  CHECK([[NSFileManager defaultManager]removeItemAtPath:base error:NULL]);
}
