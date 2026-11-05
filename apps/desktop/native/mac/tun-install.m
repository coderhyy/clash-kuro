// Fixed administrator installation and exact recorded cleanup; no caller-supplied paths.
static NSString *const FreshReceipt = @"/Library/PrivilegedHelperTools/dev.kuro.tun-fresh-install.json";
static int Launchctl(NSArray *arguments) {
  pid_t child;
  NSMutableArray *strings = [NSMutableArray arrayWithObject:@"/bin/launchctl"];
  [strings addObjectsFromArray:arguments];
  char *argv[strings.count + 1];
  for (NSUInteger i = 0; i < strings.count; i++) argv[i] = (char *)[strings[i] UTF8String];
  argv[strings.count] = NULL;
  char *environment[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  int result = posix_spawn(&child, "/bin/launchctl", &actions, NULL, argv, environment);
  posix_spawn_file_actions_destroy(&actions);
  if (result) return -1;
  for (int i = 0; i < 100; i++) {
    int status;
    pid_t done = waitpid(child, &status, WNOHANG);
    if (done == child) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (done < 0 && errno != EINTR) return -1;
    struct timespec pause = {0, 50000000}; nanosleep(&pause, NULL);
  }
  kill(child, SIGKILL); waitpid(child, NULL, 0);
  return -1;
}
static BOOL StopService(BOOL system, NSString **error) {
  if (!system) return YES;
  int present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
  if (present == 3 || present == 113) return YES;
  if (present != 0 || Launchctl(@[@"bootout", @"system/dev.kuro.tun"]) != 0) return Fail(error, @"cannot prove service stopped; installation preserved");
  present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
  return (present == 3 || present == 113) || Fail(error, @"service absence not confirmed");
}
static BOOL PreflightInstall(NSString *prefix, uid_t owner, BOOL system, NSString **error) {
  NSString *legacy=At(prefix,LegacySocketDirectory);
  if(Exists(legacy))return Fail(error,[NSString stringWithFormat:@"legacy endpoint directory %@ is preserved; fresh install refused",legacy]);
  if(!SocketAncestorsProtected(prefix,owner,NO,error))return NO;
  for (NSString *target in @[Tools, State, SocketDirectory, Plist, Recovery, RecoveryRecord, FreshReceipt]) {
    NSString *path = At(prefix, target);
    if (Exists(path)) return Fail(error, [NSString stringWithFormat:@"existing or partial helper install at %@ preserved; fresh install refused",path]);
    NSString *current = prefix.length ? prefix : @"/";
    if (!SafeNode(current, owner, YES, error)) return NO;
    for (NSString *component in target.pathComponents) {
      if ([component isEqual:@"/"]) continue;
      current = [current stringByAppendingPathComponent:component];
      if (!Exists(current)) break;
      if (!SafeNode(current, owner, YES, error)) return NO;
    }
  }
  if (system) {
    int present = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
    if (present != 3 && present != 113) return Fail(error, @"service absence not proven; install refused");
  }
  return YES;
}
static BOOL ValidManifest(NSDictionary *manifest, NSString **error) {
  if (![manifest isKindOfClass:NSDictionary.class])return Fail(error,@"manifest must be an object");
  NSArray *manifestKeys = @[@"format", @"label", @"release", @"target", @"protocol", @"activationAllowed", @"core", @"helper"];
  if (manifest[@"installerProtocol"]) manifestKeys = [manifestKeys arrayByAddingObject:@"installerProtocol"];
  if (manifest[@"client"]) manifestKeys = [manifestKeys arrayByAddingObject:@"client"];
  if (manifest[@"clientInventorySHA256"]) manifestKeys = [manifestKeys arrayByAddingObject:@"clientInventorySHA256"];
  if (!Keys(manifest, manifestKeys) || (manifest[@"installerProtocol"] && !KuroNumber(manifest[@"installerProtocol"],2,2)) || (manifest[@"client"] && !KuroClientPinValid(manifest[@"client"])) ||
      ((manifest[@"client"]!=nil)!=(manifest[@"clientInventorySHA256"]!=nil)) ||
      (manifest[@"clientInventorySHA256"] && !Match(manifest[@"clientInventorySHA256"], @"\\A[0-9a-f]{64}\\z")) ||
      !KuroNumber(manifest[@"format"],1,1) || !KuroNumber(manifest[@"protocol"],1,1) || ![manifest[@"label"] isEqual:Label] || !KuroBool(manifest[@"activationAllowed"]) ||
      ([manifest[@"activationAllowed"]boolValue] && (!manifest[@"client"] || !manifest[@"clientInventorySHA256"])) ||
      !Match(manifest[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") ||
      !Keys(manifest[@"core"], @[@"file", @"version", @"sha256", @"archiveSha256"]) || !Keys(manifest[@"helper"], @[@"file", @"version", @"sha256"]) ||
      ![manifest[@"core"][@"file"] isEqual:@"mihomo"] || ![manifest[@"helper"][@"file"] isEqual:@"helper"] ||
      !Match(manifest[@"core"][@"sha256"], @"\\A[0-9a-f]{64}\\z") || !Match(manifest[@"helper"][@"sha256"], @"\\A[0-9a-f]{64}\\z")) return Fail(error, @"invalid fixed payload manifest");
#if defined(__arm64__)
  NSString *target = @"darwin-arm64";
#else
  NSString *target = @"darwin-x64";
#endif
  return [manifest[@"target"] isEqual:target] || Fail(error, @"payload architecture does not match installer");
}
static BOOL FixedPlist(NSData *data, NSString *release, NSString **error) {
  NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
  NSString *program = [[Tools stringByAppendingPathComponent:@"versions"] stringByAppendingPathComponent:[release stringByAppendingPathComponent:@"helper"]];
  return (Keys(plist, @[@"Label", @"ProgramArguments", @"Disabled", @"RunAtLoad", @"KeepAlive", @"AbandonProcessGroup"]) && [plist[@"Label"] isEqual:Label] &&
    [plist[@"ProgramArguments"] isEqual:@[program, @"--serve"]] && [plist[@"Disabled"] isEqual:@YES] && [plist[@"RunAtLoad"] isEqual:@NO] && [plist[@"KeepAlive"] isEqual:@NO] && [plist[@"AbandonProcessGroup"] isEqual:@NO]) || Fail(error, @"plist must be fixed and disabled");
}
static BOOL ProveNeverStarted(NSString *prefix, uid_t owner, NSDictionary **record, NSString **error) {
  *record = ReadJSON(prefix, At(prefix, [State stringByAppendingPathComponent:@"installed.json"]), owner, error);
  if (!Keys(*record, @[@"format", @"release", @"helperSHA256", @"neverStarted"]) || ![(*record)[@"format"] isEqual:@1] || ![(*record)[@"neverStarted"] isEqual:@YES] ||
      !Match((*record)[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") || HasOwnershipFootprint(prefix)) return Fail(error, @"no proven off ownership record; cleanup refused");
  return YES;
}
static BOOL MachExecutable(NSData *data) {
  uint32_t header[8];
  if (data.length < sizeof(header)) return NO;
  memcpy(header, data.bytes, sizeof(header));
#if defined(__arm64__)
  uint32_t cpu = 0x0100000c;
#else
  uint32_t cpu = 0x01000007;
#endif
  return header[0] == 0xfeedfacf && header[1] == cpu && header[3] == 2;
}
static int ServiceLock(NSString *prefix, uid_t owner, NSString **error) {
  NSString *directory = At(prefix, SocketDirectory);
  if (!SocketAncestorsProtected(prefix,owner,NO,error) || !EnsureDirectory(prefix, directory, owner, 0755, error) || !SocketAncestorsProtected(prefix,owner,YES,error)) return -1;
  NSString *path = [directory stringByAppendingPathComponent:@"service.lock"];
  int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat info;
  if (fd < 0 || fstat(fd, &info) || !SafeMetadata(info, owner, NO) || (info.st_mode & 0777) != 0600 ||
      !SafeChain(prefix, path, owner, NO, error) || flock(fd, LOCK_EX | LOCK_NB)) {
    if (fd >= 0) close(fd);
    Fail(error, @"service lock unavailable; active or unknown helper preserved");
    return -1;
  }
  return fd;
}
static const NSUInteger InventoryLimit = 32 * 1024 * 1024;
static NSString *InstallFileHash(NSString *anchor, NSString *path, uid_t owner, NSString **error) {
  if (!SafeChain(anchor,path,owner,NO,error)) return nil;
  int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC); struct stat before,after;
  if(fd<0 || fstat(fd,&before) || !SafeMetadata(before,owner,NO)) { if(fd>=0)close(fd); Fail(error,@"unprotected inventory file");return nil; }
  CC_SHA256_CTX context; CC_SHA256_Init(&context); unsigned char buffer[65536]; off_t count=0; BOOL ok=YES;
  for(;;) { ssize_t size=read(fd,buffer,sizeof(buffer)); if(size<0&&errno==EINTR)continue; if(size<0) {ok=NO;break;} if(!size)break; CC_SHA256_Update(&context,buffer,(CC_LONG)size); count+=size; }
  ok=ok && !fstat(fd,&after) && count==before.st_size && before.st_dev==after.st_dev && before.st_ino==after.st_ino && before.st_size==after.st_size && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec && SafeMetadata(after,owner,NO);
  close(fd); unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&context);
  if(!ok) {Fail(error,@"inventory file changed while reading");return nil;} return Hex([NSData dataWithBytes:digest length:sizeof(digest)]);
}
static BOOL InventoryPath(id path, BOOL root) {
  if(root && [path isEqual:@""])return YES;
  if(!KuroText(path,4096) || [path isAbsolutePath] || ![[path stringByStandardizingPath] isEqual:path])return NO;
  for(NSString *part in [path componentsSeparatedByString:@"/"])if(!part.length || [part isEqual:@"."] || [part isEqual:@".."])return NO;
  return YES;
}
static NSDictionary *InventoryEntries(NSDictionary *inventory,NSString **error) {
  if(!Keys(inventory,@[@"format",@"directories",@"files",@"links"]) || !KuroNumber(inventory[@"format"],1,1)) {Fail(error,@"invalid client inventory envelope");return nil;}
  NSMutableDictionary *entries=[NSMutableDictionary dictionary];
  for(NSString *kind in @[@"directories",@"files",@"links"]) {
    if(!KuroArray(inventory[kind],100000,NO)) {Fail(error,@"invalid inventory list");return nil;}
    for(id item in inventory[kind]) {
      NSArray *keys=[kind isEqual:@"files"]?@[@"path",@"mode",@"sha256"]:[kind isEqual:@"links"]?@[@"path",@"target"]:@[@"path",@"mode"];
      if(!Keys(item,keys) || !InventoryPath(item[@"path"],[kind isEqual:@"directories"]) || entries[item[@"path"]] || entries.count>=100000) {Fail(error,@"duplicate or unsafe inventory path");return nil;}
      if([kind isEqual:@"links"]) {
        NSString *path=item[@"path"],*target=item[@"target"];
        NSString *resolved=[[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:([target isKindOfClass:NSString.class]?target:@"")] stringByStandardizingPath];
        if(![path hasPrefix:@"Contents/Frameworks/"] || !KuroText(target,4096) || [target isAbsolutePath] || ![resolved hasPrefix:@"Contents/Frameworks/"]) {Fail(error,@"inventory link escapes Frameworks");return nil;}
      } else if(!KuroNumber(item[@"mode"],0,0777) || ([item[@"mode"] unsignedIntValue]&06022) || ([kind isEqual:@"directories"] && !([item[@"mode"] unsignedIntValue]&0100)) || ([kind isEqual:@"files"] && !Match(item[@"sha256"],@"\\A[0-9a-f]{64}\\z"))) {Fail(error,@"unsafe inventory mode or hash");return nil;}
      NSMutableDictionary *entry=[item mutableCopy];entry[@"kind"]=kind;entries[item[@"path"]]=entry;
    }
  }
  if(![entries[@""][@"kind"] isEqual:@"directories"]) {Fail(error,@"inventory root missing");return nil;}
  for(NSString *path in entries)if(path.length) {
    NSString *parent=[path containsString:@"/"]?path.stringByDeletingLastPathComponent:@"";
    if(![entries[parent][@"kind"] isEqual:@"directories"]) {Fail(error,@"inventory parent is not an explicit directory");return nil;}
  }
  return entries;
}
static BOOL ClientSubset(NSString *prefix,uid_t owner,NSDictionary *entries,NSString *relative,NSString **error) {
  NSString *bundle=At(prefix,ClientBundle),*path=relative.length?[bundle stringByAppendingPathComponent:relative]:bundle;
  if(!Exists(path))return YES;
  NSDictionary *entry=entries[relative]; struct stat info;
  if(!entry || lstat(path.fileSystemRepresentation,&info) || info.st_uid!=owner) return Fail(error,@"unknown client entry or changed ownership preserved");
  if([entry[@"kind"] isEqual:@"links"]) {
    char target[PATH_MAX];ssize_t size=readlink(path.fileSystemRepresentation,target,sizeof(target)-1);
    if(!S_ISLNK(info.st_mode) || info.st_nlink!=1 || size<1 || size>=PATH_MAX-1)return Fail(error,@"changed client link preserved");target[size]=0;
    return [[NSString stringWithUTF8String:target] isEqual:entry[@"target"]] || Fail(error,@"changed client link target preserved");
  }
  BOOL directory=[entry[@"kind"] isEqual:@"directories"];
  if(!SafeChain(prefix,path,owner,directory,error) || (info.st_mode&07777)!=[entry[@"mode"] unsignedIntValue])return Fail(error,@"changed client type, permissions or ACL preserved");
  if(!directory)return [InstallFileHash(prefix,path,owner,error) isEqual:entry[@"sha256"]] || Fail(error,@"changed client bytes preserved");
  NSArray *children=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];if(!children)return Fail(error,@"cannot enumerate partial client");
  for(NSString *child in children)if(!ClientSubset(prefix,owner,entries,relative.length?[relative stringByAppendingPathComponent:child]:child,error))return NO;
  return YES;
}
static BOOL RemoveClientSubset(NSString *prefix,uid_t owner,NSDictionary *entries,NSString **error) {
  if(!ClientSubset(prefix,owner,entries,@"",error))return NO;
  NSString *bundle=At(prefix,ClientBundle);
  // Unlink approved links first, never traversing them. Missing files are a valid partial-copy state.
  for(NSString *kind in @[@"links",@"files"])for(NSString *relative in entries)if([entries[relative][@"kind"] isEqual:kind]) {
    NSString *path=[bundle stringByAppendingPathComponent:relative];if(!Exists(path))continue;
    if(!ClientSubset(prefix,owner,entries,relative,error) || unlink(path.fileSystemRepresentation))return Fail(error,@"client removal failed; fresh receipt retained");
  }
  NSArray *paths=[[entries allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b) {return a.length>b.length?NSOrderedAscending:a.length<b.length?NSOrderedDescending:[b compare:a];}];
  for(NSString *relative in paths)if([entries[relative][@"kind"] isEqual:@"directories"]) {
    NSString *path=relative.length?[bundle stringByAppendingPathComponent:relative]:bundle;if(!Exists(path))continue;
    if(!SafeChain(prefix,path,owner,YES,error) || rmdir(path.fileSystemRepresentation))return Fail(error,@"client directory not empty; preserved");
  }
  return !Exists(bundle) || Fail(error,@"client removal not proven");
}
static BOOL SyncInstallDirectory(NSString *directory,NSString **error) {
  int fd=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);BOOL ok=fd>=0&&!fsync(fd);if(fd>=0)close(fd);return ok||Fail(error,@"install receipt directory sync failed");
}
// Match SafeNode's ACL policy, including macOS's NULL representation of no ACL.
// Never treat acl_get_file failure alone as evidence that an ACL is absent.
static BOOL InstallScriptsEmptyACL(NSString *path,NSString **error) {
  acl_t acl=acl_get_file(path.fileSystemRepresentation,ACL_TYPE_EXTENDED);
  if(!acl) {
    struct attrlist attributes={.bitmapcount=ATTR_BIT_MAP_COUNT,.commonattr=ATTR_CMN_EXTENDED_SECURITY};
    struct {uint32_t length;attrreference_t security;char data[65536];} result={0};
    if(!getattrlist(path.fileSystemRepresentation,&attributes,&result,sizeof(result),FSOPT_NOFOLLOW) && result.length>=sizeof(uint32_t)+sizeof(attrreference_t) && result.security.attr_length==0)return YES;
    return Fail(error,[NSString stringWithFormat:@"unable to verify Installer temporary ancestor ACL: %@",path]);
  }
  acl_entry_t entry;BOOL valid=acl_valid(acl)==0;errno=0;
  BOOL empty=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1&&errno==EINVAL;
  acl_free(acl);
  return (valid&&empty)||Fail(error,[NSString stringWithFormat:@"Installer temporary ancestor ACL not approved: %@",path]);
}
// Installer extracts its root-owned scripts below /private/tmp on some macOS releases.
// Only that exact sticky root-owned ancestor is exempt from the non-writable rule.
static BOOL InstallScriptsProtected(NSString *scripts,uid_t owner,NSString **error) {
#ifdef KURO_TESTING
  if(owner==geteuid() && owner!=0)return SafeNode(scripts,owner,YES,error);
#endif
  if(owner!=0)return Fail(error,@"Installer scripts require the root owner");
  NSString *current=@"/";if(!SafeNode(current,0,YES,error))return NO;
  for(NSString *part in scripts.pathComponents) {
    if([part isEqual:@"/"])continue;current=[current stringByAppendingPathComponent:part];
    if([current isEqual:@"/private/tmp"]) {
      struct stat info;if(lstat(current.fileSystemRepresentation,&info)||info.st_uid!=0||!S_ISDIR(info.st_mode)||(info.st_mode&07777)!=01777)return Fail(error,@"unapproved Installer temporary ancestor");
      if(!InstallScriptsEmptyACL(current,error))return NO;
    } else if(!SafeNode(current,0,YES,error))return NO;
  }
  return YES;
}
static BOOL KuroUpgradeOffValid(NSDictionary *proof,NSDictionary *manifest,NSData *manifestBytes,NSData *inventoryBytes,NSDictionary *installed) {
  if(!Keys(proof,@[@"format",@"kind",@"release",@"helperSHA256",@"coreSHA256",@"manifestSHA256",@"inventorySHA256",@"installedSHA256",@"transaction",@"previousRelease",@"previousManifestSHA256",@"previousStoppedSHA256",@"newCoreNeverStarted"]) || !KuroNumber(proof[@"format"],2,2) || ![proof[@"kind"]isEqual:@"upgrade-off"] ||
    !Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroBool(installed[@"neverStarted"]) || [installed[@"neverStarted"]boolValue] ||
    ![proof[@"release"]isEqual:installed[@"release"]] || ![proof[@"release"]isEqual:manifest[@"release"]] || ![proof[@"helperSHA256"]isEqual:installed[@"helperSHA256"]] || ![proof[@"helperSHA256"]isEqual:manifest[@"helper"][@"sha256"]] ||
    ![proof[@"coreSHA256"]isEqual:manifest[@"core"][@"sha256"]] || ![proof[@"manifestSHA256"]isEqual:Hash(manifestBytes)] || ![proof[@"inventorySHA256"]isEqual:Hash(inventoryBytes)] || ![proof[@"installedSHA256"]isEqual:Hash(JSONData(installed))] ||
    !Match(proof[@"transaction"],@"\\A[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\\z") || !Match(proof[@"previousRelease"],@"\\A[A-Za-z0-9.-]{1,120}\\z") || [proof[@"previousRelease"]isEqual:proof[@"release"]] ||
    !Match(proof[@"previousManifestSHA256"],@"\\A[0-9a-f]{64}\\z") || !Match(proof[@"previousStoppedSHA256"],@"\\A[0-9a-f]{64}\\z") || !KuroBool(proof[@"newCoreNeverStarted"]) || ![proof[@"newCoreNeverStarted"]boolValue])return NO;
  return YES;
}

static BOOL KuroStoppedProofValid(NSDictionary *proof,NSDictionary *manifest,NSData *manifestBytes,NSData *inventoryBytes,NSDictionary *installed) {
  if(!Keys(proof,@[@"format",@"release",@"helperSHA256",@"coreSHA256",@"manifestSHA256",@"inventorySHA256",@"installedSHA256",@"session",@"process",@"network"]) || !KuroNumber(proof[@"format"],1,1) ||
    !Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroNumber(installed[@"format"],1,1) || !KuroBool(installed[@"neverStarted"]) || [installed[@"neverStarted"]boolValue] ||
    ![proof[@"release"]isEqual:installed[@"release"]] || ![proof[@"release"]isEqual:manifest[@"release"]] || ![proof[@"helperSHA256"]isEqual:installed[@"helperSHA256"]] || ![proof[@"helperSHA256"]isEqual:manifest[@"helper"][@"sha256"]] ||
    ![proof[@"coreSHA256"]isEqual:manifest[@"core"][@"sha256"]] || ![proof[@"manifestSHA256"]isEqual:Hash(manifestBytes)] || ![proof[@"inventorySHA256"]isEqual:Hash(inventoryBytes)] || ![proof[@"installedSHA256"]isEqual:Hash(JSONData(installed))] ||
    !KuroCompletedStopEvidence(proof[@"process"]) || ![proof[@"session"]isEqual:proof[@"process"][@"session"]] || ![proof[@"coreSHA256"]isEqual:proof[@"process"][@"owner"][@"executableSHA256"]] ||
    ![proof[@"process"][@"owner"][@"launch"][@"template"]isEqual:@"macos-dual-stack-v1"])return NO;
  NSDictionary *network=proof[@"network"];
  if(!Keys(network,@[@"format",@"session",@"routesOff",@"dnsOff",@"routeJournalSHA256",@"dnsJournalSHA256"]) || !KuroNumber(network[@"format"],1,1) || ![network[@"session"]isEqual:proof[@"session"]])return NO;
  for(NSString *key in @[@"routesOff",@"dnsOff"])if(!KuroBool(network[key]) || ![network[key]boolValue])return NO;
  for(NSString *key in @[@"routeJournalSHA256",@"dnsJournalSHA256"])if(network[key]!=NSNull.null && !Match(network[key],@"\\A[0-9a-f]{64}\\z"))return NO;
  return YES;
}
static NSDictionary *DecodeFreshReceipt(NSData *raw,NSString **error) {
  id receipt=KuroDecodeJSON(raw,InventoryLimit*2,error);
  if(!KuroMapping(receipt,@[@"format",@"helperSHA256",@"manifestJSON",@"inventoryJSON",@"plistBase64"],@[@"uninstallJSON",@"upgradeJSON"]) || !KuroNumber(receipt[@"format"],1,1) || ![receipt[@"manifestJSON"] isKindOfClass:NSString.class] || ![receipt[@"inventoryJSON"] isKindOfClass:NSString.class] || ![receipt[@"plistBase64"] isKindOfClass:NSString.class]) {Fail(error,@"invalid fresh installation receipt");return nil;}
  NSData *manifestBytes=[receipt[@"manifestJSON"] dataUsingEncoding:NSUTF8StringEncoding],*inventoryBytes=[receipt[@"inventoryJSON"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *manifest=KuroDecodeJSON(manifestBytes,MessageLimit,error),*inventory=KuroDecodeJSON(inventoryBytes,InventoryLimit,error);NSData *plist=[[NSData alloc] initWithBase64EncodedString:receipt[@"plistBase64"] options:0];
  if(!ValidManifest(manifest,error) || !manifest[@"client"] || ![Hash(inventoryBytes) isEqual:manifest[@"clientInventorySHA256"]] || ![receipt[@"helperSHA256"] isEqual:manifest[@"helper"][@"sha256"]] || !FixedPlist(plist,manifest[@"release"],error) || !InventoryEntries(inventory,error)) {Fail(error,@"fresh receipt payload binding failed");return nil;}
  NSMutableDictionary *result=[@{@"manifest":manifest,@"manifestBytes":manifestBytes,@"inventory":inventory,@"inventoryBytes":inventoryBytes,@"plist":plist}mutableCopy];
  if(receipt[@"upgradeJSON"]) {
    if(![receipt[@"upgradeJSON"]isKindOfClass:NSString.class]) {Fail(error,@"invalid upgrade approval");return nil;}
    NSDictionary *approval=KuroDecodeJSON([receipt[@"upgradeJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
    NSDictionary *installed=@{@"format":@1,@"release":manifest[@"release"],@"helperSHA256":manifest[@"helper"][@"sha256"],@"neverStarted":@NO};
    if(![manifest[@"installerProtocol"]isEqual:@2] || !KuroUpgradeOffValid(approval,manifest,manifestBytes,inventoryBytes,installed)) {Fail(error,@"upgrade approval does not bind this payload");return nil;}
    result[@"upgrade"]=approval;
  }
  if(receipt[@"uninstallJSON"]) {
    if(![receipt[@"uninstallJSON"]isKindOfClass:NSString.class]) {Fail(error,@"invalid stopped uninstall approval");return nil;}
    NSDictionary *approval=KuroDecodeJSON([receipt[@"uninstallJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
    if(!Keys(approval,@[@"format",@"installed",@"stopped"]) || !KuroNumber(approval[@"format"],1,1) || !(KuroStoppedProofValid(approval[@"stopped"],manifest,manifestBytes,inventoryBytes,approval[@"installed"]) || (result[@"upgrade"] && [approval[@"stopped"]isEqual:result[@"upgrade"]] && KuroUpgradeOffValid(approval[@"stopped"],manifest,manifestBytes,inventoryBytes,approval[@"installed"])))) {Fail(error,@"stopped uninstall approval does not match this payload");return nil;}
    result[@"uninstall"]=approval;
  }
  return result;
}
static NSDictionary *ReadFreshReceipt(NSString *prefix,uid_t owner,NSString **error) {
  return DecodeFreshReceipt(ReadProtected(prefix,At(prefix,FreshReceipt),owner,error),error);
}
static BOOL KuroStoppedBoundToReceipt(NSDictionary *proof,NSDictionary *receipt,NSDictionary *installed) {
  return KuroStoppedProofValid(proof,receipt[@"manifest"],receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed) ||
    (receipt[@"upgrade"] && [proof isEqual:receipt[@"upgrade"]] && KuroUpgradeOffValid(proof,receipt[@"manifest"],receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed));
}
// Capability admission follows dynamic peer authentication. Neither this receipt
// nor an auth-only connection grants arbitrary commands or automatic startup.
static BOOL KuroSessionActivationAt(NSString *prefix,uid_t owner,NSString *executingHelper,NSString **error) {
  if(Exists(At(prefix,RecoveryRecord)) || Exists(At(prefix,[State stringByAppendingPathComponent:@"transaction.json"])))return Fail(error,@"finite session activation requires a completed installation transaction");
  NSDictionary *installed=ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),owner,error);
  if(!Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroNumber(installed[@"format"],1,1) || !KuroBool(installed[@"neverStarted"]) ||
    !Match(installed[@"release"],@"\\A[A-Za-z0-9.-]{1,120}\\z") || !Match(installed[@"helperSHA256"],@"\\A[0-9a-f]{64}\\z"))return Fail(error,@"finite session activation requires a protected installation record");
  NSString *version=[At(prefix,Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:installed[@"release"]]],*helper=[version stringByAppendingPathComponent:@"helper"];
  NSData *manifestBytes=ReadProtected(prefix,[version stringByAppendingPathComponent:@"manifest.json"],owner,error);
  NSDictionary *manifest=manifestBytes?KuroDecodeJSON(manifestBytes,MessageLimit,error):nil;
  if(!ValidManifest(manifest,error) || ![manifest[@"activationAllowed"]boolValue] || !manifest[@"client"] || !manifest[@"clientInventorySHA256"])return Fail(error,@"installed manifest does not explicitly permit finite TUN sessions");
  NSData *helperBytes=ReadProtected(prefix,helper,owner,error);
  if(![helper isEqual:executingHelper] || ![manifest[@"release"]isEqual:installed[@"release"]] || !helperBytes || !MachExecutable(helperBytes) ||
    ![Hash(helperBytes)isEqual:installed[@"helperSHA256"]] || ![manifest[@"helper"][@"sha256"]isEqual:installed[@"helperSHA256"]])return Fail(error,@"finite session activation helper/installation identity mismatch");
  NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error);
  NSData *inventory=ReadProtected(prefix,At(prefix,[State stringByAppendingPathComponent:@"Inbox/client-inventory.json"]),owner,error);
  NSDictionary *client=ReadJSON(prefix,At(prefix,[State stringByAppendingPathComponent:@"client.json"]),owner,error);
  if(!receipt || receipt[@"uninstall"] || ![receipt[@"manifestBytes"]isEqual:manifestBytes] || !inventory || ![inventory isEqual:receipt[@"inventoryBytes"]] || ![Hash(inventory)isEqual:manifest[@"clientInventorySHA256"]] ||
    ![client isEqual:manifest[@"client"]])return Fail(error,@"finite session activation is not bound to the administrator-approved client inventory");
  NSData *plist=ReadProtected(prefix,At(prefix,Plist),owner,error),*recovery=ReadProtected(prefix,At(prefix,Recovery),owner,error);
  if(!plist || ![plist isEqual:receipt[@"plist"]] || !FixedPlist(plist,installed[@"release"],error) || !recovery || !MachExecutable(recovery) || ![Hash(recovery)isEqual:installed[@"helperSHA256"]])return Fail(error,@"finite session activation requires the exact installed plist and recovery executable");
  if(Exists(At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"])))return Fail(error,@"auth observation is active or retained; finite session activation refused");
  return YES;
}
static BOOL KuroRevokeStoppedProof(NSString *prefix,uid_t owner,NSString **error) {
  NSString *directory=At(prefix,State),*path=[directory stringByAppendingPathComponent:@"stopped.json"];
  if(Exists(path)) {
    NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error),*installed=ReadJSON(prefix,[directory stringByAppendingPathComponent:@"installed.json"],owner,error);
    NSData *bytes=ReadProtected(prefix,path,owner,error);NSDictionary *proof=bytes?KuroDecodeJSON(bytes,MessageLimit,error):nil;
    if(!receipt || receipt[@"uninstall"] || !KuroStoppedBoundToReceipt(proof,receipt,installed) ||
      ![ReadProtected(prefix,path,owner,error)isEqual:bytes] || unlink(path.fileSystemRepresentation))return Fail(error,@"stopped proof could not be safely revoked; new session refused");
  }
  // Also sync when neverStarted is already false; absence alone is not durability.
  return SyncInstallDirectory(directory,error);
}
static BOOL KuroMarkSessionStopped(NSString *prefix,uid_t owner,NSString *executingHelper,NSDictionary *process,NSDictionary *network,NSString **error) {
  if(!KuroSessionActivationAt(prefix,owner,executingHelper,error) || !KuroCompletedStopEvidence(process) || HasOwnershipFootprint(prefix) || Exists(At(prefix,[State stringByAppendingPathComponent:@"session-work"])))return Fail(error,@"held session cleanup is incomplete; stopped checkpoint refused");
  NSString *directory=At(prefix,State),*path=[directory stringByAppendingPathComponent:@"stopped.json"];
  NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error),*installed=ReadJSON(prefix,[directory stringByAppendingPathComponent:@"installed.json"],owner,error),*manifest=receipt[@"manifest"];
  NSDictionary *proof=@{@"format":@1,@"release":installed[@"release"],@"helperSHA256":installed[@"helperSHA256"],@"coreSHA256":manifest[@"core"][@"sha256"],@"manifestSHA256":Hash(receipt[@"manifestBytes"]),@"inventorySHA256":Hash(receipt[@"inventoryBytes"]),@"installedSHA256":Hash(JSONData(installed)),@"session":process[@"session"],@"process":process,@"network":network?:@{}};
  if(!KuroStoppedProofValid(proof,manifest,receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed))return Fail(error,@"independent process/route/DNS stop proof does not bind this installed payload");
  NSData *bytes=JSONData(proof);
  if(Exists(path))return [ReadProtected(prefix,path,owner,error)isEqual:bytes] && SyncInstallDirectory(directory,error);
  return WriteNew(path,bytes,0600,error) && SyncInstallDirectory(directory,error);
}
// A failed checkpoint never resumes Core. False is sticky: even a later launch
// failure cannot restore the weaker never-started uninstall authority.
static BOOL KuroMarkSessionStarted(NSString *prefix,uid_t owner,NSString *executingHelper,NSString **error) {
  if(!KuroSessionActivationAt(prefix,owner,executingHelper,error))return NO;
  NSString *directory=At(prefix,State),*path=[directory stringByAppendingPathComponent:@"installed.json"];
  NSData *before=ReadProtected(prefix,path,owner,error);NSDictionary *record=before?KuroDecodeJSON(before,MessageLimit,error):nil;
  if(!Keys(record,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) || !KuroBool(record[@"neverStarted"]))return Fail(error,@"startup checkpoint installation record is unavailable");
  if(!KuroRevokeStoppedProof(prefix,owner,error))return NO;
  if(![record[@"neverStarted"]boolValue])return SyncInstallDirectory(directory,error);
  NSMutableDictionary *updated=[record mutableCopy];updated[@"neverStarted"]=@NO;
  NSString *temporary=[directory stringByAppendingPathComponent:[@".installed-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!WriteNew(temporary,JSONData(updated),0600,error))return NO;
  if(![ReadProtected(prefix,path,owner,error)isEqual:before] || rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation)) {
    unlink(temporary.fileSystemRepresentation);return Fail(error,@"startup checkpoint changed or could not be published; resume refused");
  }
  return SyncInstallDirectory(directory,error);
}
static BOOL BeginClientInstallFromScripts(NSString *prefix,uid_t owner,BOOL system,NSString *scripts,NSString **error) {
  if(!PreflightInstall(prefix,owner,system,error) || !InstallScriptsProtected(scripts,owner,error))return NO;
  NSString *client=At(prefix,ClientBundle);if(Exists(client))return Fail(error,@"existing protected App preserved; fresh install refused");
  NSString *ancestor=client.stringByDeletingLastPathComponent;while(!Exists(ancestor))ancestor=ancestor.stringByDeletingLastPathComponent;
  if(!SafeChain(prefix,ancestor,owner,YES,error))return NO;
  NSData *manifestBytes=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"manifest.json"],owner,error),*inventoryBytes=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"client-inventory.json"],owner,error),*plist=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"dev.kuro.tun.plist"],owner,error),*helper=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"preflight-native"],owner,error);
  NSDictionary *manifest=KuroDecodeJSON(manifestBytes,MessageLimit,error),*inventory=KuroDecodeJSON(inventoryBytes,InventoryLimit,error);
  if(!ValidManifest(manifest,error)||!manifest[@"client"]||![Hash(inventoryBytes) isEqual:manifest[@"clientInventorySHA256"]]||!InventoryEntries(inventory,error)||!FixedPlist(plist,manifest[@"release"],error)||!MachExecutable(helper)||![Hash(helper) isEqual:manifest[@"helper"][@"sha256"]])return Fail(error,@"fresh approval sidecars do not match fixed helper");
  if(system && ![Executable() isEqual:[scripts stringByAppendingPathComponent:@"preflight-native"]])return Fail(error,@"fixed Installer preflight executable required");
  NSString *parent=At(prefix,@"/Library/PrivilegedHelperTools");if(!EnsureDirectory(prefix,parent,owner,0755,error))return NO;
  int lock=open(parent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(lock<0||flock(lock,LOCK_EX|LOCK_NB)) {if(lock>=0)close(lock);return Fail(error,@"fresh installation lock unavailable");}
  @try {
    if(!PreflightInstall(prefix,owner,system,error) || Exists(client))return Fail(error,@"fresh installation baseline changed");
    NSDictionary *receipt=@{@"format":@1,@"helperSHA256":manifest[@"helper"][@"sha256"],@"manifestJSON":[[NSString alloc] initWithData:manifestBytes encoding:NSUTF8StringEncoding],@"inventoryJSON":[[NSString alloc] initWithData:inventoryBytes encoding:NSUTF8StringEncoding],@"plistBase64":[plist base64EncodedStringWithOptions:0]};
    if(!WriteNew(At(prefix,Recovery),helper,0755,error) || !SyncInstallDirectory(parent,error) || !WriteNew(At(prefix,FreshReceipt),JSONData(receipt),0600,error) || !SyncInstallDirectory(parent,error))return NO;
    return YES;
  } @finally {close(lock);}
}
static BOOL BeginClientInstall(NSString *prefix,uid_t owner,BOOL system,NSString **error) {return BeginClientInstallFromScripts(prefix,owner,system,Executable().stringByDeletingLastPathComponent,error);}

static BOOL Install(NSString *prefix, uid_t owner, BOOL system, NSString **error) {
  NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
  NSDictionary *manifest = ReadJSON(prefix, [inbox stringByAppendingPathComponent:@"manifest.json"], owner, error);
  if (!ValidManifest(manifest, error)) return NO;
  NSDictionary *client = manifest[@"client"];
  if (manifest[@"clientInventorySHA256"]) {
    NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error);
    NSData *inventory=ReadProtected(prefix,[inbox stringByAppendingPathComponent:@"client-inventory.json"],owner,error);
    if(!receipt || ![receipt[@"manifestBytes"] isEqual:ReadProtected(prefix,[inbox stringByAppendingPathComponent:@"manifest.json"],owner,error)] || !inventory || ![Hash(inventory) isEqual:manifest[@"clientInventorySHA256"]] || !ClientSubset(prefix,owner,InventoryEntries(receipt[@"inventory"],error),@"",error))return Fail(error,@"client copy does not match its fresh administrator receipt");
  }
  if (client && ![KuroClientSnapshot(prefix, At(prefix, ClientBundle), owner, error) isEqual:client]) return Fail(error, @"installed protected App does not match the administrator-approved payload");
  NSMutableDictionary *files = [NSMutableDictionary dictionary];
  for (NSString *name in @[@"helper", @"mihomo", @"manifest.json", @"dev.kuro.tun.plist"]) {
    NSData *bytes = ReadProtected(prefix, [inbox stringByAppendingPathComponent:name], owner, error);
    if (!bytes) return NO;
    files[name] = bytes;
  }
  if (!MachExecutable(files[@"helper"]) || !MachExecutable(files[@"mihomo"])) return Fail(error, @"payload must contain matching thin Mach-O executables");
  if (![Hash(files[@"helper"]) isEqual:manifest[@"helper"][@"sha256"]] || ![Hash(files[@"mihomo"]) isEqual:manifest[@"core"][@"sha256"]] || !FixedPlist(files[@"dev.kuro.tun.plist"], manifest[@"release"], error)) return Fail(error, @"payload digest or fixed plist mismatch");
  if (system) {
    NSString *installer = [Tools stringByAppendingPathComponent:@"installer"];
    NSData *selfBytes = ReadProtected(prefix, installer, owner, error);
    NSData *recovery = ReadProtected(prefix, At(prefix, Recovery), owner, error);
    if (![Executable() isEqual:installer] || !selfBytes || !recovery || ![Hash(recovery) isEqual:manifest[@"helper"][@"sha256"]] || ![Hash(selfBytes) isEqual:manifest[@"helper"][@"sha256"]]) return Fail(error, @"installer must be the approved protected helper executable");
  }
  NSString *statePath = At(prefix, [State stringByAppendingPathComponent:@"installed.json"]);
  // No unknown upgrade/partial state is overwritten. First install only until ownership migration is implemented.
  if (Exists(statePath) || Exists(At(prefix, Plist)) || Exists(At(prefix, [Tools stringByAppendingPathComponent:@"versions"]))) return Fail(error, @"existing or partial install requires recovery; upgrade refused");
  if (system) {
    int service = Launchctl(@[@"print", @"system/dev.kuro.tun"]);
    if (service != 3 && service != 113) return Fail(error, @"existing or unknown service; fresh installation refused");
  }
  int serviceLock = ServiceLock(prefix, owner, error);
  if (serviceLock < 0) return NO;
  @try {
  NSString *version = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:manifest[@"release"]]];
  if (!EnsureDirectory(prefix, At(prefix, State), owner, 0700, error) || !EnsureDirectory(prefix, version, owner, 0755, error) || !EnsureDirectory(prefix, At(prefix, @"/Library/LaunchDaemons"), owner, 0755, error)) return NO;
  NSDictionary *transaction = @{@"format":@1, @"release":manifest[@"release"], @"stage":@"copying"};
  NSString *transactionPath = At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]);
  if (!WriteNew(transactionPath, JSONData(transaction), 0600, error)) return NO;
  for (NSString *name in @[@"helper", @"mihomo", @"manifest.json"]) {
    mode_t mode = [name isEqual:@"manifest.json"] ? 0600 : 0755;
    if (!WriteNew([version stringByAppendingPathComponent:name], files[name], mode, error)) return NO;
  }
  if (!WriteNew(At(prefix, Plist), files[@"dev.kuro.tun.plist"], 0644, error)) return NO;
  if (client && !WriteNew(At(prefix, [State stringByAppendingPathComponent:@"client.json"]), JSONData(client), 0600, error)) return NO;
  NSDictionary *record = @{@"format":@1, @"release":manifest[@"release"], @"helperSHA256":manifest[@"helper"][@"sha256"], @"neverStarted":@YES};
  if (!WriteNew(statePath, JSONData(record), 0600, error)) return NO;
  // Installation never bootstraps a service or changes any network state.
  if (unlink(transactionPath.fileSystemRepresentation)) return Fail(error, @"installed disabled, but transaction cleanup failed");
  return YES;
  } @finally { close(serviceLock); }
}
static BOOL OnlyNames(NSString *prefix, NSString *path, uid_t owner, NSArray *allowed, NSString **error) {
  if (!Exists(path)) return YES;
  if (!SafeChain(prefix, path, owner, YES, error)) return NO;
  NSError *failure = nil;
  NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&failure];
  if (!names || failure) return Fail(error, @"cannot enumerate owned directory");
  for (NSString *name in names) if (![allowed containsObject:name]) return Fail(error, @"unknown files preserved; uninstall refused");
  return YES;
}
static BOOL RemoveApproved(NSString *prefix, NSString *path, uid_t owner, NSString *digest, NSString **error) {
  if (!Exists(path)) return YES;
  NSData *bytes = ReadProtected(prefix, path, owner, error);
  if (!bytes || ![Hash(bytes) isEqual:digest]) return Fail(error, @"changed installed file preserved; uninstall refused");
  return !unlink(path.fileSystemRepresentation) || Fail(error, @"file removal failed; retry recorded uninstall");
}
static BOOL RemoveDirectory(NSString *path, NSString **error) {
  return !rmdir(path.fileSystemRepresentation) || errno == ENOENT || Fail(error, @"directory not empty or removal failed; preserved");
}
static BOOL FinalizeRecovery(NSString *prefix, uid_t owner, BOOL system, NSString *entry, NSString **error) {
  if (![entry isEqual:At(prefix, Recovery)] || Exists(At(prefix, RecoveryRecord))) return Fail(error, @"no approved uninstall record");
  for (NSString *path in @[Tools, State, SocketDirectory, Plist, FreshReceipt, ClientBundle]) if (Exists(At(prefix, path))) return Fail(error, @"uninstall is not complete; recovery entry retained");
  NSData *bytes = ReadProtected(prefix, At(prefix, Recovery), owner, error);
  if (!bytes || !MachExecutable(bytes)) return Fail(error, @"unprotected recovery executable");
  if (system) {
    SecCodeRef self = NULL; SecStaticCodeRef disk = NULL;
    NSURL *url = [NSURL fileURLWithPath:entry];
    BOOL valid = SecCodeCopySelf(0, &self) == errSecSuccess && SecCodeCheckValidity(self, kSecCSStrictValidate, NULL) == errSecSuccess &&
      SecStaticCodeCreateWithPath((__bridge CFURLRef)url, 0, &disk) == errSecSuccess && SecStaticCodeCheckValidity(disk, kSecCSStrictValidate, NULL) == errSecSuccess;
    CFDictionaryRef liveInfo = NULL, diskInfo = NULL;
    if (valid) valid = SecCodeCopySigningInformation(self, kSecCSSigningInformation, &liveInfo) == errSecSuccess && SecCodeCopySigningInformation(disk, kSecCSSigningInformation, &diskInfo) == errSecSuccess;
    if (valid) {
      CFTypeRef liveHash = CFDictionaryGetValue(liveInfo, kSecCodeInfoUnique), diskHash = CFDictionaryGetValue(diskInfo, kSecCodeInfoUnique);
      valid = liveHash && diskHash && CFEqual(liveHash, diskHash);
    }
    if (liveInfo) CFRelease(liveInfo); if (diskInfo) CFRelease(diskInfo); if (self) CFRelease(self); if (disk) CFRelease(disk);
    if (!valid) return Fail(error, @"recovery code identity invalid");
  }
  return !unlink(At(prefix, Recovery).fileSystemRepresentation) || Fail(error, @"final recovery removal failed; rerun fixed recovery CLI");
}
static BOOL FreshAuthEvidence(NSString *prefix,uid_t owner,NSString *helper,NSData **recordBytes,NSString **error) {
  NSString *recordPath=At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"]),*socket=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"auth.sock"]);
  *recordBytes=nil;
  if(!Exists(recordPath))return !Exists(socket)||Fail(error,@"unrecorded auth socket preserved");
  *recordBytes=ReadProtected(prefix,recordPath,owner,error);NSDictionary *record=KuroDecodeJSON(*recordBytes,MessageLimit,error);
  if(!Keys(record,@[@"format",@"socketDevice",@"socketInode",@"helperSHA256"])||!KuroNumber(record[@"format"],1,1)||!KuroNumber(record[@"socketDevice"],0,9007199254740991ULL)||!KuroNumber(record[@"socketInode"],1,9007199254740991ULL)||![record[@"helperSHA256"] isEqual:helper])return Fail(error,@"unknown auth observer evidence preserved");
  if(Exists(socket)) {
    struct stat info;if(!SafeChain(prefix,At(prefix,SocketDirectory),owner,YES,error)||lstat(socket.fileSystemRepresentation,&info)||!S_ISSOCK(info.st_mode)||info.st_uid!=owner||info.st_nlink!=1||(unsigned long long)info.st_dev!=[record[@"socketDevice"] unsignedLongLongValue]||info.st_ino!=[record[@"socketInode"] unsignedLongLongValue])return Fail(error,@"changed auth socket identity preserved");
  }
  return YES;
}
static BOOL UninstallFresh(NSString *prefix,uid_t owner,BOOL system,NSString *entry,NSString **error) {
  NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error);if(!receipt)return NO;
  NSDictionary *manifest=receipt[@"manifest"],*entries=InventoryEntries(receipt[@"inventory"],error);
  NSString *helper=manifest[@"helper"][@"sha256"],*inbox=At(prefix,[State stringByAppendingPathComponent:@"Inbox"]),*versions=[At(prefix,Tools) stringByAppendingPathComponent:@"versions"],*version=[versions stringByAppendingPathComponent:manifest[@"release"]];
  if(![@[At(prefix,Recovery),[At(prefix,Tools) stringByAppendingPathComponent:@"installer"]] containsObject:entry] || (system&&![Executable() isEqual:entry]) || ![InstallFileHash(prefix,entry,owner,error) isEqual:helper] || ![InstallFileHash(prefix,At(prefix,Recovery),owner,error) isEqual:helper])return Fail(error,@"fresh recovery executable identity mismatch");
  if(HasOwnershipFootprint(prefix)||Exists(At(prefix,RecoveryRecord)))return Fail(error,@"unknown active ownership or recovery approval preserved");
  if(system) {int present=Launchctl(@[@"print",@"system/dev.kuro.tun"]);if(present!=3&&present!=113)return Fail(error,@"fresh cleanup requires absent launchd service");}
  if(!OnlyNames(prefix,At(prefix,Tools),owner,@[@"installer",@"versions"],error)||!OnlyNames(prefix,versions,owner,@[manifest[@"release"]],error)||!OnlyNames(prefix,version,owner,@[@"helper",@"mihomo",@"manifest.json"],error)||!OnlyNames(prefix,At(prefix,State),owner,@[@"installed.json",@"stopped.json",@"client.json",@"transaction.json",@"auth-observer.json",@"Inbox"],error)||!OnlyNames(prefix,inbox,owner,@[@"helper",@"mihomo",@"manifest.json",@"dev.kuro.tun.plist",@"client-inventory.json"],error)||!OnlyNames(prefix,At(prefix,SocketDirectory),owner,@[@"service.lock",@"auth.sock"],error)||!ClientSubset(prefix,owner,entries,@"",error))return NO;
  NSMutableDictionary *expected=[NSMutableDictionary dictionary];
  for(NSString *directory in @[version,inbox]) {
    expected[[directory stringByAppendingPathComponent:@"helper"]]=helper;
    expected[[directory stringByAppendingPathComponent:@"mihomo"]]=manifest[@"core"][@"sha256"];
    expected[[directory stringByAppendingPathComponent:@"manifest.json"]]=Hash(receipt[@"manifestBytes"]);
  }
  expected[[inbox stringByAppendingPathComponent:@"client-inventory.json"]]=manifest[@"clientInventorySHA256"];
  expected[[inbox stringByAppendingPathComponent:@"dev.kuro.tun.plist"]]=Hash(receipt[@"plist"]);
  expected[At(prefix,Plist)]=Hash(receipt[@"plist"]);
  expected[[At(prefix,Tools) stringByAppendingPathComponent:@"installer"]]=helper;
  expected[At(prefix,[State stringByAppendingPathComponent:@"client.json"])]=Hash(JSONData(manifest[@"client"]));
  NSString *installedPath=At(prefix,[State stringByAppendingPathComponent:@"installed.json"]),*stoppedPath=At(prefix,[State stringByAppendingPathComponent:@"stopped.json"]);
  NSDictionary *installed=Exists(installedPath)?ReadJSON(prefix,installedPath,owner,error):nil;
  NSDictionary *approval=receipt[@"uninstall"];
  BOOL started=approval || (KuroBool(installed[@"neverStarted"]) && ![installed[@"neverStarted"]boolValue]);
  if(started) {
    if(!approval) {
      NSDictionary *stopped=ReadJSON(prefix,stoppedPath,owner,error);
      if(!KuroStoppedBoundToReceipt(stopped,receipt,installed))return Fail(error,@"running-history install requires its protected completed-stop checkpoint");
      approval=@{@"format":@1,@"installed":installed,@"stopped":stopped};
    }
    if((installed && ![installed isEqual:approval[@"installed"]]) || Exists(At(prefix,[State stringByAppendingPathComponent:@"session-work"])))return Fail(error,@"started installation identity or runtime changed; preserving install");
    expected[installedPath]=Hash(JSONData(approval[@"installed"]));expected[stoppedPath]=Hash(JSONData(approval[@"stopped"]));
  } else {
    if(Exists(stoppedPath))return Fail(error,@"unexpected stopped proof on never-started installation preserved");
    expected[installedPath]=Hash(JSONData(@{@"format":@1,@"release":manifest[@"release"],@"helperSHA256":helper,@"neverStarted":@YES}));
  }
  expected[At(prefix,[State stringByAppendingPathComponent:@"transaction.json"])]=Hash(JSONData(@{@"format":@1,@"release":manifest[@"release"],@"stage":@"copying"}));
  int lock=ServiceLock(prefix,owner,error);if(lock<0)return NO;
  @try {
    // Complete verification precedes any deletion. Missing approved files are retryable.
    for(NSString *path in expected)if(Exists(path)&&![InstallFileHash(prefix,path,owner,error) isEqual:expected[path]])return Fail(error,@"changed partial installation preserved");
    if(started && !receipt[@"uninstall"]) {
      NSString *receiptPath=At(prefix,FreshReceipt);NSData *before=ReadProtected(prefix,receiptPath,owner,error);
      NSMutableDictionary *updated=[KuroDecodeJSON(before,InventoryLimit*2,error)mutableCopy];if(!updated)return NO;
      updated[@"uninstallJSON"]=[[NSString alloc]initWithData:JSONData(approval) encoding:NSUTF8StringEncoding];
      NSString *temporary=[receiptPath stringByAppendingString:[@".pending-"stringByAppendingString:NSUUID.UUID.UUIDString]];
      if(!WriteNew(temporary,JSONData(updated),0600,error) || ![ReadProtected(prefix,receiptPath,owner,error)isEqual:before] || rename(temporary.fileSystemRepresentation,receiptPath.fileSystemRepresentation) || !SyncInstallDirectory(receiptPath.stringByDeletingLastPathComponent,error))return Fail(error,@"completed-stop uninstall approval could not be persisted; installation preserved");
    }
    NSData *authRecord=nil;if(!FreshAuthEvidence(prefix,owner,helper,&authRecord,error))return NO;
    if(!RemoveClientSubset(prefix,owner,entries,error))return NO;
    if(authRecord) {
      NSData *current=nil;if(!FreshAuthEvidence(prefix,owner,helper,&current,error)||![current isEqual:authRecord])return Fail(error,@"auth cleanup evidence changed");
      NSString *socket=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"auth.sock"]);
      if(Exists(socket)&&unlink(socket.fileSystemRepresentation))return Fail(error,@"auth socket cleanup failed");
      if(!RemoveApproved(prefix,At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"]),owner,Hash(authRecord),error))return NO;
    }
    for(NSString *path in expected)if(!RemoveApproved(prefix,path,owner,expected[path],error))return NO;
    for(NSString *directory in @[version,versions,inbox,At(prefix,Tools),At(prefix,State)])if(!RemoveDirectory(directory,error))return NO;
    NSString *lockPath=[At(prefix,SocketDirectory) stringByAppendingPathComponent:@"service.lock"];struct stat info;
    if(Exists(lockPath)&&(!SafeChain(prefix,lockPath,owner,NO,error)||lstat(lockPath.fileSystemRepresentation,&info)||info.st_size||unlink(lockPath.fileSystemRepresentation)))return Fail(error,@"changed service lock preserved");
    if(!RemoveDirectory(At(prefix,SocketDirectory),error))return NO;
    if(Exists(At(prefix,ClientBundle)))return Fail(error,@"fresh App removal not complete");
    if(unlink(At(prefix,FreshReceipt).fileSystemRepresentation)||!SyncInstallDirectory(At(prefix,@"/Library/PrivilegedHelperTools"),error))return Fail(error,@"fresh receipt finalization failed");
    return RemoveApproved(prefix,At(prefix,Recovery),owner,helper,error);
  } @finally {close(lock);}
}

static BOOL Uninstall(NSString *prefix, uid_t owner, BOOL system, NSString *entry, NSString **error) {
  if(Exists(At(prefix,FreshReceipt)))return UninstallFresh(prefix,owner,system,entry,error);
  NSString *approvalPath = At(prefix, RecoveryRecord);
  if (!Exists(approvalPath) && !Exists(At(prefix, Tools)) && !Exists(At(prefix, State))) return FinalizeRecovery(prefix, owner, system, entry, error);
  NSString *statePath = At(prefix, [State stringByAppendingPathComponent:@"installed.json"]);
  NSString *inbox = At(prefix, [State stringByAppendingPathComponent:@"Inbox"]);
  NSDictionary *approval = nil;
  if (Exists(approvalPath)) {
    approval = ReadJSON(prefix, approvalPath, owner, error);
    NSArray *approvalKeys = @[@"format", @"release", @"helper", @"core", @"manifest", @"plist", @"neverStarted"];
    if (approval[@"client"]) approvalKeys = [approvalKeys arrayByAddingObject:@"client"];
    if (!Keys(approval, approvalKeys) || (approval[@"client"] && !Match(approval[@"client"], @"\\A[0-9a-f]{64}\\z")) ||
        ![approval[@"format"] isEqual:@1] || ![approval[@"neverStarted"] isEqual:@YES]) return Fail(error, @"invalid uninstall recovery record");
    for (NSString *key in @[@"helper", @"core", @"manifest", @"plist"]) if (!Match(approval[key], @"\\A[0-9a-f]{64}\\z")) return Fail(error, @"invalid uninstall digest");
  } else {
    NSDictionary *record = nil;
    if (!ProveNeverStarted(prefix, owner, &record, error) || Exists(At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]))) return Fail(error, @"unknown/partial installation; uninstall refused");
    NSString *version = [At(prefix, Tools) stringByAppendingPathComponent:[@"versions" stringByAppendingPathComponent:record[@"release"]]];
    NSData *manifestBytes = ReadProtected(prefix, [version stringByAppendingPathComponent:@"manifest.json"], owner, error);
    NSDictionary *manifest = manifestBytes ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:NULL] : nil;
    if (!ValidManifest(manifest, error) || ![manifest[@"release"] isEqual:record[@"release"]] || ![manifest[@"helper"][@"sha256"] isEqual:record[@"helperSHA256"]]) return Fail(error, @"installed manifest does not match off record");
    for (NSString *name in @[@"helper", @"mihomo"]) {
      NSData *bytes = ReadProtected(prefix, [version stringByAppendingPathComponent:name], owner, error);
      NSDictionary *item = manifest[[name isEqual:@"helper"] ? @"helper" : @"core"];
      if (!bytes || ![Hash(bytes) isEqual:item[@"sha256"]]) return Fail(error, @"installed bytes changed; uninstall refused");
    }
    NSData *plist = ReadProtected(prefix, At(prefix, Plist), owner, error);
    if (!FixedPlist(plist, record[@"release"], error)) return NO;
    approval = @{@"format":@1, @"release":record[@"release"], @"helper":manifest[@"helper"][@"sha256"], @"core":manifest[@"core"][@"sha256"], @"manifest":Hash(manifestBytes), @"plist":Hash(plist), @"neverStarted":@YES};
    if (manifest[@"client"]) {
      NSData *clientBytes = ReadProtected(prefix, At(prefix, [State stringByAppendingPathComponent:@"client.json"]), owner, error);
      if (!clientBytes || ![clientBytes isEqual:JSONData(manifest[@"client"])]) return Fail(error, @"client approval changed; uninstall preserved");
      NSMutableDictionary *withClient = [approval mutableCopy]; withClient[@"client"] = Hash(clientBytes); approval = withClient;
    }
    if (!WriteNew(approvalPath, JSONData(approval), 0600, error)) return NO;
  }
  if (!Match(approval[@"release"], @"\\A[A-Za-z0-9.-]{1,120}\\z") || HasOwnershipFootprint(prefix) || Exists(At(prefix, [State stringByAppendingPathComponent:@"transaction.json"]))) return Fail(error, @"owned cleanup is unknown; uninstall preserved");
  NSString *versions = [At(prefix, Tools) stringByAppendingPathComponent:@"versions"];
  NSString *version = [versions stringByAppendingPathComponent:approval[@"release"]];
  if (!OnlyNames(prefix, At(prefix, Tools), owner, @[@"installer", @"versions"], error) ||
      !OnlyNames(prefix, versions, owner, @[approval[@"release"]], error) ||
      !OnlyNames(prefix, version, owner, @[@"helper", @"mihomo", @"manifest.json"], error) ||
      !OnlyNames(prefix, At(prefix, State), owner, @[@"installed.json", @"client.json", @"auth-observer.json", @"Inbox"], error) ||
      !OnlyNames(prefix, inbox, owner, @[@"helper", @"mihomo", @"manifest.json", @"dev.kuro.tun.plist"], error) ||
      !OnlyNames(prefix, At(prefix, SocketDirectory), owner, @[@"service.lock", @"control.sock", @"auth.sock"], error) || !StopService(system, error)) return NO;
  NSData *recovery = ReadProtected(prefix, At(prefix, Recovery), owner, error);
  if (!recovery || ![Hash(recovery) isEqual:approval[@"helper"]]) return Fail(error, @"exact recovery executable unavailable; uninstall preserved");
  int serviceLock = ServiceLock(prefix, owner, error);
  if (serviceLock < 0) return NO;
  @try {
    NSData *authRecord=nil;if(!FreshAuthEvidence(prefix,owner,approval[@"helper"],&authRecord,error))return NO;
    if(authRecord) {
      NSString *socket=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"auth.sock"]);
      if(Exists(socket)&&unlink(socket.fileSystemRepresentation))return Fail(error,@"auth socket cleanup failed");
      if(!RemoveApproved(prefix,At(prefix,[State stringByAppendingPathComponent:@"auth-observer.json"]),owner,Hash(authRecord),error))return NO;
    }
    if (!RemoveApproved(prefix, At(prefix, [State stringByAppendingPathComponent:@"client.json"]), owner, approval[@"client"], error)) return NO;
    for (NSString *directory in @[version, inbox]) {
      for (NSArray *item in @[@[@"helper", @"helper"], @[@"mihomo", @"core"], @[@"manifest.json", @"manifest"]])
        if (!RemoveApproved(prefix, [directory stringByAppendingPathComponent:item[0]], owner, approval[item[1]], error)) return NO;
    }
    if (!RemoveApproved(prefix, [inbox stringByAppendingPathComponent:@"dev.kuro.tun.plist"], owner, approval[@"plist"], error) ||
        !RemoveApproved(prefix, At(prefix, Plist), owner, approval[@"plist"], error) ||
        !RemoveDirectory(version, error) || !RemoveDirectory(versions, error) || !RemoveDirectory(inbox, error)) return NO;
    NSString *socket = [At(prefix, SocketDirectory) stringByAppendingPathComponent:@"control.sock"];
    struct stat info;
    if (Exists(socket) && (lstat(socket.fileSystemRepresentation, &info) || !S_ISSOCK(info.st_mode) || info.st_uid != owner || unlink(socket.fileSystemRepresentation))) return Fail(error, @"unknown socket preserved");
    for (NSString *lock in @[[At(prefix, SocketDirectory) stringByAppendingPathComponent:@"service.lock"]]) {
      if (Exists(lock) && (!SafeChain(prefix, lock, owner, NO, error) || lstat(lock.fileSystemRepresentation, &info) || info.st_size != 0 || unlink(lock.fileSystemRepresentation))) return Fail(error, @"unknown lock preserved");
    }
    if (!RemoveDirectory(At(prefix, SocketDirectory), error) || !RemoveApproved(prefix, [At(prefix, Tools) stringByAppendingPathComponent:@"installer"], owner, approval[@"helper"], error) || !RemoveDirectory(At(prefix, Tools), error)) return NO;
    if (Exists(statePath) && (!ReadProtected(prefix, statePath, owner, error) || unlink(statePath.fileSystemRepresentation))) return Fail(error, @"off record removal failed; approval retained");
    if (!RemoveDirectory(At(prefix, State), error)) return Fail(error, @"final state cleanup failed; recovery entry retained");
    if (unlink(approvalPath.fileSystemRepresentation)) return Fail(error, @"final approval cleanup failed; recovery entry retained");
    return RemoveApproved(prefix, At(prefix, Recovery), owner, approval[@"helper"], error);
  } @finally { close(serviceLock); }
}
// Installer-only fixed transaction; no executable/path selection crosses an RPC.
static NSString *UpgradeRoot(NSString *prefix) {return At(prefix,[State stringByAppendingPathComponent:@"Upgrade"]);}
static NSString *UpgradeMarker(NSString *prefix) {return At(prefix,[State stringByAppendingPathComponent:@"transaction.json"]);}
#ifdef KURO_TESTING
static BOOL (^UpgradeFault)(NSString *point);
static KuroSessionHook UpgradeRetirementSyncFault;
#endif
static BOOL UpgradePoint(NSString *point,NSString **error) {
#ifdef KURO_TESTING
  if(UpgradeFault && !UpgradeFault(point))return Fail(error,[@"injected interruption: "stringByAppendingString:point]);
#else
  (void)point;(void)error;
#endif
  return YES;
}
// A missing approval after unlink is not yet a durable retirement. Both the
// original transition and a complete no-record retry must flush its fixed parent.
static BOOL UpgradeSyncRetirement(NSString *prefix,NSString **error) {
#ifdef KURO_TESTING
  if(UpgradeRetirementSyncFault && !UpgradeRetirementSyncFault(error))return NO;
#endif
  return SyncInstallDirectory(At(prefix,RecoveryRecord).stringByDeletingLastPathComponent,error);
}
static NSString *UpgradeString(NSData *data) {return [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];}
static NSDictionary *UpgradeFile(NSString *hash,mode_t mode) {return @{@"kind":@"files",@"mode":@(mode),@"sha256":hash};}
static NSDictionary *UpgradeDirectory(mode_t mode) {return @{@"kind":@"directories",@"mode":@(mode)};}
static BOOL UpgradeTree(NSString *prefix,NSString *base,uid_t owner,NSDictionary *entries,BOOL full,NSString **error) {
  if(!entries)return !Exists(base)||Fail(error,@"unexpected object in absent upgrade slot");
  if(!Exists(base))return !full||Fail(error,[@"missing full upgrade object: "stringByAppendingString:base]);
  NSMutableArray *pending=[NSMutableArray arrayWithObject:@""];
  while(pending.count) {
    NSString *relative=pending.lastObject;[pending removeLastObject];NSString *path=relative.length?[base stringByAppendingPathComponent:relative]:base;
    NSDictionary *entry=entries[relative];struct stat info={0};
    if(!entry || lstat(path.fileSystemRepresentation,&info) || info.st_uid!=owner)return Fail(error,[@"unknown or changed upgrade object: "stringByAppendingString:path]);
    if([entry[@"kind"]isEqual:@"links"]) {
      char target[PATH_MAX];ssize_t size=readlink(path.fileSystemRepresentation,target,sizeof(target)-1);
      if(!S_ISLNK(info.st_mode)||info.st_nlink!=1||size<1||size>=(ssize_t)sizeof(target)-1)return Fail(error,@"changed upgrade link type");target[size]=0;
      if(![@(target)isEqual:entry[@"target"]])return Fail(error,@"changed upgrade link target");
    } else {
      BOOL directory=[entry[@"kind"]isEqual:@"directories"];
      if(!SafeChain(prefix,path,owner,directory,error)||(info.st_mode&07777)!=[entry[@"mode"]unsignedIntValue])return Fail(error,[@"unsafe upgrade permissions: "stringByAppendingString:path]);
      if(directory) {
        NSArray *children=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:path error:NULL];if(!children)return Fail(error,@"upgrade directory cannot be enumerated");
        for(NSString *child in children)[pending addObject:relative.length?[relative stringByAppendingPathComponent:child]:child];
      } else if(![InstallFileHash(prefix,path,owner,error)isEqual:entry[@"sha256"]])return Fail(error,[@"changed upgrade bytes: "stringByAppendingString:path]);
    }
  }
  if(full)for(NSString *relative in entries)if(!Exists(relative.length?[base stringByAppendingPathComponent:relative]:base))return Fail(error,@"incomplete approved upgrade tree");
  return YES;
}
static BOOL UpgradeRemove(NSString *prefix,NSString *base,uid_t owner,NSDictionary *entries,NSString **error) {
  if(!UpgradeTree(prefix,base,owner,entries,NO,error))return NO;if(!Exists(base))return YES;
  for(NSString *kind in @[@"links",@"files"])for(NSString *relative in entries)if([entries[relative][@"kind"]isEqual:kind]) {
    NSString *path=relative.length?[base stringByAppendingPathComponent:relative]:base;
    if(!Exists(path))continue;
    // Validate through the original base before each unlink; never follow an approved Framework link.
    if(!UpgradeTree(prefix,base,owner,entries,NO,error)||unlink(path.fileSystemRepresentation)||!UpgradePoint([@"removed:"stringByAppendingString:path.lastPathComponent],error))return NO;
  }
  NSArray *paths=[entries.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return a.length>b.length?NSOrderedAscending:a.length<b.length?NSOrderedDescending:[b compare:a];}];
  for(NSString *relative in paths)if([entries[relative][@"kind"]isEqual:@"directories"]) {
    NSString *path=relative.length?[base stringByAppendingPathComponent:relative]:base;if(!Exists(path))continue;
    if(!SafeChain(prefix,path,owner,YES,error)||rmdir(path.fileSystemRepresentation)||!UpgradePoint([@"removed-dir:"stringByAppendingString:path.lastPathComponent],error))return Fail(error,@"upgrade directory cleanup interrupted or nonempty");
  }
  return SyncInstallDirectory(base.stringByDeletingLastPathComponent,error);
}
static BOOL UpgradeInstalled(NSDictionary *installed,NSDictionary *receipt) {
  NSDictionary *manifest=receipt[@"manifest"];
  return Keys(installed,@[@"format",@"release",@"helperSHA256",@"neverStarted"]) && KuroNumber(installed[@"format"],1,1) && KuroBool(installed[@"neverStarted"]) && [installed[@"release"]isEqual:manifest[@"release"]] && [installed[@"helperSHA256"]isEqual:manifest[@"helper"][@"sha256"]];
}
static NSDictionary *UpgradeProof(NSDictionary *record,NSDictionary *next,NSDictionary *installed) {
  NSDictionary *old=DecodeFreshReceipt([record[@"oldReceiptJSON"]dataUsingEncoding:NSUTF8StringEncoding],NULL),*manifest=next[@"manifest"];
  return @{@"format":@2,@"kind":@"upgrade-off",@"release":manifest[@"release"],@"helperSHA256":manifest[@"helper"][@"sha256"],@"coreSHA256":manifest[@"core"][@"sha256"],@"manifestSHA256":Hash(next[@"manifestBytes"]),@"inventorySHA256":Hash(next[@"inventoryBytes"]),@"installedSHA256":Hash(JSONData(installed)),@"transaction":record[@"transaction"],@"previousRelease":old[@"manifest"][@"release"],@"previousManifestSHA256":Hash(old[@"manifestBytes"]),@"previousStoppedSHA256":Hash([record[@"oldStoppedJSON"]dataUsingEncoding:NSUTF8StringEncoding]),@"newCoreNeverStarted":@YES};
}
static NSDictionary *UpgradeDecode(NSDictionary *record,NSString **error) {
  if(!Keys(record,@[@"format",@"operation",@"transaction",@"phase",@"oldReceiptJSON",@"oldInstalledJSON",@"oldStoppedJSON",@"newManifestJSON",@"newInventoryJSON",@"newPlistBase64"]) || !KuroNumber(record[@"format"],2,2)||![record[@"operation"]isEqual:@"upgrade"]||!Match(record[@"transaction"],@"\\A[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}\\z")||![@[@"staging",@"switching",@"next-installed",@"finalizing"]containsObject:record[@"phase"]]) {Fail(error,@"closed upgrade approval required");return nil;}
  for(NSString *key in @[@"oldReceiptJSON",@"oldInstalledJSON",@"newManifestJSON",@"newInventoryJSON",@"newPlistBase64"])if(![record[key]isKindOfClass:NSString.class]) {Fail(error,@"invalid upgrade encoded sidecar");return nil;}
  NSDictionary *old=DecodeFreshReceipt([record[@"oldReceiptJSON"]dataUsingEncoding:NSUTF8StringEncoding],error),*installed=KuroDecodeJSON([record[@"oldInstalledJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
  NSDictionary *manifest=KuroDecodeJSON([record[@"newManifestJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
  if(!old||old[@"uninstall"]||!UpgradeInstalled(installed,old)||![old[@"manifest"][@"installerProtocol"]isEqual:@2]||!ValidManifest(manifest,error)||![manifest[@"installerProtocol"]isEqual:@2]||[manifest[@"release"]isEqual:old[@"manifest"][@"release"]]) {Fail(error,@"upgrade requires two distinct protocol-2 releases and a complete old off receipt");return nil;}
  if([installed[@"neverStarted"]boolValue]) {if(record[@"oldStoppedJSON"]!=NSNull.null){Fail(error,@"unexpected old stopped proof");return nil;}}
  else {
    if(![record[@"oldStoppedJSON"]isKindOfClass:NSString.class]){Fail(error,@"old running history requires an exact stopped proof");return nil;}
    NSDictionary *proof=KuroDecodeJSON([record[@"oldStoppedJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
    if(!KuroStoppedBoundToReceipt(proof,old,installed)){Fail(error,@"old stopped proof is not bound to this installed release");return nil;}
  }
  NSMutableDictionary *raw=[@{@"format":@1,@"helperSHA256":manifest[@"helper"][@"sha256"],@"manifestJSON":record[@"newManifestJSON"],@"inventoryJSON":record[@"newInventoryJSON"],@"plistBase64":record[@"newPlistBase64"]}mutableCopy];
  NSDictionary *next=DecodeFreshReceipt(JSONData(raw),error);if(!next)return nil;
  NSDictionary *nextInstalled=@{@"format":@1,@"release":manifest[@"release"],@"helperSHA256":manifest[@"helper"][@"sha256"],@"neverStarted":installed[@"neverStarted"]};
  NSDictionary *proof=nil;
  if(![installed[@"neverStarted"]boolValue]) {proof=UpgradeProof(record,next,nextInstalled);raw[@"upgradeJSON"]=UpgradeString(JSONData(proof));next=DecodeFreshReceipt(JSONData(raw),error);if(!next)return nil;}
  return @{@"old":old,@"installed":installed,@"next":next,@"nextInstalled":nextInstalled,@"nextReceiptBytes":JSONData(raw),@"nextStopped":proof?:NSNull.null};
}
static NSDictionary *UpgradeRead(NSString *prefix,uid_t owner,NSString **error) {
  NSData *bytes=ReadProtected(prefix,At(prefix,RecoveryRecord),owner,error);NSDictionary *record=KuroDecodeJSON(bytes,128*1024*1024,error);
  return UpgradeDecode(record,error)?record:nil;
}
static NSArray *UpgradeSlots(void) {return @[@"tools",@"inbox",@"client",@"installed",@"client-pin",@"stopped",@"plist",@"receipt"];}
static NSString *UpgradeCurrent(NSString *prefix,NSString *slot) {
  NSDictionary *paths=@{@"tools":Tools,@"inbox":[State stringByAppendingPathComponent:@"Inbox"],@"client":ClientBundle,@"installed":[State stringByAppendingPathComponent:@"installed.json"],@"client-pin":[State stringByAppendingPathComponent:@"client.json"],@"stopped":[State stringByAppendingPathComponent:@"stopped.json"],@"plist":Plist,@"receipt":FreshReceipt};return At(prefix,paths[slot]);
}
static NSDictionary *UpgradeEntries(NSDictionary *decoded,BOOL next,NSString *slot) {
  NSDictionary *receipt=decoded[next?@"next":@"old"],*manifest=receipt[@"manifest"],*installed=decoded[next?@"nextInstalled":@"installed"];
  NSString *release=manifest[@"release"],*helper=manifest[@"helper"][@"sha256"],*core=manifest[@"core"][@"sha256"];
  if([slot isEqual:@"client"])return InventoryEntries(receipt[@"inventory"],NULL);
  if([slot isEqual:@"tools"]) {
    NSString *version=[@"versions"stringByAppendingPathComponent:release];
    return @{@"":UpgradeDirectory(0755),@"installer":UpgradeFile(helper,0755),@"versions":UpgradeDirectory(0755),version:UpgradeDirectory(0755),[version stringByAppendingPathComponent:@"helper"]:UpgradeFile(helper,0755),[version stringByAppendingPathComponent:@"mihomo"]:UpgradeFile(core,0755),[version stringByAppendingPathComponent:@"manifest.json"]:UpgradeFile(Hash(receipt[@"manifestBytes"]),0600)};
  }
  if([slot isEqual:@"inbox"])return @{@"":UpgradeDirectory(0700),@"helper":UpgradeFile(helper,0755),@"mihomo":UpgradeFile(core,0755),@"manifest.json":UpgradeFile(Hash(receipt[@"manifestBytes"]),0600),@"client-inventory.json":UpgradeFile(Hash(receipt[@"inventoryBytes"]),0600),@"dev.kuro.tun.plist":UpgradeFile(Hash(receipt[@"plist"]),0600)};
  NSString *digest=nil;mode_t mode=0600;
  if([slot isEqual:@"installed"])digest=Hash(JSONData(installed));
  if([slot isEqual:@"client-pin"])digest=Hash(JSONData(manifest[@"client"]));
  if([slot isEqual:@"plist"]) {digest=Hash(receipt[@"plist"]);mode=0644;}
  if([slot isEqual:@"receipt"])digest=next?Hash(decoded[@"nextReceiptBytes"]):nil;
  if([slot isEqual:@"stopped"]) {
    if([installed[@"neverStarted"]boolValue])return nil;
    digest=next?Hash(JSONData(decoded[@"nextStopped"])):nil;
  }
  // Exact old serialized bytes are supplied separately, avoiding canonicalization drift.
  return digest?@{@"":UpgradeFile(digest,mode)}:nil;
}
static NSDictionary *UpgradeSlotEntries(NSDictionary *record,NSDictionary *decoded,BOOL next,NSString *slot) {
  if(!next && [slot isEqual:@"receipt"])return @{@"":UpgradeFile(Hash([record[@"oldReceiptJSON"]dataUsingEncoding:NSUTF8StringEncoding]),0600)};
  if(!next && [slot isEqual:@"installed"])return @{@"":UpgradeFile(Hash([record[@"oldInstalledJSON"]dataUsingEncoding:NSUTF8StringEncoding]),0600)};
  if(!next && [slot isEqual:@"stopped"] && record[@"oldStoppedJSON"]!=NSNull.null)return @{@"":UpgradeFile(Hash([record[@"oldStoppedJSON"]dataUsingEncoding:NSUTF8StringEncoding]),0600)};
  return UpgradeEntries(decoded,next,slot);
}
static BOOL UpgradeQuiescent(NSString *prefix,uid_t owner,BOOL system,NSString **error) {
  if(HasOwnershipFootprint(prefix)||Exists(At(prefix,LegacySocketDirectory)))return Fail(error,@"active, legacy or unknown network/Core ownership blocks upgrade");
  for(NSString *name in @[@"session-work",@"auth-observer.json"])if(Exists(At(prefix,[State stringByAppendingPathComponent:name])))return Fail(error,@"runtime/auth ownership blocks upgrade");
  if(!OnlyNames(prefix,At(prefix,State),owner,@[@"installed.json",@"client.json",@"stopped.json",@"Inbox",@"Upgrade",@"transaction.json"],error)||!OnlyNames(prefix,At(prefix,SocketDirectory),owner,@[@"service.lock"],error))return NO;
  NSString *lockPath=At(prefix,[SocketDirectory stringByAppendingPathComponent:@"service.lock"]);struct stat info;
  if(lstat(lockPath.fileSystemRepresentation,&info)||info.st_size||!SafeNode(lockPath,owner,NO,error))return Fail(error,@"unexpected service lock bytes");
  if(system){int present=Launchctl(@[@"print",@"system/dev.kuro.tun"]);if(present!=3&&present!=113)return Fail(error,@"upgrade requires an independently absent launchd job");}
  return YES;
}
static NSDictionary *UpgradeMarkerValue(NSDictionary *record) {return @{@"format":@2,@"operation":@"upgrade",@"transaction":record[@"transaction"]};}
static BOOL UpgradeMarkerValid(NSString *prefix,uid_t owner,NSDictionary *record,BOOL optional,NSString **error) {
  NSString *path=UpgradeMarker(prefix);return (!Exists(path)&&optional)||[ReadProtected(prefix,path,owner,error)isEqual:JSONData(UpgradeMarkerValue(record))]||Fail(error,@"upgrade transaction marker changed");
}
static BOOL UpgradeCurrentFull(NSString *prefix,uid_t owner,NSDictionary *record,NSDictionary *decoded,BOOL next,BOOL recovery,NSString **error) {
  for(NSString *slot in UpgradeSlots())if(!UpgradeTree(prefix,UpgradeCurrent(prefix,slot),owner,UpgradeSlotEntries(record,decoded,next,slot),YES,error))return NO;
  NSDictionary *receipt=decoded[next?@"next":@"old"];
  if(![KuroClientSnapshot(prefix,At(prefix,ClientBundle),owner,error)isEqual:receipt[@"manifest"][@"client"]])return Fail(error,@"complete upgraded App seal does not match exact pin");
  if(recovery && ![InstallFileHash(prefix,At(prefix,Recovery),owner,error)isEqual:receipt[@"manifest"][@"helper"][@"sha256"]])return Fail(error,@"fixed recovery identity changed");
  return YES;
}
static BOOL UpgradeRename(NSString *prefix,uid_t owner,NSString *from,NSString *to,NSDictionary *entries,NSString **error) {
  if(!UpgradeTree(prefix,from,owner,entries,YES,error)||Exists(to)||!SafeChain(prefix,to.stringByDeletingLastPathComponent,owner,YES,error))return Fail(error,@"upgrade rename source/destination not exact");
  struct stat source,parent;if(lstat(from.fileSystemRepresentation,&source)||lstat(to.stringByDeletingLastPathComponent.fileSystemRepresentation,&parent)||source.st_dev!=parent.st_dev)return Fail(error,@"cross-filesystem upgrade rename refused");
  if(!UpgradePoint([@"before-rename:"stringByAppendingString:to.lastPathComponent],error)||renameatx_np(AT_FDCWD,from.fileSystemRepresentation,AT_FDCWD,to.fileSystemRepresentation,RENAME_EXCL)||!UpgradePoint([@"after-rename:"stringByAppendingString:to.lastPathComponent],error))return Fail(error,@"fixed upgrade rename interrupted");
  if(!SyncInstallDirectory(from.stringByDeletingLastPathComponent,error)||!SyncInstallDirectory(to.stringByDeletingLastPathComponent,error))return NO;
  return UpgradePoint([@"after-sync:"stringByAppendingString:to.lastPathComponent],error);
}
static BOOL UpgradeStageNames(NSString *prefix,uid_t owner,NSString **error) {
  NSString *root=UpgradeRoot(prefix);
  for(NSString *directory in @[root,[root stringByAppendingPathComponent:@"Payload"],[root stringByAppendingPathComponent:@"Next"],[root stringByAppendingPathComponent:@"Previous"]])if(Exists(directory)) {
    struct stat info;if(lstat(directory.fileSystemRepresentation,&info)||!SafeChain(prefix,directory,owner,YES,error)||(info.st_mode&07777)!=0700)return Fail(error,@"upgrade stage directory is not protected 0700");
  }
  if(!OnlyNames(prefix,root,owner,@[@"Payload",@"Next",@"Previous",@"record.pending",@"recovery.pending"],error))return NO;
  if(!OnlyNames(prefix,[root stringByAppendingPathComponent:@"Payload"],owner,@[@"Inbox",@"Client.app"],error))return NO;
  for(NSString *name in @[@"Next",@"Previous"])if(!OnlyNames(prefix,[root stringByAppendingPathComponent:name],owner,UpgradeSlots(),error))return NO;
  return YES;
}
static BOOL UpgradeClearPending(NSString *prefix,uid_t owner,NSDictionary *record,NSString **error) {
  NSString *path=[UpgradeRoot(prefix)stringByAppendingPathComponent:@"record.pending"];if(!Exists(path))return YES;
  NSData *bytes=ReadProtected(prefix,path,owner,error);struct stat info;if(!bytes||lstat(path.fileSystemRepresentation,&info)||(info.st_mode&07777)!=0600)return Fail(error,@"unprotected upgrade pending record");
  BOOL match=NO;for(NSString *phase in @[@"staging",@"switching",@"next-installed",@"finalizing"]) {
    NSMutableDictionary *candidate=[record mutableCopy];candidate[@"phase"]=phase;NSData *known=JSONData(candidate);
    if(bytes.length<=known.length && !memcmp(bytes.bytes,known.bytes,bytes.length)){match=YES;break;}
  }
  return (match && !unlink(path.fileSystemRepresentation) && SyncInstallDirectory(path.stringByDeletingLastPathComponent,error)) || Fail(error,@"unknown pending upgrade bytes preserved");
}
static BOOL UpgradePhase(NSString *prefix,uid_t owner,NSMutableDictionary *record,NSString *phase,NSString **error) {
  if(!UpgradeClearPending(prefix,owner,record,error))return NO;
  NSString *path=At(prefix,RecoveryRecord),*pending=[UpgradeRoot(prefix)stringByAppendingPathComponent:@"record.pending"];
  NSData *before=ReadProtected(prefix,path,owner,error);if(![before isEqual:JSONData(record)])return Fail(error,@"upgrade approval changed");
  NSMutableDictionary *next=[record mutableCopy];next[@"phase"]=phase;
  if(!WriteNew(pending,JSONData(next),0600,error)||!UpgradePoint([@"phase-prepublish:"stringByAppendingString:phase],error)||![ReadProtected(prefix,path,owner,error)isEqual:before]||rename(pending.fileSystemRepresentation,path.fileSystemRepresentation))return NO;
  [record setDictionary:next];
  return SyncInstallDirectory(path.stringByDeletingLastPathComponent,error) && SyncInstallDirectory(pending.stringByDeletingLastPathComponent,error) && UpgradePoint([@"phase:"stringByAppendingString:phase],error);
}
static BOOL UpgradeRecoveryBytes(NSString *prefix,uid_t owner,NSDictionary *record,NSDictionary *decoded,BOOL next,NSString **error) {
  NSString *path=At(prefix,Recovery),*oldHash=decoded[@"old"][@"manifest"][@"helper"][@"sha256"],*nextHash=decoded[@"next"][@"manifest"][@"helper"][@"sha256"],*expected=next?nextHash:oldHash;
  NSString *actual=InstallFileHash(prefix,path,owner,error);if(![actual isEqual:oldHash]&&![actual isEqual:nextHash])return Fail(error,@"unknown recovery executable preserved");
  NSString *pending=[UpgradeRoot(prefix)stringByAppendingPathComponent:@"recovery.pending"];
  if(Exists(pending)) {
    NSString *pendingHash=InstallFileHash(prefix,pending,owner,error);
    if((![pendingHash isEqual:oldHash]&&![pendingHash isEqual:nextHash])||unlink(pending.fileSystemRepresentation))return Fail(error,@"changed pending recovery preserved");
  }
  if([actual isEqual:expected])return SyncInstallDirectory(path.stringByDeletingLastPathComponent,error);
  NSString *source=next?[UpgradeCurrent(prefix,@"tools")stringByAppendingPathComponent:@"installer"]:[[UpgradeRoot(prefix)stringByAppendingPathComponent:@"Previous/tools"]stringByAppendingPathComponent:@"installer"];
  if(!Exists(source))source=[UpgradeCurrent(prefix,@"tools")stringByAppendingPathComponent:@"installer"];
  NSData *bytes=ReadProtected(prefix,source,owner,error);if(!bytes||![Hash(bytes)isEqual:expected]||!MachExecutable(bytes))return Fail(error,@"approved recovery source missing");
  if(!WriteNew(pending,bytes,0755,error)||!UpgradePoint(@"recovery-prepublish",error)||![InstallFileHash(prefix,path,owner,error)isEqual:actual]||rename(pending.fileSystemRepresentation,path.fileSystemRepresentation))return NO;
  (void)record;
  return SyncInstallDirectory(path.stringByDeletingLastPathComponent,error)&&SyncInstallDirectory(pending.stringByDeletingLastPathComponent,error)&&UpgradePoint(@"recovery-published",error);
}
static BOOL UpgradeEraseStaging(NSString *prefix,uid_t owner,NSDictionary *record,NSDictionary *decoded,BOOL previous,NSString **error) {
  NSString *root=UpgradeRoot(prefix);if(!UpgradeStageNames(prefix,owner,error)||!UpgradeClearPending(prefix,owner,record,error))return NO;
  if(Exists([root stringByAppendingPathComponent:@"recovery.pending"]))return Fail(error,@"pending recovery must be reconciled first");
  for(NSString *group in @[@"Previous",@"Next"])for(NSString *slot in UpgradeSlots()) {
    NSString *path=[[root stringByAppendingPathComponent:group]stringByAppendingPathComponent:slot];BOOL old=[group isEqual:@"Previous"];
    if(old && !previous && Exists(path))return Fail(error,@"unrestored old backup preserved");
    if(!UpgradeTree(prefix,path,owner,UpgradeSlotEntries(record,decoded,!old,slot),NO,error))return NO;
  }
  for(NSString *slot in @[@"inbox",@"client"]) {
    NSString *name=[slot isEqual:@"inbox"]?@"Inbox":@"Client.app";
    if(!UpgradeTree(prefix,[[root stringByAppendingPathComponent:@"Payload"]stringByAppendingPathComponent:name],owner,UpgradeSlotEntries(record,decoded,YES,slot),NO,error))return NO;
  }
  // Validate the whole known remainder before deleting any stage content.
  for(NSString *group in @[@"Previous",@"Next"]) {
    for(NSString *slot in UpgradeSlots())if(!UpgradeRemove(prefix,[[root stringByAppendingPathComponent:group]stringByAppendingPathComponent:slot],owner,UpgradeSlotEntries(record,decoded,![group isEqual:@"Previous"],slot),error))return NO;
    if(!RemoveDirectory([root stringByAppendingPathComponent:group],error))return NO;
  }
  for(NSString *slot in @[@"inbox",@"client"])if(!UpgradeRemove(prefix,[[root stringByAppendingPathComponent:@"Payload"]stringByAppendingPathComponent:[slot isEqual:@"inbox"]?@"Inbox":@"Client.app"],owner,UpgradeSlotEntries(record,decoded,YES,slot),error))return NO;
  return RemoveDirectory([root stringByAppendingPathComponent:@"Payload"],error);
}
static BOOL UpgradeRetire(NSString *prefix,uid_t owner,NSDictionary *record,NSString **error) {
  if(!UpgradeMarkerValid(prefix,owner,record,YES,error))return NO;
  if(!RemoveDirectory(UpgradeRoot(prefix),error)||!SyncInstallDirectory(At(prefix,State),error)||!UpgradePoint(@"stage-retired",error))return NO;
  NSString *marker=UpgradeMarker(prefix);if(Exists(marker)&&(unlink(marker.fileSystemRepresentation)||!SyncInstallDirectory(marker.stringByDeletingLastPathComponent,error)))return NO;
  if(!UpgradePoint(@"marker-retired",error))return NO;
  NSString *path=At(prefix,RecoveryRecord);if(![ReadProtected(prefix,path,owner,error)isEqual:JSONData(record)]||unlink(path.fileSystemRepresentation))return Fail(error,@"upgrade approval retirement failed");
  return UpgradeSyncRetirement(prefix,error);
}
static BOOL BeginClientUpgradeFromScripts(NSString *prefix,uid_t owner,BOOL system,NSString *scripts,NSString **error) {
  if(!InstallScriptsProtected(scripts,owner,error))return NO;
  NSData *manifestBytes=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"manifest.json"],owner,error),*inventoryBytes=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"client-inventory.json"],owner,error),*plist=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"dev.kuro.tun.plist"],owner,error),*helper=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"preflight-native"],owner,error);
  NSDictionary *manifest=manifestBytes?KuroDecodeJSON(manifestBytes,MessageLimit,error):nil;
  if(!ValidManifest(manifest,error)||![manifest[@"installerProtocol"]isEqual:@2]||!helper||!MachExecutable(helper)||![Hash(helper)isEqual:manifest[@"helper"][@"sha256"]]||(system&&![Executable()isEqual:[scripts stringByAppendingPathComponent:@"preflight-native"]]))return Fail(error,@"protocol-2 fixed upgrade sidecars/helper required");
  if(Exists(At(prefix,RecoveryRecord))||Exists(UpgradeRoot(prefix))||Exists(UpgradeMarker(prefix)))return Fail(error,@"existing upgrade or recovery evidence preserved");
  if(!Exists(At(prefix,FreshReceipt))||!Exists(At(prefix,SocketDirectory)))return Fail(error,@"complete old installation is required; no upgrade state created");
  int lock=ServiceLock(prefix,owner,error);if(lock<0)return NO;
  @try {
    if(!UpgradeQuiescent(prefix,owner,system,error))return NO;
    NSData *oldReceipt=ReadProtected(prefix,At(prefix,FreshReceipt),owner,error),*installedBytes=ReadProtected(prefix,UpgradeCurrent(prefix,@"installed"),owner,error),*stopped=Exists(UpgradeCurrent(prefix,@"stopped"))?ReadProtected(prefix,UpgradeCurrent(prefix,@"stopped"),owner,error):nil;
    if(!oldReceipt||!installedBytes)return NO;
    NSDictionary *record=@{@"format":@2,@"operation":@"upgrade",@"transaction":NSUUID.UUID.UUIDString,@"phase":@"staging",@"oldReceiptJSON":UpgradeString(oldReceipt)?:@"",@"oldInstalledJSON":UpgradeString(installedBytes)?:@"",@"oldStoppedJSON":stopped?(UpgradeString(stopped)?:@""):NSNull.null,@"newManifestJSON":UpgradeString(manifestBytes),@"newInventoryJSON":UpgradeString(inventoryBytes)?:@"",@"newPlistBase64":[plist base64EncodedStringWithOptions:0]?:@""};
    NSDictionary *decoded=UpgradeDecode(record,error);if(!decoded||!UpgradeCurrentFull(prefix,owner,record,decoded,NO,YES,error))return NO;
    // All fixed rename parents must be on one filesystem before approval is issued.
    struct stat baseline;if(lstat(At(prefix,State).fileSystemRepresentation,&baseline))return NO;
    for(NSString *parent in @[At(prefix,Tools).stringByDeletingLastPathComponent,At(prefix,ClientBundle).stringByDeletingLastPathComponent,At(prefix,Plist).stringByDeletingLastPathComponent]) {struct stat value;if(!SafeChain(prefix,parent,owner,YES,error)||lstat(parent.fileSystemRepresentation,&value)||value.st_dev!=baseline.st_dev)return Fail(error,@"upgrade fixed paths cross filesystems or have unsafe ancestors");}
    NSData *bytes=JSONData(record);if(bytes.length>128*1024*1024)return Fail(error,@"bounded upgrade receipt exceeded");
    if(!WriteNew(At(prefix,RecoveryRecord),bytes,0600,error)||!SyncInstallDirectory(At(prefix,RecoveryRecord).stringByDeletingLastPathComponent,error)||!UpgradePoint(@"approval",error))return NO;
    if(!WriteNew(UpgradeMarker(prefix),JSONData(UpgradeMarkerValue(record)),0600,error)||!SyncInstallDirectory(At(prefix,State),error)||!UpgradePoint(@"marker",error))return NO;
    return EnsureDirectory(prefix,UpgradeRoot(prefix),owner,0700,error)&&EnsureDirectory(prefix,[UpgradeRoot(prefix)stringByAppendingPathComponent:@"Payload"],owner,0700,error)&&UpgradePoint(@"staging-ready",error);
  } @finally {close(lock);}
}
static BOOL UpgradePrepareNext(NSString *prefix,uid_t owner,NSDictionary *record,NSDictionary *decoded,NSString **error) {
  NSString *root=UpgradeRoot(prefix),*payload=[root stringByAppendingPathComponent:@"Payload"],*next=[root stringByAppendingPathComponent:@"Next"];
  if(!UpgradeStageNames(prefix,owner,error)||Exists(next)||Exists([root stringByAppendingPathComponent:@"Previous"]))return Fail(error,@"interrupted staged preparation requires explicit recovery");
  for(NSString *slot in @[@"inbox",@"client"])if(!UpgradeTree(prefix,[payload stringByAppendingPathComponent:[slot isEqual:@"inbox"]?@"Inbox":@"Client.app"],owner,UpgradeSlotEntries(record,decoded,YES,slot),YES,error))return NO;
  NSDictionary *receipt=decoded[@"next"],*manifest=receipt[@"manifest"];
  if(![KuroClientSnapshot(prefix,[payload stringByAppendingPathComponent:@"Client.app"],owner,error)isEqual:manifest[@"client"]])return Fail(error,@"staged upgraded App seal/pin mismatch");
  for(NSString *name in @[@"helper",@"mihomo"])if(!MachExecutable(ReadProtected(prefix,[[payload stringByAppendingPathComponent:@"Inbox"]stringByAppendingPathComponent:name],owner,error)))return Fail(error,@"staged executable is not the exact supported Mach-O");
  if(!EnsureDirectory(prefix,next,owner,0700,error)||!EnsureDirectory(prefix,[root stringByAppendingPathComponent:@"Previous"],owner,0700,error))return NO;
  NSString *tools=[next stringByAppendingPathComponent:@"tools"],*version=[tools stringByAppendingPathComponent:[@"versions"stringByAppendingPathComponent:manifest[@"release"]]];
  if(!EnsureDirectory(prefix,version,owner,0755,error))return NO;
  for(NSArray *item in @[@[@"helper",@"installer"],@[@"helper",[@"versions"stringByAppendingPathComponent:[manifest[@"release"]stringByAppendingPathComponent:@"helper"]]],@[@"mihomo",[@"versions"stringByAppendingPathComponent:[manifest[@"release"]stringByAppendingPathComponent:@"mihomo"]]],@[@"manifest.json",[@"versions"stringByAppendingPathComponent:[manifest[@"release"]stringByAppendingPathComponent:@"manifest.json"]]]]) {
    NSData *bytes=ReadProtected(prefix,[[payload stringByAppendingPathComponent:@"Inbox"]stringByAppendingPathComponent:item[0]],owner,error);
    if(!bytes||!WriteNew([tools stringByAppendingPathComponent:item[1]],bytes,[item[0]isEqual:@"manifest.json"]?0600:0755,error)||!UpgradePoint([@"prepare:"stringByAppendingString:item[1]],error))return NO;
  }
  NSDictionary *files=@{@"installed":JSONData(decoded[@"nextInstalled"]),@"client-pin":JSONData(manifest[@"client"]),@"plist":receipt[@"plist"],@"receipt":decoded[@"nextReceiptBytes"]};
  for(NSString *slot in @[@"installed",@"client-pin",@"plist",@"receipt"])if(!WriteNew([next stringByAppendingPathComponent:slot],files[slot],[slot isEqual:@"plist"]?0644:0600,error)||!UpgradePoint([@"prepare:"stringByAppendingString:slot],error))return NO;
  if(decoded[@"nextStopped"]!=NSNull.null && !WriteNew([next stringByAppendingPathComponent:@"stopped"],JSONData(decoded[@"nextStopped"]),0600,error))return NO;
  for(NSString *slot in @[@"inbox",@"client"])if(!UpgradeRename(prefix,owner,[payload stringByAppendingPathComponent:[slot isEqual:@"inbox"]?@"Inbox":@"Client.app"],[next stringByAppendingPathComponent:slot],UpgradeSlotEntries(record,decoded,YES,slot),error))return NO;
  for(NSString *slot in UpgradeSlots())if(!UpgradeTree(prefix,[next stringByAppendingPathComponent:slot],owner,UpgradeSlotEntries(record,decoded,YES,slot),YES,error))return NO;
  for(NSString *directory in @[version,version.stringByDeletingLastPathComponent,tools,next,root])if(!SyncInstallDirectory(directory,error))return NO;
  return YES;
}
static BOOL UpgradeFinish(NSString *prefix,uid_t owner,NSDictionary *record,NSDictionary *decoded,NSString **error) {
  if(![record[@"phase"]isEqual:@"finalizing"]||!UpgradeCurrentFull(prefix,owner,record,decoded,YES,YES,error))return Fail(error,@"forward finalization requires complete new payload and exact new recovery");
  if(!UpgradeEraseStaging(prefix,owner,record,decoded,YES,error))return NO;
  if(!UpgradeCurrentFull(prefix,owner,record,decoded,YES,YES,error))return NO;
  return UpgradeRetire(prefix,owner,record,error);
}
static BOOL CompleteClientUpgradeFromScripts(NSString *prefix,uid_t owner,BOOL system,NSString *scripts,NSString **error) {
  if(!InstallScriptsProtected(scripts,owner,error))return NO;
  int lock=ServiceLock(prefix,owner,error);if(lock<0)return NO;
  @try {
    NSMutableDictionary *record=[UpgradeRead(prefix,owner,error)mutableCopy];NSDictionary *decoded=record?UpgradeDecode(record,error):nil;if(!decoded)return NO;
    NSData *selfBytes=ReadProtected(scripts,[scripts stringByAppendingPathComponent:@"preflight-native"],owner,error);
    if(![Hash(selfBytes)isEqual:decoded[@"next"][@"manifest"][@"helper"][@"sha256"]]||(system&&![Executable()isEqual:[scripts stringByAppendingPathComponent:@"preflight-native"]]))return Fail(error,@"upgrade completion executable identity mismatch");
    if(![record[@"phase"]isEqual:@"staging"]||!UpgradeQuiescent(prefix,owner,system,error)||!UpgradeMarkerValid(prefix,owner,record,NO,error)||!UpgradeCurrentFull(prefix,owner,record,decoded,NO,YES,error)||!UpgradePrepareNext(prefix,owner,record,decoded,error))return NO;
    if(!UpgradePhase(prefix,owner,record,@"switching",error))return NO;
    NSString *root=UpgradeRoot(prefix),*next=[root stringByAppendingPathComponent:@"Next"],*previous=[root stringByAppendingPathComponent:@"Previous"];
    for(NSString *slot in UpgradeSlots()) {
      NSDictionary *old=UpgradeSlotEntries(record,decoded,NO,slot),*new=UpgradeSlotEntries(record,decoded,YES,slot);NSString *current=UpgradeCurrent(prefix,slot);
      if(old && !UpgradeRename(prefix,owner,current,[previous stringByAppendingPathComponent:slot],old,error))return NO;
      if(new && !UpgradeRename(prefix,owner,[next stringByAppendingPathComponent:slot],current,new,error))return NO;
    }
    if(!UpgradePhase(prefix,owner,record,@"next-installed",error)||!UpgradeCurrentFull(prefix,owner,record,decoded,YES,NO,error)||!UpgradeRecoveryBytes(prefix,owner,record,decoded,YES,error)||!UpgradePhase(prefix,owner,record,@"finalizing",error))return NO;
    return UpgradeFinish(prefix,owner,record,decoded,error);
  } @finally {close(lock);}
}
static BOOL RecoverClientUpgrade(NSString *prefix,uid_t owner,BOOL system,NSString *entry,NSString **error) {
  if(![entry isEqual:At(prefix,Recovery)] || (system&&![Executable()isEqual:entry]))return Fail(error,@"fixed protected upgrade recovery entry required");
  if(!Exists(At(prefix,SocketDirectory)) || (!Exists(At(prefix,RecoveryRecord))&&!Exists(At(prefix,FreshReceipt))))return Fail(error,@"no approved upgrade or complete installation to observe");
  int lock=ServiceLock(prefix,owner,error);if(lock<0)return NO;
  @try {
    if(!UpgradeQuiescent(prefix,owner,system,error))return NO;
    if(!Exists(At(prefix,RecoveryRecord))) {
      // Idempotent observation only; absent evidence never authorizes deleting a partial tree.
      if(Exists(UpgradeRoot(prefix))||Exists(UpgradeMarker(prefix)))return Fail(error,@"unapproved partial upgrade remains");
      NSDictionary *receipt=ReadFreshReceipt(prefix,owner,error),*installed=ReadJSON(prefix,UpgradeCurrent(prefix,@"installed"),owner,error);
      if(!receipt||receipt[@"uninstall"]||![receipt[@"manifest"][@"installerProtocol"]isEqual:@2]||!UpgradeInstalled(installed,receipt)||![InstallFileHash(prefix,entry,owner,error)isEqual:installed[@"helperSHA256"]])return Fail(error,@"no complete protocol-2 off installation to observe");
      if(![installed[@"neverStarted"]boolValue]&&!KuroStoppedBoundToReceipt(ReadJSON(prefix,UpgradeCurrent(prefix,@"stopped"),owner,error),receipt,installed))return Fail(error,@"completed upgrade off proof absent");
      NSData *raw=ReadProtected(prefix,At(prefix,FreshReceipt),owner,error),*installedBytes=ReadProtected(prefix,UpgradeCurrent(prefix,@"installed"),owner,error),*stoppedBytes=Exists(UpgradeCurrent(prefix,@"stopped"))?ReadProtected(prefix,UpgradeCurrent(prefix,@"stopped"),owner,error):nil;
      NSDictionary *observedRecord=@{@"oldReceiptJSON":UpgradeString(raw),@"oldInstalledJSON":UpgradeString(installedBytes),@"oldStoppedJSON":stoppedBytes?UpgradeString(stoppedBytes):NSNull.null};
      return UpgradeCurrentFull(prefix,owner,observedRecord,@{@"old":receipt,@"installed":installed},NO,YES,error) && UpgradeSyncRetirement(prefix,error);
    }
    NSDictionary *record=UpgradeRead(prefix,owner,error),*decoded=record?UpgradeDecode(record,error):nil;if(!decoded||!UpgradeMarkerValid(prefix,owner,record,YES,error)||!UpgradeStageNames(prefix,owner,error))return NO;
    NSString *selfHash=InstallFileHash(prefix,entry,owner,error);
    if(![selfHash isEqual:decoded[@"old"][@"manifest"][@"helper"][@"sha256"]]&&![selfHash isEqual:decoded[@"next"][@"manifest"][@"helper"][@"sha256"]])return Fail(error,@"unapproved recovery binary preserved");
    if([record[@"phase"]isEqual:@"finalizing"])return UpgradeFinish(prefix,owner,record,decoded,error);
    NSString *root=UpgradeRoot(prefix),*previous=[root stringByAppendingPathComponent:@"Previous"];
    // First validate every distributed old/new object; unknown content prevents all deletion.
    for(NSString *slot in UpgradeSlots()) {
      NSDictionary *old=UpgradeSlotEntries(record,decoded,NO,slot),*next=UpgradeSlotEntries(record,decoded,YES,slot);NSString *backup=[previous stringByAppendingPathComponent:slot],*current=UpgradeCurrent(prefix,slot);
      if(Exists(backup)) {
        if(!old||!UpgradeTree(prefix,backup,owner,old,YES,error)||!UpgradeTree(prefix,current,owner,next,NO,error))return NO;
      } else if(!UpgradeTree(prefix,current,owner,old,YES,error))return NO;
    }
    for(NSString *group in @[@"Previous",@"Next"])for(NSString *slot in UpgradeSlots()) {
      NSString *path=[[root stringByAppendingPathComponent:group]stringByAppendingPathComponent:slot];
      if(!UpgradeTree(prefix,path,owner,UpgradeSlotEntries(record,decoded,![group isEqual:@"Previous"],slot),NO,error))return NO;
    }
    for(NSString *slot in @[@"inbox",@"client"])if(!UpgradeTree(prefix,[[root stringByAppendingPathComponent:@"Payload"]stringByAppendingPathComponent:[slot isEqual:@"inbox"]?@"Inbox":@"Client.app"],owner,UpgradeSlotEntries(record,decoded,YES,slot),NO,error))return NO;
    NSString *pendingRecovery=[root stringByAppendingPathComponent:@"recovery.pending"];
    if(Exists(pendingRecovery)) {
      NSString *pendingHash=InstallFileHash(prefix,pendingRecovery,owner,error);
      if(![pendingHash isEqual:decoded[@"old"][@"manifest"][@"helper"][@"sha256"]]&&![pendingHash isEqual:decoded[@"next"][@"manifest"][@"helper"][@"sha256"]])return Fail(error,@"unknown recovery candidate preserved");
    }
    for(NSString *slot in UpgradeSlots()) {
      NSString *backup=[previous stringByAppendingPathComponent:slot],*current=UpgradeCurrent(prefix,slot);
      if(Exists(backup)) {
        if(!UpgradeRemove(prefix,current,owner,UpgradeSlotEntries(record,decoded,YES,slot),error)||!UpgradeRename(prefix,owner,backup,current,UpgradeSlotEntries(record,decoded,NO,slot),error))return NO;
      }
    }
    if(!UpgradeRecoveryBytes(prefix,owner,record,decoded,NO,error)||!UpgradeCurrentFull(prefix,owner,record,decoded,NO,YES,error)||!UpgradeEraseStaging(prefix,owner,record,decoded,NO,error))return NO;
    return UpgradeRetire(prefix,owner,record,error);
  } @finally {close(lock);}
}
