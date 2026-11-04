// Root-side closed schema. No raw YAML, filesystem paths, providers or Core HTTP
// requests are accepted. This produces a candidate; it does not authorize start.
#include <arpa/inet.h>
#include <math.h>
@interface KuroJSONScanner : NSObject
@property(nonatomic) NSString *text;
@property(nonatomic) NSUInteger cursor;
- (BOOL)value:(NSUInteger)depth;
@end
@implementation KuroJSONScanner
- (void)space { while (_cursor < _text.length && [[NSCharacterSet characterSetWithCharactersInString:@" \r\n\t"] characterIsMember:[_text characterAtIndex:_cursor]]) _cursor++; }
- (NSString *)string {
  [self space]; NSUInteger start = _cursor;
  if (_cursor >= _text.length || [_text characterAtIndex:_cursor++] != '"') return nil;
  BOOL escaped = NO;
  while (_cursor < _text.length) {
    unichar c = [_text characterAtIndex:_cursor++];
    if (escaped) { escaped = NO; continue; }
    if (c == '\\') { escaped = YES; continue; }
    if (c == '"') {
      NSString *wrapped = [NSString stringWithFormat:@"[%@]", [_text substringWithRange:NSMakeRange(start, _cursor - start)]];
      NSArray *parsed = [NSJSONSerialization JSONObjectWithData:[wrapped dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
      return parsed.count == 1 && [parsed[0] isKindOfClass:NSString.class] ? parsed[0] : nil;
    }
  }
  return nil;
}
- (BOOL)value:(NSUInteger)depth {
  if (depth > 32) return NO;
  [self space]; if (_cursor >= _text.length) return NO;
  unichar c = [_text characterAtIndex:_cursor];
  if (c == '"') return [self string] != nil;
  if (c == '{' || c == '[') {
    _cursor++; [self space]; unichar end = c == '{' ? '}' : ']'; NSMutableSet *keys = [NSMutableSet set];
    if (_cursor < _text.length && [_text characterAtIndex:_cursor] == end) { _cursor++; return YES; }
    for (;;) {
      if (c == '{') { NSString *key = [self string]; [self space]; if (!key || [keys containsObject:key] || _cursor >= _text.length || [_text characterAtIndex:_cursor++] != ':') return NO; [keys addObject:key]; }
      if (![self value:depth + 1]) return NO;
      [self space]; if (_cursor >= _text.length) return NO;
      unichar separator = [_text characterAtIndex:_cursor++]; if (separator == end) return YES; if (separator != ',') return NO;
    }
  }
  NSUInteger start = _cursor;
  while (_cursor < _text.length && ![[NSCharacterSet characterSetWithCharactersInString:@",]} \t\r\n"] characterIsMember:[_text characterAtIndex:_cursor]]) _cursor++;
  return _cursor > start; // Foundation independently checks all primitive syntax.
}
@end
static id KuroDecodeJSON(NSData *data, NSUInteger limit, NSString **error) {
  if (!data.length || data.length > limit) { Fail(error, @"JSON frame exceeds its byte limit"); return nil; }
  KuroJSONScanner *scanner = [KuroJSONScanner new]; scanner.text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!scanner.text || ![scanner value:0]) { Fail(error, @"invalid JSON, duplicate keys or excessive nesting"); return nil; }
  [scanner space]; if (scanner.cursor != scanner.text.length) { Fail(error, @"trailing JSON input"); return nil; }
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if (!value) Fail(error, @"invalid JSON syntax"); return value;
}
static BOOL KuroBool(id value) { return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(); }
static BOOL KuroNumber(id value, NSUInteger minimum, NSUInteger maximum) {
  if (![value isKindOfClass:NSNumber.class] || KuroBool(value)) return NO;
  double number = [value doubleValue]; return isfinite(number) && number >= minimum && number <= maximum && floor(number) == number;
}
static BOOL KuroMapping(id value, NSArray *required, NSArray *optional) {
  if (![value isKindOfClass:NSDictionary.class]) return NO;
  NSSet *keys = [NSSet setWithArray:[value allKeys]]; NSMutableSet *allowed = [NSMutableSet setWithArray:required]; [allowed addObjectsFromArray:optional];
  return [keys isSubsetOfSet:allowed] && [[NSSet setWithArray:required] isSubsetOfSet:keys];
}
static BOOL KuroText(id value, NSUInteger maximum) {
  if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > maximum) return NO;
  NSCharacterSet *controls = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 32)];
  return [value rangeOfCharacterFromSet:controls].location == NSNotFound && [value rangeOfString:@"\x7f"].location == NSNotFound && [value dataUsingEncoding:NSUTF8StringEncoding] != nil;
}
static BOOL KuroArray(id value, NSUInteger maximum, BOOL nonempty) { return [value isKindOfClass:NSArray.class] && [value count] <= maximum && (!nonempty || [value count]); }
static BOOL KuroDomain(id value) {
  if (!KuroText(value, 253)) return NO;
  for (NSString *part in [value componentsSeparatedByString:@"."]) if (!Match(part, @"\\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\z")) return NO;
  return YES;
}
static BOOL KuroProxyName(id value) {
  if (!KuroText(value, 128) || ![value isEqual:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] || [value containsString:@","]) return NO;
  return ![@[@"DIRECT", @"REJECT", @"REJECT-DROP", @"PASS", @"COMPATIBLE", @"GLOBAL", @"__PROTO__", @"CONSTRUCTOR", @"PROTOTYPE"] containsObject:[value uppercaseString]];
}
static int KuroIP(NSString *text, unsigned char *bytes) {
  if (!KuroText(text, 45) || [text containsString:@"%"] || ([text containsString:@":"] && [text containsString:@"."])) return 0;
  if (inet_pton(AF_INET, text.UTF8String, bytes) == 1) return 4;
  return inet_pton(AF_INET6, text.UTF8String, bytes) == 1 ? 16 : 0;
}
static BOOL KuroResolvers(id value) {
  if (!KuroArray(value, 16, YES)) return NO;
  for (id address in value) {
    unsigned char bytes[16] = {0}; int size = KuroIP(address, bytes); BOOL zero = YES;
    for (int i = 0; i < size; i++) if (bytes[i]) zero = NO;
    if (!size || zero || (size == 4 ? bytes[0] == 0 || bytes[0] >= 224 : bytes[0] == 255)) return NO;
    if (size == 4 && bytes[0] == 198 && bytes[1] == 18 && bytes[2] == 0 && bytes[3] < 4) return NO;
    const unsigned char pool[15] = {0xfd,0xfe,0xdc,0xba,0x98,0x76,0,0,0,0,0,0,0,0,0};
    if (size == 16 && !memcmp(bytes, pool, 15) && bytes[15] < 4) return NO;
  }
  return YES;
}
static BOOL KuroProxy(NSDictionary *proxy) {
  NSArray *base = @[@"type", @"name", @"server", @"port"];
  NSString *type = proxy[@"type"]; NSArray *required = nil, *optional = nil;
  if ([type isEqual:@"ss"]) { required = [base arrayByAddingObjectsFromArray:@[@"cipher", @"password"]]; optional = @[@"udp"]; }
  else if ([type isEqual:@"trojan"]) { required = [base arrayByAddingObject:@"password"]; optional = @[@"udp", @"sni", @"skip-cert-verify"]; }
  else if ([type isEqual:@"socks5"] || [type isEqual:@"http"]) { required = base; optional = @[@"udp", @"username", @"password", @"tls"]; }
  else return NO;
  if (!KuroMapping(proxy, required, optional) || !KuroProxyName(proxy[@"name"]) || !KuroNumber(proxy[@"port"], 1, 65535)) return NO;
  unsigned char address[16]; if (!KuroIP(proxy[@"server"], address) && !KuroDomain(proxy[@"server"])) return NO;
  if (proxy[@"udp"] && !KuroBool(proxy[@"udp"])) return NO;
  for (NSString *key in @[@"username", @"password"]) if (proxy[key] && !KuroText(proxy[key], 1024)) return NO;
  if ([type isEqual:@"ss"] && ![@[@"aes-128-gcm", @"aes-192-gcm", @"aes-256-gcm", @"chacha20-ietf-poly1305"] containsObject:proxy[@"cipher"]]) return NO;
  if ([type isEqual:@"trojan"]) {
    if (proxy[@"sni"] && !KuroDomain(proxy[@"sni"])) return NO;
    if (proxy[@"skip-cert-verify"] && (!KuroBool(proxy[@"skip-cert-verify"]) || [proxy[@"skip-cert-verify"] boolValue])) return NO;
  } else if (![type isEqual:@"ss"]) {
    if ((proxy[@"username"] != nil) != (proxy[@"password"] != nil)) return NO;
    if (proxy[@"tls"] && (!KuroBool(proxy[@"tls"]) || [proxy[@"tls"] boolValue])) return NO;
  }
  return YES;
}
static BOOL KuroRule(NSDictionary *rule, NSSet *targets) {
  if (!Keys(rule, @[@"type", @"value", @"target", @"noResolve"]) || ![targets containsObject:rule[@"target"]] || !KuroBool(rule[@"noResolve"])) return NO;
  NSString *type = rule[@"type"], *value = rule[@"value"];
  if ([type isEqual:@"MATCH"]) return [value isEqual:@""] && ![rule[@"noResolve"] boolValue];
  if ([type isEqual:@"IP-CIDR"] || [type isEqual:@"IP-CIDR6"]) {
    if (!KuroText(value, 49)) return NO; NSArray *parts = [value componentsSeparatedByString:@"/"]; if (parts.count != 2) return NO;
    unsigned char bytes[16]; int family = [type isEqual:@"IP-CIDR"] ? 4 : 16;
    return KuroIP(parts[0], bytes) == family && Match(parts[1], @"\\A(?:0|[1-9][0-9]{0,2})\\z") && [parts[1] integerValue] <= (family == 4 ? 32 : 128);
  }
  if ([rule[@"noResolve"] boolValue]) return NO;
  if ([type isEqual:@"DOMAIN"] || [type isEqual:@"DOMAIN-SUFFIX"]) return KuroDomain(value);
  return [type isEqual:@"DOMAIN-KEYWORD"] && KuroText(value, 253) && Match(value, @"\\A[a-zA-Z0-9.-]+\\z");
}
static NSDictionary *KuroValidateTunConfig(NSData *data, NSString **error) {
  id session = KuroDecodeJSON(data, 65536, error);
  if (!Keys(session, @[@"version", @"template", @"mode", @"proxies", @"groups", @"rules", @"dns"]) || !KuroNumber(session[@"version"], 1, 1) || ![session[@"template"] isEqual:@"macos-dual-stack-v1"] || ![@[@"rule", @"global", @"direct"] containsObject:session[@"mode"]]) { Fail(error, @"unsupported TUN session envelope"); return nil; }
  if (!KuroArray(session[@"proxies"], 128, NO) || !KuroArray(session[@"groups"], 128, NO) || !KuroArray(session[@"rules"], 256, YES)) { Fail(error, @"TUN collection limits exceeded"); return nil; }
  NSMutableSet *names = [NSMutableSet setWithArray:@[@"DIRECT", @"REJECT"]];
  for (id proxy in session[@"proxies"]) {
    if (![proxy isKindOfClass:NSDictionary.class] || !KuroProxy(proxy) || [names containsObject:proxy[@"name"]]) { Fail(error, @"unsupported inline Proxy or duplicate name"); return nil; }
    [names addObject:proxy[@"name"]];
  }
  NSSet *proxyTargets = [names copy];
  for (id group in session[@"groups"]) {
    if (!Keys(group, @[@"name", @"type", @"proxies"]) || !KuroProxyName(group[@"name"]) || [names containsObject:group[@"name"]] || ![group[@"type"] isEqual:@"select"] || !KuroArray(group[@"proxies"], 130, YES)) { Fail(error, @"unsupported Group or duplicate name"); return nil; }
    for (id member in group[@"proxies"]) if (![member isKindOfClass:NSString.class] || ![proxyTargets containsObject:member]) { Fail(error, @"Group reference is not an inline Proxy or built-in"); return nil; }
    [names addObject:group[@"name"]];
  }
  NSArray *rules = session[@"rules"];
  for (NSUInteger i = 0; i < rules.count; i++) {
    if (![rules[i] isKindOfClass:NSDictionary.class] || !KuroRule(rules[i], names) || ([rules[i][@"type"] isEqual:@"MATCH"] != (i + 1 == rules.count))) { Fail(error, @"unsupported Rule or missing explicit final MATCH"); return nil; }
  }
  id dns = session[@"dns"];
  if (!Keys(dns, @[@"nameservers", @"bootstrap", @"proxyNameservers", @"policies"]) || !KuroResolvers(dns[@"nameservers"]) || !KuroResolvers(dns[@"bootstrap"]) || !KuroResolvers(dns[@"proxyNameservers"]) || !KuroArray(dns[@"policies"], 128, NO)) { Fail(error, @"only explicit unicast literal DNS over UDP53 is supported"); return nil; }
  NSMutableSet *policies = [NSMutableSet set];
  for (id policy in dns[@"policies"]) {
    if (!Keys(policy, @[@"domain", @"nameservers"]) || !KuroText(policy[@"domain"], 253) || !KuroResolvers(policy[@"nameservers"])) { Fail(error, @"unsupported DNS policy"); return nil; }
    NSString *pattern = policy[@"domain"], *domain = [pattern hasPrefix:@"+."] ? [pattern substringFromIndex:2] : pattern;
    if (!KuroDomain(domain) || [policies containsObject:pattern.lowercaseString]) { Fail(error, @"invalid or duplicate DNS policy domain"); return nil; } [policies addObject:pattern.lowercaseString];
  }
  return session;
}
static NSData *KuroTunRuntimeJSON(NSData *data, NSString **error) {
  NSDictionary *session = KuroValidateTunConfig(data, error); if (!session) return nil;
  NSMutableArray *rules = [NSMutableArray array];
  for (NSDictionary *rule in session[@"rules"]) {
    NSMutableArray *parts = [NSMutableArray arrayWithObject:rule[@"type"]]; if (![rule[@"type"] isEqual:@"MATCH"]) [parts addObject:rule[@"value"]]; [parts addObject:rule[@"target"]]; if ([rule[@"noResolve"] boolValue]) [parts addObject:@"no-resolve"]; [rules addObject:[parts componentsJoinedByString:@","]];
  }
  NSMutableDictionary *policies = [NSMutableDictionary dictionary]; for (NSDictionary *policy in session[@"dns"][@"policies"]) policies[policy[@"domain"]] = policy[@"nameservers"];
  NSDictionary *runtime = @{@"mode":session[@"mode"], @"ipv6":@YES, @"allow-lan":@NO, @"bind-address":@"127.0.0.1", @"log-level":@"info", @"mixed-port":@0, @"port":@0, @"socks-port":@0, @"redir-port":@0, @"tproxy-port":@0, @"find-process-mode":@"off", @"geo-auto-update":@NO, @"profile":@{@"store-selected":@NO,@"store-fake-ip":@NO}, @"proxies":session[@"proxies"], @"proxy-groups":session[@"groups"], @"rules":rules,
    @"dns":@{@"enable":@YES,@"ipv6":@YES,@"enhanced-mode":@"redir-host",@"listen":@"",@"use-hosts":@YES,@"use-system-hosts":@YES,@"nameserver":session[@"dns"][@"nameservers"],@"default-nameserver":session[@"dns"][@"bootstrap"],@"proxy-server-nameserver":session[@"dns"][@"proxyNameservers"],@"nameserver-policy":policies,@"proxy-server-nameserver-policy":@{},@"direct-nameserver":@[],@"direct-nameserver-follow-policy":@NO,@"fallback":@[],@"fallback-filter":@{@"geoip":@NO},@"respect-rules":@NO,@"fake-ip-range":@"198.18.0.1/16",@"fake-ip-range6":@""},
    @"tun":@{@"enable":@YES,@"stack":@"mips",@"mtu":@1500,@"auto-route":@NO,@"auto-detect-interface":@YES,@"strict-route":@NO,@"dns-mode":@"disabled",@"dns-hijack":@[],@"inet6-address":@[@"fdfe:dcba:9876::1/126"]}};
  // The locked Core uses a YAML reader that rejects JSON escaped slashes (\/).
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:runtime options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:NULL];
  NSString *text = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
  // YAML treats literal NEL/line/paragraph separators as line breaks. Escape them
  // so credentials/names retain their exact JSON string value at the Core reader.
  for (NSNumber *code in @[@0x85, @0x2028, @0x2029]) {
    text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C", (unichar)code.unsignedIntValue] withString:[NSString stringWithFormat:@"\\u%04x", code.unsignedIntValue]];
  }
  return [text dataUsingEncoding:NSUTF8StringEncoding];
}
