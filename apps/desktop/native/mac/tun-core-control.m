// Root-internal typed Unix control. No RPC accepts an HTTP method or path.
static NSString *KuroPathComponent(NSString *name) {
  NSData *bytes=[name dataUsingEncoding:NSUTF8StringEncoding]; NSMutableString *encoded=[NSMutableString string];
  const unsigned char *input=bytes.bytes;
  for(NSUInteger i=0;i<bytes.length;i++) {
    unsigned char c=input[i];
    if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~') [encoded appendFormat:@"%c",c];
    else [encoded appendFormat:@"%%%02X",c];
  }
  return encoded;
}
static BOOL KuroCoreWaitFD(int fd,short events,uint64_t deadline,NSString **error) {
  while(KuroMonotonicMilliseconds()<deadline) {
    struct pollfd value={.fd=fd,.events=events};
    uint64_t now=KuroMonotonicMilliseconds(); int remaining=now<deadline ? (int)(deadline-now) : 0;
    int count=poll(&value,1,MAX(remaining,0));
    if(count<0&&errno==EINTR)continue;
    if(count>0 && (value.revents&events))return YES;
    break;
  }
  return Fail(error,@"private Core request timed out or disconnected");
}
static id KuroCoreControlRequest(NSString *socketPath,NSString *secret,NSArray *groups,KuroSessionHook verify,NSDictionary *command,NSString **error) {
  NSString *method=nil,*path=nil; NSDictionary *body=nil;
  if(Keys(command,@[@"operation"]) && [command[@"operation"] isEqual:@"version"]) { method=@"GET"; path=@"/version"; }
  else if(Keys(command,@[@"operation"]) && [command[@"operation"]isEqual:@"readMode"]) { method=@"GET";path=@"/configs"; }
  else if(Keys(command,@[@"operation",@"group"]) && [command[@"operation"]isEqual:@"readSelection"] && KuroText(command[@"group"],128)) {
    BOOL allowed=NO;for(NSDictionary *group in groups)if([group[@"name"]isEqual:command[@"group"]])allowed=YES;
    if(!allowed) { Fail(error,@"selection group was not admitted");return nil; }
    method=@"GET";path=[@"/proxies/" stringByAppendingString:KuroPathComponent(command[@"group"])];
  }
  else if(Keys(command,@[@"operation",@"mode"]) && [command[@"operation"] isEqual:@"mode"] && [@[@"rule",@"global",@"direct"] containsObject:command[@"mode"]]) { method=@"PATCH"; path=@"/configs"; body=@{@"mode":command[@"mode"]}; }
  else if(Keys(command,@[@"operation",@"group",@"proxy"]) && [command[@"operation"] isEqual:@"select"] && KuroText(command[@"group"],128) && KuroText(command[@"proxy"],128)) {
    BOOL allowed=NO;
    for(NSDictionary *group in groups) if([group[@"name"] isEqual:command[@"group"]] && [group[@"proxies"] containsObject:command[@"proxy"]])allowed=YES;
    if(!allowed) { Fail(error,@"selection was not admitted by the session schema"); return nil; }
    method=@"PUT"; path=[@"/proxies/" stringByAppendingString:KuroPathComponent(command[@"group"])]; body=@{@"name":command[@"proxy"]};
  } else { Fail(error,@"unsupported typed Core control operation"); return nil; }
  if(!verify || !verify(error))return nil;
  NSData *payload=body ? JSONData(body) : [NSData data];
  NSString *header=[NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer %@\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: %lu\r\n\r\n",method,path,secret,(unsigned long)payload.length];
  NSMutableData *request=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [request appendData:payload];
  struct sockaddr_un address;
  if(!KuroUnixSocketAddress(socketPath,&address,error))return nil;
  int fd=socket(AF_UNIX,SOCK_STREAM,0);
  if(fd<0) { Fail(error,@"private Core socket unavailable"); return nil; }
  int flags=fcntl(fd,F_GETFL);
  if(flags<0 || fcntl(fd,F_SETFD,FD_CLOEXEC) || fcntl(fd,F_SETFL,flags|O_NONBLOCK)) { close(fd);Fail(error,@"private Core socket could not be made nonblocking");return nil; }
  uint64_t deadline=KuroMonotonicMilliseconds()+500;
  BOOL ok=connect(fd,(struct sockaddr *)&address,sizeof(address))==0;
  if(!ok&&errno==EINPROGRESS) {
    ok=KuroCoreWaitFD(fd,POLLOUT,deadline,error); int failure=0; socklen_t size=sizeof(failure);
    ok=ok && !getsockopt(fd,SOL_SOCKET,SO_ERROR,&failure,&size) && !failure;
  }
  NSUInteger offset=0;
  while(ok&&offset<request.length) {
    ssize_t count=send(fd,(const char *)request.bytes+offset,request.length-offset,MSG_NOSIGNAL);
    if(count<0&&(errno==EINTR||errno==EAGAIN)) { ok=KuroCoreWaitFD(fd,POLLOUT,deadline,error); continue; }
    if(count<=0) { ok=NO; break; } offset+=(NSUInteger)count;
  }
  NSMutableData *response=[NSMutableData data]; BOOL ended=NO;
  while(ok && response.length<=MessageLimit) {
    unsigned char bytes[4096]; ssize_t count=recv(fd,bytes,sizeof(bytes),0);
    if(count<0&&(errno==EINTR||errno==EAGAIN)) { ok=KuroCoreWaitFD(fd,POLLIN,deadline,error); continue; }
    if(count<0) { ok=NO; break; } if(!count) { ended=YES; break; }
    [response appendBytes:bytes length:(NSUInteger)count];
  }
  close(fd);
  if(!ok || !ended || response.length>MessageLimit) { Fail(error,@"private Core response is incomplete or oversized"); return nil; }
  NSData *delimiter=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]; NSRange range=[response rangeOfData:delimiter options:0 range:NSMakeRange(0,response.length)];
  if(range.location==NSNotFound || range.location>8192) { Fail(error,@"private Core response headers invalid"); return nil; }
  NSString *headers=[[NSString alloc] initWithData:[response subdataWithRange:NSMakeRange(0,range.location)] encoding:NSASCIIStringEncoding];
  NSArray *lines=[headers componentsSeparatedByString:@"\r\n"];
  if(!lines.count || !Match(lines[0],@"\\AHTTP/1\\.[01] (?:200|204)(?: [^\\r\\n]*)?\\z")) { Fail(error,@"private Core operation was not accepted"); return nil; }
  NSMutableDictionary *fields=[NSMutableDictionary dictionary];
  for(NSUInteger i=1;i<lines.count;i++) {
    NSRange separator=[lines[i] rangeOfString:@":"];
    if(separator.location==NSNotFound) { Fail(error,@"malformed private Core header"); return nil; }
    NSString *key=[[lines[i] substringToIndex:separator.location] lowercaseString];
    if(fields[key]) { Fail(error,@"duplicate private Core header"); return nil; }
    fields[key]=[[lines[i] substringFromIndex:separator.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  NSData *content=[response subdataWithRange:NSMakeRange(NSMaxRange(range),response.length-NSMaxRange(range))];
  BOOL noContent=[lines[0] hasPrefix:@"HTTP/1.1 204"] || [lines[0] hasPrefix:@"HTTP/1.0 204"];
  BOOL lengthOK=fields[@"content-length"] ? Match(fields[@"content-length"],@"\\A(?:0|[1-9][0-9]{0,5})\\z") && (unsigned long long)[fields[@"content-length"] longLongValue]==content.length : noContent && content.length==0;
  if(fields[@"transfer-encoding"] || !lengthOK || (noContent && content.length)) { Fail(error,@"private Core response must have one bounded content length"); return nil; }
  if([command[@"operation"] isEqual:@"version"]) {
    if(noContent) { Fail(error,@"version readiness requires a JSON response"); return nil; }
    id value=KuroDecodeJSON(content,MessageLimit,error);
    if(![value isKindOfClass:NSDictionary.class] || !KuroText(value[@"version"],128)) { Fail(error,@"Core version readiness response invalid"); return nil; }
    return value;
  }
  if([command[@"operation"]isEqual:@"readMode"] || [command[@"operation"]isEqual:@"readSelection"]) {
    id value=noContent?nil:KuroDecodeJSON(content,MessageLimit,error);
    if(![value isKindOfClass:NSDictionary.class]) { Fail(error,@"typed Core readback requires an object");return nil; }
    if([command[@"operation"]isEqual:@"readMode"]) {
      NSString *mode=value[@"mode"];if(![@[@"rule",@"global",@"direct"]containsObject:mode]) { Fail(error,@"invalid mode readback");return nil; }
      return @{@"mode":mode};
    }
    for(NSDictionary *group in groups)if([group[@"name"]isEqual:command[@"group"]]&&[group[@"proxies"]containsObject:value[@"now"]])return @{@"now":value[@"now"]};
    Fail(error,@"selection readback is outside admitted group");return nil;
  }
  if(!noContent) { Fail(error,@"typed Core writes require an empty 204 response"); return nil; }
  return @{};
}
