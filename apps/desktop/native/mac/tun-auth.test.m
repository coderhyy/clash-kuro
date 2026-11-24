static int AuthFixtureMain(int argc,const char **argv) {
  if(argc!=3 || strcmp(argv[1],"--auth-fixture"))return -1;
  if(geteuid()==0)return 91;
  int peer=socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un address={.sun_family=AF_UNIX};
  if(peer<0 || strlcpy(address.sun_path,argv[2],sizeof(address.sun_path))>=sizeof(address.sun_path) || connect(peer,(struct sockaddr *)&address,sizeof(address)))return 92;
  char ready='R'; if(send(peer,&ready,1,0)!=1)return 93;
  struct pollfd wait={.fd=peer,.events=POLLIN}; char result;
  if(poll(&wait,1,5000)<=0 || recv(peer,&result,1,0)!=1)return 94;
  close(peer); return 0;
}
static void AuthTests(void) {
  char pattern[]="/tmp/kuro-auth-policy-XXXXXX",canonical[PATH_MAX]; CHECK(mkdtemp(pattern)&&realpath(pattern,canonical));
  NSString *prefix=@(canonical), *bundle=At(prefix,ClientBundle), *error=nil;
  NSString *main=[bundle stringByAppendingPathComponent:ClientExecutable];
  Put(main,[NSData dataWithContentsOfFile:Executable()],0755);
  NSDictionary *plist=@{@"CFBundleIdentifier":@"dev.kuro.desktop",@"CFBundleExecutable":@"Clash Kuro",@"CFBundlePackageType":@"APPL",@"CFBundleVersion":@"1"};
  Put([bundle stringByAppendingPathComponent:@"Contents/Info.plist"],[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL],0644);
  Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"inert native fixture"),0644);
  char *sign[]={"/usr/bin/codesign","--force","--sign","-","--options","runtime",(char *)bundle.fileSystemRepresentation,NULL};
  char *env[]={"PATH=/usr/bin:/bin","LANG=C",NULL}; pid_t signer; int exitStatus;
  CHECK(!posix_spawn(&signer,sign[0],NULL,NULL,sign,env)); CHECK(waitpid(signer,&exitStatus,0)==signer&&WIFEXITED(exitStatus)&&!WEXITSTATUS(exitStatus));
  NSDictionary *pin=KuroClientSnapshot(prefix,bundle,geteuid(),&error); CHECK(pin);
  NSString *record=At(prefix,[State stringByAppendingPathComponent:@"client.json"]); Put(record,JSONData(pin),0600);
  NSString *socketPath=[prefix stringByAppendingPathComponent:@"auth.sock"];
  int listener=socket(AF_UNIX,SOCK_STREAM,0); struct sockaddr_un address={.sun_family=AF_UNIX}; strlcpy(address.sun_path,socketPath.UTF8String,sizeof(address.sun_path));
  CHECK(listener>=0&&!bind(listener,(struct sockaddr *)&address,sizeof(address))&&!listen(listener,1));
  char *args[]={(char *)main.fileSystemRepresentation,"--auth-fixture",(char *)socketPath.fileSystemRepresentation,NULL}; pid_t child;
  CHECK(!posix_spawn(&child,args[0],NULL,NULL,args,env));
  struct pollfd incoming={.fd=listener,.events=POLLIN}; CHECK(poll(&incoming,1,5000)>0);
  int peer=accept(listener,NULL,NULL); CHECK(peer>=0); char ready; CHECK(recv(peer,&ready,1,0)==1);
  NSData *request=Bytes(@"{\"version\":1,\"operation\":\"authenticate\"}\n");
  NSDictionary *accepted=AuthenticateRequestAt(request,peer,prefix,geteuid());
  if(![accepted[@"ok"] boolValue])fprintf(stderr,"auth positive fixture: %s\n",accepted.description.UTF8String);
  CHECK(([accepted isEqual:@{@"version":@1,@"ok":@YES,@"authenticated":@YES}]));
  for(NSString *operation in @[@"open",@"start",@"stop",@"recover",@"exec",@"status"])
    CHECK(![AuthenticateRequestAt(Bytes([NSString stringWithFormat:@"{\"version\":1,\"operation\":\"%@\"}",operation]),peer,prefix,geteuid())[@"ok"] boolValue]);
  CHECK(![AuthenticateRequestAt(Bytes(@"{\"version\":1,\"version\":1,\"operation\":\"authenticate\"}"),peer,prefix,geteuid())[@"ok"] boolValue]);
  NSMutableDictionary *wrong=[pin mutableCopy]; wrong[@"cdhash"]=[@"0" stringByPaddingToLength:40 withString:@"0" startingAtIndex:0];
  Put(record,JSONData(wrong),0600); CHECK(![AuthenticateRequestAt(request,peer,prefix,geteuid())[@"ok"] boolValue]); Put(record,JSONData(pin),0600);
  Put([bundle stringByAppendingPathComponent:@"Contents/Resources/app.asar"],Bytes(@"modified resource"),0644);
  CHECK(![AuthenticateRequestAt(request,peer,prefix,geteuid())[@"ok"] boolValue]);
  int impostor[2]; CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,impostor)); CHECK(![AuthenticateRequestAt(request,impostor[0],prefix,geteuid())[@"ok"] boolValue]); close(impostor[0]);close(impostor[1]);
  CHECK(send(peer,"X",1,0)==1); close(peer);close(listener);
  CHECK(waitpid(child,&exitStatus,0)==child&&WIFEXITED(exitStatus)&&!WEXITSTATUS(exitStatus));
  CHECK([[NSFileManager defaultManager] removeItemAtPath:prefix error:NULL]);
  puts("native auth: shared production policy accepts real signed live fixture, rejects impostor/pin/resource changes and every non-observation operation; no root/Core/network");
}
