#define main KuroUnusedSuiteMain
#import "baseline-native/kuro-tun-helper.test.m"
#undef main
int main(void){@autoreleasepool{
 CHECK(geteuid()!=0);alarm(20);
 char temporary[]="/tmp/kuro-group-repro-XXXXXX";CHECK(mkdtemp(temporary));char canonical[PATH_MAX];CHECK(realpath(temporary,canonical));
 NSString *directory=@(canonical),*work=[directory stringByAppendingPathComponent:@"session-work"],*journal=[directory stringByAppendingPathComponent:@"owner.json"],*error=nil;
 Put([work stringByAppendingPathComponent:@"config.json"],Bytes(@"runtime config"),0600);Put([work stringByAppendingPathComponent:@"cache.db"],Bytes(@"fixture bbolt cache"),0600);
 NSMutableDictionary *record=RestartRecord();record[@"format"]=@2;record[@"processGroup"]=@(getpgrp());
 record[@"work"]=@{@"configSHA256":Hash(Bytes(@"runtime config")),@"socket":NSNull.null,@"cache":KuroWorkCacheSnapshot(directory,geteuid(),&error)};Put(journal,JSONData(record),0600);
 pid_t members[64]={0};int count=proc_listpids(PROC_PGRP_ONLY,(uint32_t)getpgrp(),members,sizeof(members));CHECK(count>0);BOOL selfPresent=NO;for(int i=0;i<count/(int)sizeof(pid_t);i++)if(members[i]==getpid())selfPresent=YES;CHECK(selfPresent);
 KuroTunService *service=[[KuroTunService alloc]initFixtureDirectory:directory core:[directory stringByAppendingPathComponent:@"unused"] hooks:ServiceHooks()];
 KuroOwnedSession *observed=[[KuroOwnedSession alloc]initWithDirectory:directory owner:geteuid()];observed.fixtureRestartReader=RestartReader;RestartMode=0;RestartReappearAt=0;
 BOOL accepted=[observed recoverExitedOwnerWithNetwork:^BOOL(NSString **failure){(void)failure;return YES;} workCleanup:^BOOL(NSDictionary *owner,KuroSessionHook absent,NSString **failure){return [service recoverExitedWork:owner stillAbsent:absent error:failure];} error:&error];
 CHECK(accepted&&!Exists(work)&&!Exists(journal));puts("BASELINE REPRO: ESRCH recorded Core + observed nonempty old group accepted and removed exact final-cache work");
 CHECK([[NSFileManager defaultManager]removeItemAtPath:directory error:NULL]);return 0;
}}
