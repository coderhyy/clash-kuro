#ifdef KURO_LIFECYCLE_CORE
#import "lifecycle-core.m"
#else
// Experiment A only: no TUN, network, production IPC, installation or launchctl.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
static NSString *const Label = @"dev.kuro.tun.lifecycle-a";
static NSString *const Binary = @"/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a";
static NSString *const Directory = @"/Library/Application Support/Clash Kuro/TunLifecycleExperimentA";
static NSString *const Plist = @"/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist";
static NSString *Self(void) { char path[PATH_MAX], real[PATH_MAX]; uint32_t size=sizeof(path); return !_NSGetExecutablePath(path,&size) && realpath(path,real) ? [NSString stringWithUTF8String:real] : nil; }
static BOOL Epoch(NSString *text) { NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:text]; return uuid && [uuid.UUIDString isEqual:text]; }
static NSString *Digest(NSData *bytes) { unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest); NSMutableString *text=[NSMutableString string]; for (NSUInteger i=0;i<sizeof(digest);i++) [text appendFormat:@"%02x",digest[i]]; return text; }
static NSDictionary *Identity(pid_t pid) {
  struct proc_bsdinfo info={0}; char path[PROC_PIDPATHINFO_MAXSIZE]={0};
  if (proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info)) != sizeof(info)) return nil;
  if (proc_pidpath(pid,path,sizeof(path)) <= 0) { errno=EACCES; return nil; }
  return @{@"pid":@(pid),@"parent":@(info.pbi_ppid),@"group":@(info.pbi_pgid),@"startSeconds":@(info.pbi_start_tvsec),@"startMicros":@(info.pbi_start_tvusec),@"executable":[NSString stringWithUTF8String:path]};
}
static BOOL Same(NSDictionary *left, NSDictionary *right) {
  if(!left || !right)return NO;
  // Parent changes after supervisor death; start identity and inherited group do not.
  for(NSString *key in @[@"pid",@"group",@"startSeconds",@"startMicros",@"executable"])if(![left[key] isEqual:right[key]])return NO;
  return YES;
}
static BOOL Protected(NSString *path, BOOL directory) {
  struct stat info; return !lstat(path.fileSystemRepresentation,&info) && info.st_uid==0 && !(info.st_mode & 06022) && (directory ? S_ISDIR(info.st_mode) : S_ISREG(info.st_mode) && info.st_nlink==1);
}
static BOOL WriteExclusive(NSString *path, NSData *bytes) {
  int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600); if(fd<0)return NO;
  ssize_t count=write(fd,bytes.bytes,bytes.length); BOOL ok=count==(ssize_t)bytes.length && !fsync(fd); close(fd); return ok;
}
static uint64_t Milliseconds(void) { struct timespec value; clock_gettime(CLOCK_MONOTONIC,&value); return (uint64_t)value.tv_sec*1000+(uint64_t)value.tv_nsec/1000000; }
static BOOL StopMarked(NSString *directory, NSString *epoch, uid_t owner) {
  NSString *path=[directory stringByAppendingPathComponent:@"stop.json"];
  int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC); if(fd<0)return NO;
  struct stat before,after; char buffer[256];
  BOOL safe=!fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_uid==owner && before.st_nlink==1 && !(before.st_mode&06077) && before.st_size>0 && before.st_size<=(off_t)sizeof(buffer);
  ssize_t count=safe?read(fd,buffer,sizeof(buffer)):-1;
  safe=safe && count==before.st_size && !fstat(fd,&after) && before.st_ino==after.st_ino && before.st_size==after.st_size && before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec;
  close(fd); if(!safe)return NO;
  NSDictionary *marker=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:buffer length:(NSUInteger)count] options:0 error:NULL];
  return [marker isKindOfClass:NSDictionary.class] && marker.count==1 && [marker[@"epoch"] isEqual:epoch];
}
static int ChildLifetime(NSString *directory, NSString *epoch, uid_t owner, uint64_t duration) {
  uint64_t deadline=Milliseconds()+duration;
  for(;;) {
    if(StopMarked(directory,epoch,owner))return 0;
    if(Milliseconds()>=deadline)return 10;
    struct timespec pause={.tv_nsec=20000000}; nanosleep(&pause,NULL);
  }
}
static NSDictionary *ExpectedPlist(NSString *epoch) {
  return @{@"Label":Label,@"ProgramArguments":@[Binary,@"--supervisor",epoch],@"RunAtLoad":@NO,@"KeepAlive":@NO,@"AbandonProcessGroup":@NO};
}
static BOOL FixedInstallation(NSString *epoch) {
  if(geteuid()!=0 || ![Self() isEqual:Binary] || !Protected(Binary,NO) || !Protected(Directory,YES) || !Protected(Plist,NO))return NO;
  NSDictionary *plist=[NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:Plist] error:NULL];
  return [plist isEqual:ExpectedPlist(epoch)];
}
static int Supervisor(NSString *epoch) {
  if(!Epoch(epoch) || !FixedInstallation(epoch))return 2;
  NSString *record=[Directory stringByAppendingPathComponent:@"evidence.json"];
  // No overwrite, no daemonization, no setsid or process-group changes.
  struct stat existing; if(!lstat(record.fileSystemRepresentation,&existing) || errno!=ENOENT)return 3;
  pid_t child; char *argv[]={(char *)Binary.fileSystemRepresentation,"--child",(char *)epoch.UTF8String,NULL};
  char *env[]={"PATH=/usr/bin:/bin","LANG=C",NULL};
  if(posix_spawn(&child,argv[0],NULL,NULL,argv,env))return 4;
  NSDictionary *parent=Identity(getpid()),*descendant=Identity(child);
  NSData *binary=[NSData dataWithContentsOfFile:Binary]; struct stat info;
  BOOL owned=parent && descendant && [descendant[@"parent"] intValue]==getpid() && [descendant[@"group"] isEqual:parent[@"group"]] && binary && !lstat(Binary.fileSystemRepresentation,&info);
  NSDictionary *evidence=owned ? @{@"format":@1,@"label":Label,@"epoch":epoch,@"startedUptimeMilliseconds":@(Milliseconds()),@"childLifetimeSeconds":@300,@"binarySHA256":Digest(binary),@"device":@(info.st_dev),@"inode":@(info.st_ino),@"supervisor":parent,@"child":descendant} : nil;
  NSData *bytes=evidence ? [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL] : nil;
  if(!bytes || !WriteExclusive(record,bytes)) {
    // This remains our unreaped direct child; no recorded PID is used for cleanup.
    kill(child,SIGKILL); waitpid(child,NULL,0); return 5;
  }
  // SIGTERM intentionally uses the default disposition as SIGKILL does not allow
  // handler cleanup. launchd's group policy is the mechanism being measured.
  int status; while(waitpid(child,&status,0)<0)if(errno!=EINTR)return 6;
  return 0;
}
static NSString *Observe(NSDictionary *expected) {
  if(![expected isKindOfClass:NSDictionary.class] || ![expected[@"pid"] isKindOfClass:NSNumber.class])return @"unknown";
  pid_t pid=[expected[@"pid"] intValue]; if(pid<=1)return @"unknown";
  errno=0; NSDictionary *actual=Identity(pid); int saved=errno;
  if(actual)return Same(expected,actual)?@"same-instance-live":@"identity-mismatch-do-not-signal";
  return saved==ESRCH ? @"absent" : @"unknown";
}
static int Inspect(NSString *epoch) {
  if(!Epoch(epoch) || !Protected(Directory,YES))return 2;
  NSString *record=[Directory stringByAppendingPathComponent:@"evidence.json"]; if(!Protected(record,NO))return 3;
  NSData *bytes=[NSData dataWithContentsOfFile:record]; if(!bytes || bytes.length>16384)return 4;
  NSDictionary *evidence=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
  if(![evidence isKindOfClass:NSDictionary.class] || ![evidence[@"format"] isEqual:@1] || ![evidence[@"label"] isEqual:Label] || ![evidence[@"epoch"] isEqual:epoch])return 5;
  NSData *binary=[NSData dataWithContentsOfFile:Binary]; struct stat info;
  if(!Protected(Binary,NO) || !binary || ![Digest(binary) isEqual:evidence[@"binarySHA256"]] || lstat(Binary.fileSystemRepresentation,&info) || ![evidence[@"device"] isEqual:@(info.st_dev)] || ![evidence[@"inode"] isEqual:@(info.st_ino)])return 6;
  // Read-only observation. Job binding still must be checked with launchctl print.
  uint64_t now=Milliseconds();
  id started=evidence[@"startedUptimeMilliseconds"];
  id elapsed=[started isKindOfClass:NSNumber.class] && now>=[started unsignedLongLongValue] ? @(now-[started unsignedLongLongValue]) : NSNull.null;
  NSDictionary *result=@{@"epoch":epoch,@"elapsedMilliseconds":elapsed,@"supervisor":Observe(evidence[@"supervisor"]),@"child":Observe(evidence[@"child"])};
  NSData *output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL]; fwrite(output.bytes,1,output.length,stdout); puts(""); return 0;
}
static int SelfTest(void) {
  if(geteuid()==0)return 2;
  NSString *epoch=NSUUID.UUID.UUIDString; if(!Epoch(epoch) || Epoch(@"../../bad"))return 3;
  NSDictionary *before=Identity(getpid()); if(!Same(before,Identity(getpid())))return 4;
  NSMutableDictionary *altered=[before mutableCopy]; altered[@"startMicros"]=@([before[@"startMicros"] unsignedLongLongValue]+1); if(Same(before,altered))return 5;
  NSString *pid=[NSString stringWithFormat:@"%d",getpid()],*group=[NSString stringWithFormat:@"%d",getpgrp()];
  char *argv[]={(char *)Self().fileSystemRepresentation,"--self-test-child",(char *)pid.UTF8String,(char *)group.UTF8String,NULL};
  char *env[]={"PATH=/usr/bin:/bin","LANG=C",NULL}; pid_t child;
  if(posix_spawn(&child,argv[0],NULL,NULL,argv,env))return 6;
  int status=0; if(waitpid(child,&status,0)!=child || !WIFEXITED(status) || WEXITSTATUS(status))return 8;
  if(![[ExpectedPlist(epoch) objectForKey:@"AbandonProcessGroup"] isEqual:@NO])return 9;
  char directory[]="/tmp/kuro-lifecycle-selftest-XXXXXX"; if(!mkdtemp(directory))return 10;
  NSString *base=[NSString stringWithUTF8String:directory],*marker=[base stringByAppendingPathComponent:@"stop.json"];
  NSData *wrong=[NSJSONSerialization dataWithJSONObject:@{@"epoch":NSUUID.UUID.UUIDString} options:0 error:NULL];
  if(!WriteExclusive(marker,wrong))return 11;
  child=fork(); if(child<0)return 12;
  if(!child)_exit(ChildLifetime(base,epoch,geteuid(),500));
  struct timespec pause={.tv_nsec=80000000}; nanosleep(&pause,NULL);
  if(waitpid(child,&status,WNOHANG)!=0)return 13; // Wrong epoch did not stop it.
  if(unlink(marker.fileSystemRepresentation))return 14;
  NSData *correct=[NSJSONSerialization dataWithJSONObject:@{@"epoch":epoch} options:0 error:NULL];
  if(!WriteExclusive(marker,correct) || waitpid(child,&status,0)!=child || !WIFEXITED(status) || WEXITSTATUS(status)!=0)return 15;
  if(unlink(marker.fileSystemRepresentation))return 16;
  uint64_t began=Milliseconds(); child=fork(); if(child<0)return 17;
  if(!child)_exit(ChildLifetime(base,epoch,geteuid(),120));
  if(waitpid(child,&status,0)!=child || !WIFEXITED(status) || WEXITSTATUS(status)!=10 || Milliseconds()-began<120)return 18;
  if(![[NSFileManager defaultManager] removeItemAtPath:base error:NULL])return 19;
  puts("PASS ordinary-user identity, inherited pgroup, wrong-epoch ignored, exact-epoch self-stop and monotonic TTL self-exit; no launchd behavior tested"); return 0;
}
int main(int argc,const char **argv) {
  @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"--self-test"))return SelfTest();
    if(argc==4 && !strcmp(argv[1],"--self-test-child") && geteuid()!=0)return getppid()==atoi(argv[2]) && getpgrp()==atoi(argv[3]) ? 0 : 1;
    if(argc!=3)return 1; NSString *epoch=[NSString stringWithUTF8String:argv[2]];
    if(!Epoch(epoch))return 1;
    if(!strcmp(argv[1],"--inspect"))return Inspect(epoch);
    if(!strcmp(argv[1],"--supervisor"))return Supervisor(epoch);
    if(!strcmp(argv[1],"--child") && geteuid()==0 && [Self() isEqual:Binary] && Protected(Directory,YES)) {
      int reason=ChildLifetime(Directory,epoch,0,300000);
      NSData *receipt=[NSJSONSerialization dataWithJSONObject:@{@"epoch":epoch,@"reason":reason==0?@"stop-marker":@"deadline",@"uptimeMilliseconds":@(Milliseconds())} options:0 error:NULL];
      (void)WriteExclusive([Directory stringByAppendingPathComponent:@"child-exit.json"],receipt);
      return 0;
    }
    return 1;
  }
}

#endif
