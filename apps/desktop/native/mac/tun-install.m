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
  if (manifest[@"client"]) manifestKeys = [manifestKeys arrayByAddingObject:@"client"];
  if (manifest[@"clientInventorySHA256"]) manifestKeys = [manifestKeys arrayByAddingObject:@"clientInventorySHA256"];
  if (!Keys(manifest, manifestKeys) || (manifest[@"client"] && !KuroClientPinValid(manifest[@"client"])) ||
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
static NSDictionary *ReadFreshReceipt(NSString *prefix,uid_t owner,NSString **error) {
  NSData *raw=ReadProtected(prefix,At(prefix,FreshReceipt),owner,error);id receipt=KuroDecodeJSON(raw,InventoryLimit*2,error);
  if(!KuroMapping(receipt,@[@"format",@"helperSHA256",@"manifestJSON",@"inventoryJSON",@"plistBase64"],@[@"uninstallJSON"]) || !KuroNumber(receipt[@"format"],1,1) || ![receipt[@"manifestJSON"] isKindOfClass:NSString.class] || ![receipt[@"inventoryJSON"] isKindOfClass:NSString.class] || ![receipt[@"plistBase64"] isKindOfClass:NSString.class]) {Fail(error,@"invalid fresh installation receipt");return nil;}
  NSData *manifestBytes=[receipt[@"manifestJSON"] dataUsingEncoding:NSUTF8StringEncoding],*inventoryBytes=[receipt[@"inventoryJSON"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *manifest=KuroDecodeJSON(manifestBytes,MessageLimit,error),*inventory=KuroDecodeJSON(inventoryBytes,InventoryLimit,error);NSData *plist=[[NSData alloc] initWithBase64EncodedString:receipt[@"plistBase64"] options:0];
  if(!ValidManifest(manifest,error) || !manifest[@"client"] || ![Hash(inventoryBytes) isEqual:manifest[@"clientInventorySHA256"]] || ![receipt[@"helperSHA256"] isEqual:manifest[@"helper"][@"sha256"]] || !FixedPlist(plist,manifest[@"release"],error) || !InventoryEntries(inventory,error)) {Fail(error,@"fresh receipt payload binding failed");return nil;}
  NSMutableDictionary *result=[@{@"manifest":manifest,@"manifestBytes":manifestBytes,@"inventory":inventory,@"inventoryBytes":inventoryBytes,@"plist":plist}mutableCopy];
  if(receipt[@"uninstallJSON"]) {
    if(![receipt[@"uninstallJSON"]isKindOfClass:NSString.class]) {Fail(error,@"invalid stopped uninstall approval");return nil;}
    NSDictionary *approval=KuroDecodeJSON([receipt[@"uninstallJSON"]dataUsingEncoding:NSUTF8StringEncoding],MessageLimit,error);
    if(!Keys(approval,@[@"format",@"installed",@"stopped"]) || !KuroNumber(approval[@"format"],1,1) || !KuroStoppedProofValid(approval[@"stopped"],manifest,manifestBytes,inventoryBytes,approval[@"installed"])) {Fail(error,@"stopped uninstall approval does not match this payload");return nil;}
    result[@"uninstall"]=approval;
  }
  return result;
}
// Capability admission follows dynamic peer authentication. Neither this receipt
// nor an auth-only connection grants arbitrary commands or automatic startup.
static BOOL KuroSessionActivationAt(NSString *prefix,uid_t owner,NSString *executingHelper,NSString **error) {
  if(Exists(At(prefix,[State stringByAppendingPathComponent:@"transaction.json"])))return Fail(error,@"finite session activation requires a completed installation transaction");
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
    if(!receipt || receipt[@"uninstall"] || !KuroStoppedProofValid(proof,receipt[@"manifest"],receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed) ||
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
      if(!KuroStoppedProofValid(stopped,manifest,receipt[@"manifestBytes"],receipt[@"inventoryBytes"],installed))return Fail(error,@"running-history install requires its protected completed-stop checkpoint");
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
