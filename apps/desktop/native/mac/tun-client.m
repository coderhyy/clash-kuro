// Installation approves exact App bytes, not a UID or a caller-provided path.
static NSString *const ClientBundle = @"/Library/Application Support/Clash Kuro/Client/Clash Kuro.app";
static NSString *const ClientExecutable = @"Contents/MacOS/Clash Kuro";
static BOOL KuroClientPinValid(NSDictionary *pin) {
  if (!Keys(pin, @[@"format", @"cdhash", @"executableSHA256", @"infoSHA256", @"asarSHA256"]) ||
      ![pin[@"format"] isEqual:@2] || !Match(pin[@"cdhash"], @"\\A[0-9a-f]{40}\\z")) return NO;
  for (NSString *key in @[@"executableSHA256", @"infoSHA256", @"asarSHA256"])
    if (!Match(pin[key], @"\\A[0-9a-f]{64}\\z")) return NO;
  return YES;
}
static BOOL KuroClientTree(NSString *anchor, NSString *bundle, NSString *directory, uid_t owner, NSUInteger *remaining, NSString **error) {
  if (!(*remaining)-- || !SafeChain(anchor, directory, owner, YES, error)) return Fail(error, @"client directory is not protected or exceeds traversal limit");
  NSError *failure = nil;
  NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:&failure];
  if (!entries || failure) return Fail(error, @"client resource enumeration failed");
  for (NSString *entry in entries) {
    NSString *path = [directory stringByAppendingPathComponent:entry];
    struct stat info;
    if (!(*remaining)-- || lstat(path.fileSystemRepresentation, &info)) return Fail(error, @"client resource unavailable or traversal limit exceeded");
    if (S_ISLNK(info.st_mode)) {
      NSString *frameworks = [bundle stringByAppendingPathComponent:@"Contents/Frameworks/"];
      char target[PATH_MAX], resolved[PATH_MAX];
      ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
      if (info.st_uid != owner || ![path hasPrefix:frameworks] || length <= 0 || length >= PATH_MAX - 1) return Fail(error, @"only owned internal Framework links are permitted");
      target[length] = 0;
      if (target[0] == '/' || !realpath(path.fileSystemRepresentation, resolved)) return Fail(error, @"absolute or broken client link");
      NSString *destination = [NSString stringWithUTF8String:resolved];
      struct stat actual;
      if (![destination hasPrefix:frameworks] || lstat(resolved, &actual) ||
          !SafeChain(anchor, destination, owner, S_ISDIR(actual.st_mode), error)) return Fail(error, @"client link escapes protected Framework resources");
    } else if (S_ISDIR(info.st_mode)) {
      if (!KuroClientTree(anchor, bundle, path, owner, remaining, error)) return NO;
    } else if (!SafeNode(path, owner, NO, error)) return NO;
  }
  return YES;
}
static BOOL KuroClientProtected(NSString *anchor, NSString *bundle, uid_t owner, NSString **error) {
  NSUInteger remaining = 100000;
  return KuroClientTree(anchor, bundle, bundle, owner, &remaining, error);
}
static BOOL KuroClientHardening(NSDictionary *info, NSString **error) {
  NSNumber *flags = info[(__bridge NSString *)kSecCodeInfoFlags];
  NSDictionary *entitlements = info[(__bridge NSString *)kSecCodeInfoEntitlementsDict];
  if (!(flags.unsignedIntValue & 0x10000) || [entitlements[@"com.apple.security.get-task-allow"] boolValue] ||
      [entitlements[@"com.apple.security.cs.allow-dyld-environment-variables"] boolValue]) return Fail(error, @"client runtime or injection protections are insufficient");
  // This allow-list is only a necessary condition; the final runtime gate stays closed.
  for (NSString *key in entitlements)
    if (![@[@"com.apple.security.cs.allow-jit", @"com.apple.security.cs.disable-library-validation"] containsObject:key] ||
        ![entitlements[key] isEqual:@YES]) return Fail(error, @"unapproved client entitlement");
  return YES;
}
static NSDictionary *KuroClientSnapshot(NSString *anchor, NSString *bundle, uid_t owner, NSString **error) {
  if (!KuroClientProtected(anchor, bundle, owner, error)) return nil;
  SecStaticCodeRef code = NULL;
  NSURL *url = [NSURL fileURLWithPath:bundle];
  OSStatus valid = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, 0, &code);
  if (valid == errSecSuccess) valid = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, NULL);
  CFDictionaryRef raw = NULL;
  if (valid == errSecSuccess) valid = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
  if (code) CFRelease(code);
  NSDictionary *info = CFBridgingRelease(raw);
  if (valid != errSecSuccess || ![info[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:@"dev.kuro.desktop"] || !KuroClientHardening(info, error)) {
    Fail(error, @"client seal, identifier or hardening policy failed"); return nil;
  }
  NSData *main = ReadProtected(anchor, [bundle stringByAppendingPathComponent:ClientExecutable], owner, error);
  NSData *plist = ReadProtected(anchor, [bundle stringByAppendingPathComponent:@"Contents/Info.plist"], owner, error);
  NSData *asar = ReadProtected(anchor, [bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"], owner, error);
  NSData *identity = info[(__bridge NSString *)kSecCodeInfoUnique];
  if (!main || !plist || !asar || identity.length != 20) return nil;
  NSDictionary *pin = @{@"format":@2, @"cdhash":Hex(identity), @"executableSHA256":Hash(main), @"infoSHA256":Hash(plist), @"asarSHA256":Hash(asar)};
  return KuroClientPinValid(pin) ? pin : nil;
}
