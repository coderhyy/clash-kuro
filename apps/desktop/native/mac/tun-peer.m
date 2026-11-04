// Kernel peer identity observation is a liveness check, never an authorization
// decision. A fully authenticated open must capture it only after Authorize.
@interface KuroPeerIdentity : NSObject {
  NSData *_audit;
  NSData *_cdhash;
}
+ (instancetype)observePeer:(int)peer error:(NSString **)error;
- (BOOL)isLive;
@end
@implementation KuroPeerIdentity
+ (instancetype)observePeer:(int)peer error:(NSString **)error {
  audit_token_t token; socklen_t size = sizeof(token);
  if (getsockopt(peer, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token) || audit_token_to_pid(token) <= 0) { Fail(error, @"peer audit token is unavailable"); return nil; }
  SecCodeRef code = NULL; if (!PeerCode(peer, &code, error)) return nil;
  CFDictionaryRef raw = NULL; OSStatus copied = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw); CFRelease(code);
  if (copied != errSecSuccess) { Fail(error, @"peer identity is unavailable"); return nil; }
  NSDictionary *info = CFBridgingRelease(raw); NSData *identity = info[(__bridge NSString *)kSecCodeInfoUnique];
  if (![identity isKindOfClass:NSData.class] || !identity.length) { Fail(error, @"peer code has no exact identity"); return nil; }
  KuroPeerIdentity *result = [KuroPeerIdentity new]; result->_audit = [NSData dataWithBytes:&token length:sizeof(token)]; result->_cdhash = [identity copy]; return result;
}
- (BOOL)isLive {
  // The full kernel audit token includes pidversion. An inherited/SCM_RIGHTS
  // socket FD is not proof that the originally approved client is still alive.
  NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit:_audit};
  SecCodeRef code = NULL; CFDictionaryRef raw = NULL;
  OSStatus valid = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, 0, &code);
  if (valid == errSecSuccess) valid = SecCodeCheckValidity(code, kSecCSStrictValidate, NULL);
  if (valid == errSecSuccess) valid = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &raw);
  if (code) CFRelease(code);
  NSDictionary *info = raw ? CFBridgingRelease(raw) : nil;
  return valid == errSecSuccess && [_cdhash isEqual:info[(__bridge NSString *)kSecCodeInfoUnique]];
}
@end
