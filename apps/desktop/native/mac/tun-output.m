#ifndef KURO_TUN_OUTPUT_INCLUDED
#define KURO_TUN_OUTPUT_INCLUDED 1
// Internal capture extracted from ExperimentOutput. Include after helper file
// primitives (SafeNode/ReadProtected/WriteNew/Exists) and tun-session's clock.
// The caller creates a canonical owner-only diagnostics directory; this module
// neither chooses a path nor decides Core/network/off or installation ownership.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
static const NSUInteger KuroOutputLimit=65536;
static BOOL KuroOutputFail(NSString **error,NSString *message) {if(error)*error=message;return NO;}

// Only the validated four-proxy runtime schema is supported, not arbitrary YAML.
static NSArray<NSString *> *KuroDiagnosticSecrets(NSDictionary *mapping) {
  if(![mapping isKindOfClass:NSDictionary.class]||![mapping[@"secret"]isKindOfClass:NSString.class]||![mapping[@"secret"]length]||![mapping[@"proxies"]isKindOfClass:NSArray.class]||[mapping[@"proxies"]count]>128)return nil;
  NSMutableOrderedSet *values=[NSMutableOrderedSet orderedSetWithObject:mapping[@"secret"]];
  for(id proxy in mapping[@"proxies"]) {
    if(![proxy isKindOfClass:NSDictionary.class]||![@[@"ss",@"trojan",@"socks5",@"http"]containsObject:proxy[@"type"]])return nil;
    for(NSString *key in @[@"username",@"password"])if(proxy[key]) {
      if(![proxy[key]isKindOfClass:NSString.class]||![proxy[key]length])return nil;
      [values addObject:proxy[key]];
    }
  }
  return values.array;
}
static NSDictionary *KuroDiagnosticRuntime(NSDictionary *mapping) {
  if(!KuroDiagnosticSecrets(mapping))return nil;
  NSMutableDictionary *redacted=[mapping mutableCopy];redacted[@"secret"]=@"[REDACTED]";
  NSMutableArray *proxies=[NSMutableArray array];
  for(NSDictionary *proxy in mapping[@"proxies"]) {
    NSMutableDictionary *copy=[proxy mutableCopy];
    for(NSString *key in @[@"username",@"password"])if(copy[key])copy[key]=@"[REDACTED]";
    [proxies addObject:[copy copy]];
  }
  redacted[@"proxies"]=[proxies copy];return [redacted copy];
}
static NSArray<NSData *> *KuroOutputNeedles(NSArray<NSString *> *secrets) {
  if(![secrets isKindOfClass:NSArray.class]||!secrets.count||secrets.count>257)return nil;
  NSMutableOrderedSet *needles=[NSMutableOrderedSet orderedSet];NSUInteger total=0;
  for(id secret in secrets) {
    if(![secret isKindOfClass:NSString.class])return nil;
    NSData *raw=[secret dataUsingEncoding:NSUTF8StringEncoding];
    if(!raw.length||raw.length>4096||(total+=raw.length)>65536)return nil;
    [needles addObject:raw];
    for(NSNumber *options in @[@(NSJSONWritingWithoutEscapingSlashes),@0]) {
      NSData *wrapped=[NSJSONSerialization dataWithJSONObject:@[secret] options:options.unsignedIntegerValue error:NULL];
      if(wrapped.length<4)return nil;
      NSData *fragment=[wrapped subdataWithRange:NSMakeRange(2,wrapped.length-4)];[needles addObject:fragment];
      NSString *text=[[NSString alloc]initWithData:fragment encoding:NSUTF8StringEncoding];
      // Match the runtime serializer's YAML-safe NEL/line/paragraph escaping.
      for(NSNumber *code in @[@0x85,@0x2028,@0x2029])text=[text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"%C",(unichar)code.unsignedIntValue] withString:[NSString stringWithFormat:@"\\u%04x",code.unsignedIntValue]];
      [needles addObject:[text dataUsingEncoding:NSUTF8StringEncoding]];
    }
  }
  return needles.array;
}
static void KuroOutputAppend(NSMutableData *result,const void *bytes,NSUInteger length) {
  NSUInteger count=MIN(length,KuroOutputLimit-result.length);if(count)[result appendBytes:bytes length:count];
}
static NSData *KuroOutputRedact(NSData *raw,NSArray<NSData *> *needles) {
  // Mark only original byte ranges, including overlaps. Never search generated
  // replacement text (a password can itself be REDACTED or a single '[').
  NSMutableIndexSet *hidden=[NSMutableIndexSet indexSet];
  for(NSData *needle in needles) {
    NSUInteger offset=0;
    while(offset<raw.length) {
      NSRange found=[raw rangeOfData:needle options:0 range:NSMakeRange(offset,raw.length-offset)];
      if(found.location==NSNotFound)break;[hidden addIndexesInRange:found];offset=found.location+1;
    }
    for(NSUInteger count=MIN(needle.length-1,raw.length);count>0;count--) {
      if(!memcmp((const unsigned char *)raw.bytes+raw.length-count,needle.bytes,count)) {[hidden addIndexesInRange:NSMakeRange(raw.length-count,count)];break;}
    }
  }
  NSMutableData *result=[NSMutableData data];NSData *marker=[@"[REDACTED]"dataUsingEncoding:NSUTF8StringEncoding];__block NSUInteger copied=0;
  [hidden enumerateRangesUsingBlock:^(NSRange range,BOOL *stop) {
    KuroOutputAppend(result,(const unsigned char *)raw.bytes+copied,range.location-copied);
    KuroOutputAppend(result,marker.bytes,marker.length);copied=NSMaxRange(range);if(result.length==KuroOutputLimit)*stop=YES;
  }];
  if(result.length<KuroOutputLimit)KuroOutputAppend(result,(const unsigned char *)raw.bytes+copied,raw.length-copied);
  return result;
}
// Redact string values before JSON serialization, never JSON structure itself.
static NSString *KuroDiagnosticText(NSString *text,NSArray<NSString *> *secrets) {
  if(![text isKindOfClass:NSString.class])return nil;
  NSArray *needles=KuroOutputNeedles(secrets);if(!needles)return nil;
  NSData *bytes=KuroOutputRedact([text dataUsingEncoding:NSUTF8StringEncoding],needles);
  for(NSUInteger trim=0;trim<=MIN((NSUInteger)3,bytes.length);trim++) {
    NSString *value=[[NSString alloc]initWithBytes:bytes.bytes length:bytes.length-trim encoding:NSUTF8StringEncoding];if(value)return value;
  }
  return nil;
}
static BOOL KuroOutputProtected(NSString *directory,NSString *file,NSString **error) {
  struct stat info={0};
  if(!SafeNode(directory,geteuid(),YES,error)||lstat(directory.fileSystemRepresentation,&info)||(info.st_mode&07777)!=0700)return KuroOutputFail(error,@"diagnostic directory must remain owner-only mode0700");
  if(file&&(!SafeNode(file,geteuid(),NO,error)||lstat(file.fileSystemRepresentation,&info)||(info.st_mode&07777)!=0600||info.st_nlink!=1))return KuroOutputFail(error,@"diagnostic file must remain owner-only mode0600 with one link");
  return YES;
}
static BOOL KuroOutputPublish(NSString *directory,NSString *name,NSData *bytes,NSData *previous,NSString **error) {
  NSString *path=[directory stringByAppendingPathComponent:name];
  if(!KuroOutputProtected(directory,Exists(path)?path:nil,error))return NO;
  if(previous) {
    if(![ReadProtected(directory,path,geteuid(),error)isEqual:previous])return KuroOutputFail(error,@"diagnostic checkpoint changed; unknown object preserved");
    if([previous isEqual:bytes])return YES;
  } else if(Exists(path))return KuroOutputFail(error,@"unrecognized diagnostic file preserved");
  NSString *temporary=[directory stringByAppendingPathComponent:[@".log-"stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!WriteNew(temporary,bytes,0600,error))return NO; // Partial files remain evidence.
  if(previous) {
    if(![ReadProtected(directory,path,geteuid(),error)isEqual:previous])return KuroOutputFail(error,@"diagnostic changed before replacement; preserved");
    if(rename(temporary.fileSystemRepresentation,path.fileSystemRepresentation))return KuroOutputFail(error,@"diagnostic checkpoint replacement failed");
  } else if(renameatx_np(AT_FDCWD,temporary.fileSystemRepresentation,AT_FDCWD,path.fileSystemRepresentation,RENAME_EXCL))return KuroOutputFail(error,@"diagnostic publication failed; existing object preserved");
  return YES;
}
static BOOL KuroOutputSync(NSString *directory,NSString **error) {
  int fd=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);BOOL ok=fd>=0&&!fsync(fd);if(fd>=0)close(fd);
  return ok||KuroOutputFail(error,@"diagnostic directory synchronization failed");
}
@interface KuroCoreOutput : NSObject {
  int _reads[2],_writes[2],_readErrors[2];BOOL _eof[2];
  NSMutableData *_data[2];uint64_t _bytes[2],_finishDeadline;NSUInteger _capacity;
  dispatch_group_t _drain;BOOL _finished;NSArray<NSData *> *_needles;
  NSDictionary *_statistics;NSData *_published[2];NSString *_publishedDirectory;
}
- (instancetype)initWithSecrets:(NSArray<NSString *> *)secrets;
- (int)writer:(NSUInteger)stream;
- (void)closeWriters;
- (BOOL)checkpointTo:(NSString *)directory error:(NSString **)error;
- (BOOL)finishTo:(NSString *)directory error:(NSString **)error;
- (NSDictionary *)statistics;
@end
@implementation KuroCoreOutput
- (instancetype)initWithSecrets:(NSArray<NSString *> *)secrets {
  if((self=[super init])) {
    for(NSUInteger i=0;i<2;i++)_reads[i]=_writes[i]=-1;
    _needles=KuroOutputNeedles(secrets);if(!_needles)return nil;
    NSUInteger maximum=0;for(NSData *needle in _needles)maximum=MAX(maximum,needle.length);_capacity=KuroOutputLimit+maximum;
    for(NSUInteger i=0;i<2;i++) {
      int pair[2];if(pipe(pair))return nil;
      _reads[i]=fcntl(pair[0],F_DUPFD_CLOEXEC,4);_writes[i]=fcntl(pair[1],F_DUPFD_CLOEXEC,4);close(pair[0]);close(pair[1]);
      if(_reads[i]<0||_writes[i]<0)return nil;_data[i]=[NSMutableData data];
      int flags=fcntl(_reads[i],F_GETFL);
      if(flags<0||fcntl(_reads[i],F_SETFL,flags|O_NONBLOCK)||fcntl(_reads[i],F_SETFD,FD_CLOEXEC)||fcntl(_writes[i],F_SETFD,FD_CLOEXEC))return nil;
    }
    _drain=dispatch_group_create();dispatch_group_async(_drain,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[self drain];});
  }
  return self;
}
- (void)dealloc {for(NSUInteger i=0;i<2;i++){if(_reads[i]>=0)close(_reads[i]);if(_writes[i]>=0)close(_writes[i]);}}
- (int)writer:(NSUInteger)stream {return stream<2?_writes[stream]:-1;}
- (void)closeWriters {for(NSUInteger i=0;i<2;i++)if(_writes[i]>=0){close(_writes[i]);_writes[i]=-1;}}
- (void)drain {
  for(;;)@autoreleasepool {
    struct pollfd values[2]={{.fd=_reads[0],.events=POLLIN},{.fd=_reads[1],.events=POLLIN}};
    if(values[0].fd<0&&values[1].fd<0)break;
    uint64_t deadline;@synchronized(self){deadline=_finishDeadline;}if(deadline&&KuroMonotonicMilliseconds()>=deadline)break;
    int ready=poll(values,2,20);if(ready<0&&errno==EINTR)continue;
    if(ready<0){for(NSUInteger i=0;i<2;i++)_readErrors[i]=errno;break;}
    for(NSUInteger i=0;i<2;i++)if(values[i].fd>=0&&values[i].revents){
      unsigned char bytes[4096];ssize_t count=read(_reads[i],bytes,sizeof(bytes));
      if(count>0){_bytes[i]+=(uint64_t)count;NSUInteger retained=MIN((NSUInteger)count,_capacity-_data[i].length);if(retained)@synchronized(self){[_data[i]appendBytes:bytes length:retained];}}
      else if(!count||(errno!=EAGAIN&&errno!=EINTR)){if(count<0)_readErrors[i]=errno;else _eof[i]=YES;close(_reads[i]);_reads[i]=-1;}
    }
  }
  for(NSUInteger i=0;i<2;i++)if(_reads[i]>=0){close(_reads[i]);_reads[i]=-1;}
}
- (BOOL)checkpointTo:(NSString *)directory error:(NSString **)error {
  if(_publishedDirectory&&![_publishedDirectory isEqual:directory])return KuroOutputFail(error,@"capture evidence cannot move to another directory");
  if(!KuroOutputProtected(directory,nil,error))return NO;
  _publishedDirectory=[directory copy];
  NSString *firstError=nil;
  for(NSUInteger i=0;i<2;i++){
    NSData *raw;@synchronized(self){raw=[_data[i]copy];}NSData *bytes=KuroOutputRedact(raw,_needles);NSString *problem=nil;
    if(!KuroOutputPublish(directory,i?@"stderr.log":@"stdout.log",bytes,_published[i],&problem)){if(!firstError)firstError=problem?:@"diagnostic stream publication failed";}
    else _published[i]=bytes;
  }
  NSString *syncError=nil;if(!KuroOutputSync(directory,&syncError)&&!firstError)firstError=syncError;
  return !firstError||KuroOutputFail(error,firstError);
}
- (BOOL)finishTo:(NSString *)directory error:(NSString **)error {
  [self closeWriters];
  if(!_finished){@synchronized(self){_finishDeadline=KuroMonotonicMilliseconds()+500;}
    if(dispatch_group_wait(_drain,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)))return KuroOutputFail(error,@"bounded output drain did not complete; runtime must be preserved");_finished=YES;
  }
  NSMutableDictionary *statistics=[NSMutableDictionary dictionary];
  for(NSUInteger i=0;i<2;i++){
    NSData *bytes=KuroOutputRedact(_data[i],_needles);
    statistics[i?@"stderr":@"stdout"]=@{@"bytesRead":@(_bytes[i]),@"retainedBytes":@(bytes.length),@"truncated":@(_bytes[i]>KuroOutputLimit),@"eof":@(_eof[i]),@"readErrno":@(_readErrors[i])};
  }
  _statistics=[statistics copy];BOOL saved=[self checkpointTo:directory error:error];
  if(!_eof[0]||!_eof[1]||_readErrors[0]||_readErrors[1])return KuroOutputFail(error,@"output EOF/readback incomplete; runtime must be preserved");
  return saved;
}
- (NSDictionary *)statistics {return _statistics?:@{};}
@end

#endif
