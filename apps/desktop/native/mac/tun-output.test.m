#define KURO_TESTING 1
#ifndef KURO_OUTPUT_HELPER_SOURCE
#define KURO_OUTPUT_HELPER_SOURCE "kuro-tun-helper.m"
#endif
#import KURO_OUTPUT_HELPER_SOURCE
#ifndef KURO_TUN_OUTPUT_INCLUDED
#import "tun-output.m"
#endif
#include <spawn.h>
static NSUInteger checks=0;
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static NSData *D(NSString *text){return [text dataUsingEncoding:NSUTF8StringEncoding];}
static NSString *T(NSData *data){return [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];}
static NSString *Redact(NSString *text,NSArray *secrets){return T(KuroOutputRedact(D(text),KuroOutputNeedles(secrets)));}
static NSString *Directory(void){char path[]="/private/tmp/kuro-output-test-XXXXXX";CHECK(mkdtemp(path)!=NULL);CHECK(chmod(path,0700)==0);return @(path);}
static void WriteAll(int fd,const void *bytes,size_t size){while(size){ssize_t n=write(fd,bytes,size);if(n<0&&errno==EINTR)continue;if(n<=0)_exit(71);bytes=(const char *)bytes+n;size-=(size_t)n;}}
static int Child(void){@autoreleasepool{
  const char *secret="raw-password";WriteAll(1,secret,5);WriteAll(1,secret+5,strlen(secret)-5);WriteAll(2,secret,strlen(secret));
  char block[4096];memset(block,'x',sizeof(block));for(int i=0;i<64;i++){WriteAll(1,block,sizeof(block));WriteAll(2,block,sizeof(block));}return 37;
}}
static int Spawn(NSString *self,KuroCoreOutput *output){
  posix_spawn_file_actions_t actions;CHECK(posix_spawn_file_actions_init(&actions)==0);
  CHECK(posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0)==0);
  CHECK(posix_spawn_file_actions_adddup2(&actions,[output writer:0],1)==0);CHECK(posix_spawn_file_actions_adddup2(&actions,[output writer:1],2)==0);
  char *args[]={(char *)self.fileSystemRepresentation,"--fixture-output",NULL};char *env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};pid_t child=0;
  CHECK(posix_spawn(&child,self.fileSystemRepresentation,&actions,NULL,args,env)==0);CHECK(posix_spawn_file_actions_destroy(&actions)==0);[output closeWriters];
  int status=0;uint64_t until=KuroMonotonicMilliseconds()+5000;
  for(;;){pid_t value=waitpid(child,&status,WNOHANG);if(value==child)break;if(!(value==0||(value<0&&errno==EINTR)))CHECK(NO);if(KuroMonotonicMilliseconds()>=until)CHECK(NO);usleep(1000);}
  CHECK(WIFEXITED(status));return WEXITSTATUS(status);
}
int main(int argc,const char **argv){@autoreleasepool{
  CHECK(geteuid()!=0);alarm(15);
  if(argc==2&&!strcmp(argv[1],"--fixture-output"))return Child();
  NSDictionary *mapping=@{@"secret":@"REDACTED",@"proxies":@[@{@"type":@"ss",@"password":@"pass"},@{@"type":@"http",@"username":@"user",@"password":@"word"}],@"rules":@[@"MATCH,DIRECT"]};
  NSData *original=JSONData(mapping);NSArray *secrets=KuroDiagnosticSecrets(mapping);CHECK(secrets.count==4);
  NSDictionary *redacted=KuroDiagnosticRuntime(mapping);CHECK([redacted[@"secret"]isEqual:@"[REDACTED]"]);CHECK([redacted[@"proxies"][1][@"username"]isEqual:@"[REDACTED]"]);CHECK([redacted[@"rules"]isEqual:mapping[@"rules"]]);CHECK([original isEqual:JSONData(mapping)]);
  CHECK(KuroDiagnosticRuntime(@{@"secret":@"a",@"proxies":@[@{@"type":@"vmess",@"uuid":@"x"}]})==nil);
  CHECK(KuroDiagnosticRuntime(@{@"secret":@"a",@"proxies":@[@{@"type":@"ss",@"password":@1}]})==nil);
  CHECK([Redact(@"REDACTED and [",@[@"REDACTED",@"["])isEqual:@"[REDACTED] and [REDACTED]"]);
  CHECK([Redact(@"abcde",@[@"abc",@"cde"])isEqual:@"[REDACTED]"]);CHECK([Redact(@"swordf",@[@"swordfish"])isEqual:@"[REDACTED]"]);
  NSString *unicode=@"密钥\"\\/\n\u2028";NSArray *needles=KuroOutputNeedles(@[unicode]);CHECK(needles.count>=2);
  for(NSData *needle in needles)CHECK([T(KuroOutputRedact(needle,needles))isEqual:@"[REDACTED]"]);
  CHECK([Redact(@"prefix 密钥 suffix",@[@"密钥"])isEqual:@"prefix [REDACTED] suffix"]);
  NSString *text=KuroDiagnosticText(@"secret [ and \" token",@[@"["]);CHECK(text!=nil);CHECK([NSJSONSerialization JSONObjectWithData:JSONData(@{@"error":text}) options:0 error:NULL]!=nil);
  CHECK(KuroDiagnosticText(@"anything",@[])==nil);
  NSMutableString *longText=[NSMutableString string];for(int i=0;i<30000;i++)[longText appendString:@"密"];
  CHECK([KuroDiagnosticText(longText,@[@"other"])dataUsingEncoding:NSUTF8StringEncoding].length<=65536);
  NSMutableData *edge=[NSMutableData dataWithLength:65530];memset(edge.mutableBytes,'x',edge.length);[edge appendData:D(@"raw-password")];
  NSData *clipped=KuroOutputRedact(edge,KuroOutputNeedles(@[@"raw-password"]));CHECK(clipped.length<=65536);CHECK([clipped rangeOfData:D(@"raw-pa") options:0 range:NSMakeRange(0,clipped.length)].location==NSNotFound);
  CHECK([[KuroCoreOutput alloc]initWithSecrets:@[]]==nil);
  NSString *directory=Directory();KuroCoreOutput *output=[[KuroCoreOutput alloc]initWithSecrets:@[@"raw-password"]];CHECK(output!=nil);CHECK([output writer:0]>=4&&[output writer:1]>=4&&[output writer:0]!=[output writer:1]);CHECK([output writer:2]==-1);
  NSString *self=[[NSProcessInfo processInfo]arguments][0];int exitCode=Spawn(self,output);CHECK(exitCode==37);
  NSString *error=nil;CHECK(chmod(directory.fileSystemRepresentation,0755)==0);CHECK(![output finishTo:directory error:&error]);CHECK(exitCode==37);CHECK(error!=nil);CHECK(chmod(directory.fileSystemRepresentation,0700)==0);error=nil;CHECK([output finishTo:directory error:&error]);
  NSDictionary *stats=[output statistics];for(NSString *name in @[@"stdout",@"stderr"]){CHECK([stats[name][@"bytesRead"]unsignedLongLongValue]>262144);CHECK([stats[name][@"retainedBytes"]unsignedIntegerValue]<=65536);CHECK([stats[name][@"truncated"]boolValue]);CHECK([stats[name][@"eof"]boolValue]);CHECK([stats[name][@"readErrno"]intValue]==0);NSData *log=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".log"]]];CHECK(log.length<=65536);CHECK([log rangeOfData:D(@"raw-password") options:0 range:NSMakeRange(0,log.length)].location==NSNotFound);CHECK([log rangeOfData:D(@"[REDACTED]") options:0 range:NSMakeRange(0,log.length)].location!=NSNotFound);}
  CHECK([output finishTo:directory error:&error]);CHECK(![output checkpointTo:Directory() error:&error]);
  NSString *stdoutPath=[directory stringByAppendingPathComponent:@"stdout.log"];CHECK([D(@"external")writeToFile:stdoutPath atomically:NO]);CHECK(![output checkpointTo:directory error:&error]);CHECK([[NSData dataWithContentsOfFile:stdoutPath]isEqual:D(@"external")]);
  NSString *foreign=Directory();CHECK([D(@"foreign")writeToFile:[foreign stringByAppendingPathComponent:@"stdout.log"] atomically:NO]);CHECK(chmod([[foreign stringByAppendingPathComponent:@"stdout.log"]fileSystemRepresentation],0600)==0);
  KuroCoreOutput *empty=[[KuroCoreOutput alloc]initWithSecrets:@[@"test"]];CHECK(![empty finishTo:foreign error:&error]);CHECK([[NSData dataWithContentsOfFile:[foreign stringByAppendingPathComponent:@"stdout.log"]]isEqual:D(@"foreign")]);
  NSString *links=Directory();CHECK(symlink(stdoutPath.fileSystemRepresentation,[[links stringByAppendingPathComponent:@"stdout.log"]fileSystemRepresentation])==0);KuroCoreOutput *symlinked=[[KuroCoreOutput alloc]initWithSecrets:@[@"test"]];CHECK(![symlinked finishTo:links error:&error]);
  NSString *hard=Directory();CHECK(link(stdoutPath.fileSystemRepresentation,[[hard stringByAppendingPathComponent:@"stdout.log"]fileSystemRepresentation])==0);KuroCoreOutput *hardlinked=[[KuroCoreOutput alloc]initWithSecrets:@[@"test"]];CHECK(![hardlinked finishTo:hard error:&error]);
  NSString *updates=Directory();KuroCoreOutput *updating=[[KuroCoreOutput alloc]initWithSecrets:@[@"swordfish"]];WriteAll([updating writer:0],"sword",5);
  BOOL observed=NO;uint64_t deadline=KuroMonotonicMilliseconds()+1000;
  while(KuroMonotonicMilliseconds()<deadline){if(![updating checkpointTo:updates error:&error])CHECK(NO);NSData *snapshot=[NSData dataWithContentsOfFile:[updates stringByAppendingPathComponent:@"stdout.log"]];if(snapshot.length){CHECK([T(snapshot)isEqual:@"[REDACTED]"]);observed=YES;break;}usleep(1000);}
  CHECK(observed);WriteAll([updating writer:0],"fish done",9);CHECK([updating finishTo:updates error:&error]);CHECK([[NSData dataWithContentsOfFile:[updates stringByAppendingPathComponent:@"stdout.log"]]isEqual:D(@"[REDACTED] done")]);
  NSString *incompleteDir=Directory();KuroCoreOutput *incomplete=[[KuroCoreOutput alloc]initWithSecrets:@[@"test"]];int held=dup([incomplete writer:1]);CHECK(held>=0);CHECK(![incomplete finishTo:incompleteDir error:&error]);CHECK(![[incomplete statistics][@"stderr"][@"eof"]boolValue]);CHECK(close(held)==0);CHECK(![incomplete finishTo:incompleteDir error:&error]);
  fprintf(stdout,"PASS %lu assertions; harmless self-child exit37; no Core/network; evidence %s\n",(unsigned long)checks,directory.fileSystemRepresentation);return 0;
}}
