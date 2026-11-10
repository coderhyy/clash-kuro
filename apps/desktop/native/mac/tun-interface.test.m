#import "tun-interface.m"
#include <poll.h>
#include <sys/wait.h>

typedef enum {
  KuroInterfaceStable, KuroInterfaceNoTun, KuroInterfaceMultiple, KuroInterfaceDenied,
  KuroInterfaceFullList, KuroInterfaceShortSocket, KuroInterfaceStartChanged,
  KuroInterfaceFDChanged, KuroInterfaceHandleChanged, KuroInterfaceUnitChanged,
  KuroInterfaceIndexChanged, KuroInterfaceReverseChanged, KuroInterfaceDisconnected,
  KuroInterfaceWrongFamily, KuroInterfaceMissingKind, KuroInterfaceBadName,
  KuroInterfaceZeroHandle, KuroInterfaceDuplicateFD, KuroInterfaceWrongParent,
  KuroInterfaceOversized, KuroInterfaceMalformedList,
  KuroInterfaceTCPChanged, KuroInterfaceUDPChanged, KuroInterfaceFDAdded,
  KuroInterfaceTunFDChanged, KuroInterfacePCBChanged, KuroInterfaceControlIDChanged,
  KuroInterfaceTypeChanged, KuroInterfaceProtocolChanged, KuroInterfaceControlNameChanged,
  KuroInterfaceFDTypeChanged, KuroInterfaceMultipleAppeared, KuroInterfaceUnrelatedReadFailed,
  KuroInterfaceStateChanged, KuroInterfaceSocketEPERM, KuroInterfaceSocketEACCES,
  KuroInterfaceTargetSocketClosed, KuroInterfaceZeroSocket,
} KuroInterfaceScenario;
static struct {
  KuroInterfaceScenario scenario;
  unsigned int identityReads, listReads, socketReads, indexReads, targetReads, targetFault;
} KuroInterfaceFixture;
static const KuroCoreIdentity KuroInterfaceTestIdentity = {4242, 123, 456};
static int KuroInterfaceTestPIDInfo(int pid, int flavor, uint64_t arg, void *buffer, int size) {
  CHECK(pid == KuroInterfaceTestIdentity.pid && !arg);
  KuroInterfaceScenario scenario = KuroInterfaceFixture.scenario;
  if (flavor == PROC_PIDTBSDINFO) {
    CHECK(size == sizeof(struct proc_bsdinfo));
    KuroInterfaceFixture.identityReads++;
    struct proc_bsdinfo process = {0}; process.pbi_pid = (uint32_t)pid; process.pbi_ppid = (uint32_t)getpid();
    process.pbi_status = SSLEEP; process.pbi_start_tvsec = 123; process.pbi_start_tvusec = 456;
    if (scenario == KuroInterfaceStartChanged && KuroInterfaceFixture.identityReads == 2) process.pbi_start_tvusec++;
    if (scenario == KuroInterfaceWrongParent) process.pbi_ppid++;
    memcpy(buffer, &process, sizeof(process)); return sizeof(process);
  }
  CHECK(flavor == PROC_PIDLISTFDS);
  if (scenario == KuroInterfaceDenied) return 0;
  if (!buffer) return scenario == KuroInterfaceOversized ? (int)((KuroInterfaceFDLimit + 1) * sizeof(struct proc_fdinfo)) : 4 * sizeof(struct proc_fdinfo);
  KuroInterfaceFixture.listReads++;
  if (scenario == KuroInterfaceFullList) return size;
  if (scenario == KuroInterfaceMalformedList) return sizeof(struct proc_fdinfo) + 1;
  struct proc_fdinfo entries[] = {{9, PROX_FDTYPE_SOCKET}, {3, PROX_FDTYPE_VNODE}, {5, PROX_FDTYPE_SOCKET}, {11, PROX_FDTYPE_VNODE}};
  NSUInteger count = scenario == KuroInterfaceFDAdded && KuroInterfaceFixture.listReads == 2 ? 4 : 3;
  if (KuroInterfaceFixture.listReads == 2) {
    if (scenario == KuroInterfaceTunFDChanged) entries[0].proc_fd = 10;
    if (scenario == KuroInterfaceFDTypeChanged) entries[0].proc_fdtype = PROX_FDTYPE_VNODE;
    if (scenario == KuroInterfaceMultipleAppeared) entries[1].proc_fdtype = PROX_FDTYPE_SOCKET;
  }
  if (scenario == KuroInterfaceMultiple) entries[1].proc_fdtype = PROX_FDTYPE_SOCKET;
  if (scenario == KuroInterfaceDuplicateFD) entries[1].proc_fd = 9;
  if (scenario == KuroInterfaceFDChanged && KuroInterfaceFixture.listReads == 2) entries[1].proc_fd++;
  // Enumeration order itself is not identity.
  if (KuroInterfaceFixture.listReads == 2) { struct proc_fdinfo temporary = entries[0]; entries[0] = entries[2]; entries[2] = temporary; }
  CHECK(size >= (int)(count * sizeof(entries[0]))); memcpy(buffer, entries, count * sizeof(entries[0])); return (int)(count * sizeof(entries[0]));
}
static int KuroInterfaceTestFDInfo(int pid, int descriptor, int flavor, void *buffer, int size) {
  CHECK(pid == 4242 && flavor == PROC_PIDFDSOCKETINFO && size == sizeof(struct socket_fdinfo));
  KuroInterfaceFixture.socketReads++;
  KuroInterfaceScenario scenario = KuroInterfaceFixture.scenario;
  unsigned int sample=KuroInterfaceFixture.targetReads?:KuroInterfaceFixture.listReads;
  if ((scenario == KuroInterfaceSocketEPERM || scenario == KuroInterfaceSocketEACCES) && descriptor == 5) { errno = scenario == KuroInterfaceSocketEPERM ? EPERM : EACCES; return 0; }
  if (scenario == KuroInterfaceTargetSocketClosed && descriptor == 9) { errno = EBADF; return 0; }
  if (scenario == KuroInterfaceZeroSocket && descriptor == 5) return 0;
  if (scenario == KuroInterfaceShortSocket || (scenario == KuroInterfaceUnrelatedReadFailed && descriptor == 5 && sample == 2)) return size - 1;
  struct socket_fdinfo socket = {0}; struct socket_info *info = &socket.psi;
  info->soi_so = (uint64_t)descriptor + 100; info->soi_pcb = (uint64_t)descriptor + 200;
  info->soi_family = AF_INET; info->soi_type = SOCK_STREAM; info->soi_protocol = IPPROTO_TCP; info->soi_kind = SOCKINFO_TCP;
  if (descriptor == 5 && (scenario == KuroInterfaceTCPChanged || scenario == KuroInterfaceUDPChanged)) {
    if (scenario == KuroInterfaceUDPChanged) { info->soi_type = SOCK_DGRAM; info->soi_protocol = IPPROTO_UDP; info->soi_kind = SOCKINFO_IN; }
    info->soi_state = sample == 1 ? SOI_S_ISCONNECTING : SOI_S_ISCONNECTED;
    if (sample == 2) { info->soi_so++; info->soi_pcb++; }
  }
  if (((descriptor == 9 || (descriptor == 10 && scenario == KuroInterfaceTunFDChanged)) && scenario != KuroInterfaceNoTun) ||
    (descriptor == 3 && (scenario == KuroInterfaceMultiple || scenario == KuroInterfaceMultipleAppeared))) {
    info->soi_family = AF_SYSTEM; info->soi_type = SOCK_DGRAM; info->soi_protocol = SYSPROTO_CONTROL;
    info->soi_kind = SOCKINFO_KERN_CTL; info->soi_state = SOI_S_ISCONNECTED;
    struct kern_ctl_info *control = &info->soi_proto.pri_kern_ctl;
    control->kcsi_id = 17; control->kcsi_unit = 8; strlcpy(control->kcsi_name, UTUN_CONTROL_NAME, sizeof(control->kcsi_name));
    if (scenario == KuroInterfaceHandleChanged && sample == 2) info->soi_so++;
    if (scenario == KuroInterfaceUnitChanged && sample == 2) control->kcsi_unit++;
    if (scenario == KuroInterfaceDisconnected) info->soi_state |= SOI_S_ISDISCONNECTING;
    if (scenario == KuroInterfaceWrongFamily) info->soi_family = AF_INET;
    if (scenario == KuroInterfaceMissingKind) info->soi_kind = SOCKINFO_GENERIC;
    if (scenario == KuroInterfaceBadName) memset(control->kcsi_name, 'x', sizeof(control->kcsi_name));
    if (scenario == KuroInterfaceZeroHandle) info->soi_so = 0;
    if (sample == 2) {
      if (scenario == KuroInterfacePCBChanged) info->soi_pcb++;
      if (scenario == KuroInterfaceControlIDChanged) control->kcsi_id++;
      if (scenario == KuroInterfaceTypeChanged) info->soi_type = SOCK_STREAM;
      if (scenario == KuroInterfaceProtocolChanged) info->soi_protocol++;
      if (scenario == KuroInterfaceControlNameChanged) strlcpy(control->kcsi_name, "other.control", sizeof(control->kcsi_name));
      if (scenario == KuroInterfaceStateChanged) info->soi_state |= SOI_S_DRAINING;
    }
  }
  // Unstable traffic counters are intentionally excluded from identity.
  info->soi_rcv.sbi_cc = KuroInterfaceFixture.socketReads;
  memcpy(buffer, &socket, sizeof(socket)); return sizeof(socket);
}
static unsigned int KuroInterfaceTestNameToIndex(const char *name) {
  CHECK(!strcmp(name, "utun7") || (KuroInterfaceFixture.scenario == KuroInterfaceUnitChanged && !strcmp(name, "utun8")));
  KuroInterfaceFixture.indexReads++;
  return KuroInterfaceFixture.scenario == KuroInterfaceIndexChanged && KuroInterfaceFixture.indexReads >= 3 ? 71 : 70;
}
static char *KuroInterfaceTestIndexToName(unsigned int index, char *name) {
  unsigned int sample=KuroInterfaceFixture.targetReads?:KuroInterfaceFixture.listReads;
  CHECK(index == 70 || index == 71);
  strlcpy(name, KuroInterfaceFixture.scenario == KuroInterfaceReverseChanged ? "en0" :
    KuroInterfaceFixture.scenario == KuroInterfaceUnitChanged && sample == 2 ? "utun8" : "utun7", IF_NAMESIZE);
  return name;
}

// Target mode must never enumerate/read unrelated descriptors. The same socket
// fixture fields are sampled by target-read ordinal instead of census ordinal.
static int KuroInterfaceTargetPIDInfo(int pid,int flavor,uint64_t arg,void *buffer,int size) {
  CHECK(flavor==PROC_PIDTBSDINFO);
  return KuroInterfaceTestPIDInfo(pid,flavor,arg,buffer,size);
}
static int KuroInterfaceTargetFDInfo(int pid,int descriptor,int flavor,void *buffer,int size) {
  CHECK(descriptor==9);
  KuroInterfaceFixture.targetReads++;
  if(KuroInterfaceFixture.targetFault) {
    errno=KuroInterfaceFixture.targetFault==1?EPERM:KuroInterfaceFixture.targetFault==2?EACCES:0;
    return KuroInterfaceFixture.targetFault==4?size-1:0;
  }
  return KuroInterfaceTestFDInfo(pid,descriptor,flavor,buffer,size);
}
static void InterfaceTargetTests(void) {
  const KuroInterfaceReader discovery={KuroInterfaceTestPIDInfo,KuroInterfaceTestFDInfo,KuroInterfaceTestNameToIndex,KuroInterfaceTestIndexToName};
  const KuroInterfaceReader target={KuroInterfaceTargetPIDInfo,KuroInterfaceTargetFDInfo,KuroInterfaceTestNameToIndex,KuroInterfaceTestIndexToName};
  memset(&KuroInterfaceFixture,0,sizeof(KuroInterfaceFixture));
  KuroCoreInterface saved={0};NSString *error=nil;
  CHECK(KuroObserveCoreInterfaceWithReader(KuroInterfaceTestIdentity,&saved,&discovery,&error));
  const KuroInterfaceScenario cases[]={KuroInterfaceStable,KuroInterfaceSocketEPERM,KuroInterfaceUnrelatedReadFailed,KuroInterfaceMultipleAppeared,
    KuroInterfaceTargetSocketClosed,KuroInterfaceShortSocket,KuroInterfaceStartChanged,KuroInterfaceWrongParent,
    KuroInterfaceHandleChanged,KuroInterfacePCBChanged,KuroInterfaceControlIDChanged,KuroInterfaceUnitChanged,
    KuroInterfaceTypeChanged,KuroInterfaceProtocolChanged,KuroInterfaceControlNameChanged,KuroInterfaceStateChanged,
    KuroInterfaceIndexChanged,KuroInterfaceReverseChanged,KuroInterfaceWrongFamily,KuroInterfaceMissingKind};
  for(NSUInteger n=0;n<sizeof(cases)/sizeof(cases[0]);n++) {
    memset(&KuroInterfaceFixture,0,sizeof(KuroInterfaceFixture));KuroInterfaceFixture.scenario=cases[n];
    KuroCoreInterface observed={0},empty={0};error=nil;errno=EBUSY;
    BOOL accepted=KuroObserveCoreInterfaceExpectedWithReader(saved.process,&saved,&observed,&target,&error);
    if(n<4) {
      CHECK(accepted && !error && KuroInterfaceSameTarget(saved,observed));
      CHECK(KuroInterfaceFixture.targetReads==2 && KuroInterfaceFixture.socketReads==2 && KuroInterfaceFixture.identityReads==2 && KuroInterfaceFixture.indexReads==4);
    } else CHECK(!accepted && error.length && !memcmp(&observed,&empty,sizeof(empty)));
    CHECK(KuroInterfaceFixture.listReads==0 && KuroInterfaceFixture.targetReads<=2);
  }
  for(unsigned int fault=1;fault<=4;fault++) {
    memset(&KuroInterfaceFixture,0,sizeof(KuroInterfaceFixture));KuroInterfaceFixture.targetFault=fault;
    KuroCoreInterface observed={0},empty={0};error=nil;errno=EBUSY;
    CHECK(!KuroObserveCoreInterfaceExpectedWithReader(saved.process,&saved,&observed,&target,&error));
    CHECK(!memcmp(&observed,&empty,sizeof(empty)) && KuroInterfaceFixture.targetReads==1 && !KuroInterfaceFixture.listReads);
    CHECK([error containsString:@"mode=target"] && [error lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<512);
    CHECK(([error containsString:[NSString stringWithFormat:@"errno=%d",fault==1?EPERM:fault==2?EACCES:0]]));
  }
  // Valid but different saved tokens cannot adopt a current target, even if its
  // two reads agree. Descriptor/name are validated before any target syscall.
  for(NSUInteger n=0;n<5;n++) {
    memset(&KuroInterfaceFixture,0,sizeof(KuroInterfaceFixture));KuroCoreInterface wrong=saved,observed={0};error=nil;
    if(n==0)wrong.socketHandle++;if(n==1)wrong.pcbHandle++;if(n==2)wrong.interfaceIndex++;if(n==3)wrong.process.startMicros++;if(n==4)strlcpy(wrong.interfaceName,"utun8",IF_NAMESIZE);
    CHECK(!KuroObserveCoreInterfaceExpectedWithReader(saved.process,&wrong,&observed,&target,&error) && error.length);
  }
  puts("native saved-target observer: 29 cases passed; exactly two target reads, no background FD census; no later process-wide uniqueness claim");
}

// A real listed socket is closed by this exact held direct child before its
// pidfdinfo read. No utun, listener, Core executable or external traffic exists.
static struct { pid_t child; int descriptor, command, reply, returned, savedErrno; BOOL closed; } KuroInterfaceRealClose;
static char KuroInterfaceReadReply(int descriptor) {
  struct pollfd ready = {.fd=descriptor,.events=POLLIN};
  CHECK(poll(&ready,1,1000)==1 && (ready.revents&POLLIN));
  char value=0;CHECK(read(descriptor,&value,1)==1);return value;
}
static int KuroInterfaceRealCloseFDInfo(int pid,int descriptor,int flavor,void *buffer,int size) {
  if(pid==KuroInterfaceRealClose.child && descriptor==KuroInterfaceRealClose.descriptor) {
    CHECK(!KuroInterfaceRealClose.closed);
    CHECK(write(KuroInterfaceRealClose.command,"C",1)==1);
    CHECK(KuroInterfaceReadReply(KuroInterfaceRealClose.reply)=='C');
    KuroInterfaceRealClose.closed=YES;
    errno=0;int result=proc_pidfdinfo(pid,descriptor,flavor,buffer,size);int saved=errno;
    KuroInterfaceRealClose.returned=result;KuroInterfaceRealClose.savedErrno=saved;
    errno=saved;return result;
  }
  return proc_pidfdinfo(pid,descriptor,flavor,buffer,size);
}
static void InterfaceSocketCloseRaceTest(void) {
  CHECK(geteuid()!=0);
  int sockets[2],commands[2],replies[2];
  CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));CHECK(!pipe(commands));CHECK(!pipe(replies));
  pid_t child=fork();CHECK(child>=0);
  if(!child) {
    close(commands[1]);close(replies[0]);close(sockets[1]);alarm(5);
    if(write(replies[1],"R",1)!=1)_exit(91);
    char command=0;
    if(read(commands[0],&command,1)!=1 || command!='C' || close(sockets[0]))_exit(92);
    if(write(replies[1],"C",1)!=1)_exit(93);
    if(read(commands[0],&command,1)!=1 || command!='Q')_exit(94);
    close(commands[0]);close(replies[1]);_exit(0);
  }
  close(commands[0]);close(replies[1]);close(sockets[0]);close(sockets[1]);
  CHECK(KuroInterfaceReadReply(replies[0])=='R');
  struct proc_bsdinfo process={0};CHECK(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&process,sizeof(process))==sizeof(process));
  CHECK(process.pbi_pid==(uint32_t)child && process.pbi_ppid==(uint32_t)getpid());
  struct socket_fdinfo socket={0};errno=0;
  int before=proc_pidfdinfo(child,sockets[0],PROC_PIDFDSOCKETINFO,&socket,sizeof(socket)),beforeErrno=errno;
  CHECK(before==sizeof(socket) && socket.psi.soi_family==AF_UNIX);
  memset(&KuroInterfaceRealClose,0,sizeof(KuroInterfaceRealClose));
  KuroInterfaceRealClose.child=child;KuroInterfaceRealClose.descriptor=sockets[0];KuroInterfaceRealClose.command=commands[1];KuroInterfaceRealClose.reply=replies[0];
  const KuroInterfaceReader reader={proc_pidinfo,KuroInterfaceRealCloseFDInfo,if_nametoindex,if_indextoname};
  KuroCoreIdentity identity={child,process.pbi_start_tvsec,process.pbi_start_tvusec};KuroCoreInterface observed={0},empty={0};NSString *error=nil;
  BOOL accepted=KuroObserveCoreInterfaceWithReader(identity,&observed,&reader,&error);
  // Release and accurately reap the held child before any failure assertion.
  CHECK(write(commands[1],"Q",1)==1);close(commands[1]);close(replies[0]);
  int status=0;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
  printf("native real direct-child FD-close: beforeReturned=%d beforeErrno=%d afterReturned=%d afterErrno=%d expected=%lu childExit=0 accepted=%d error=%s\n",before,beforeErrno,KuroInterfaceRealClose.returned,KuroInterfaceRealClose.savedErrno,(unsigned long)sizeof(socket),accepted,error.UTF8String);
  CHECK(KuroInterfaceRealClose.closed && KuroInterfaceRealClose.returned==0 && KuroInterfaceRealClose.savedErrno==EBADF);
  CHECK(!accepted && !memcmp(&observed,&empty,sizeof(empty)));
  CHECK([error hasPrefix:@"Core socket read is denied, incomplete, or raced with a closed FD; socketRead "]);
  CHECK(([error containsString:[NSString stringWithFormat:@"sample=1 fd=%d ",sockets[0]]]));
  CHECK(([error containsString:[NSString stringWithFormat:@"returned=0 expected=%lu errno=%d",(unsigned long)sizeof(socket),EBADF]]));
  CHECK([error lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<512);
}


static void InterfaceTests(void) {
  CHECK(geteuid() != 0);
  const KuroInterfaceReader reader = {KuroInterfaceTestPIDInfo, KuroInterfaceTestFDInfo, KuroInterfaceTestNameToIndex, KuroInterfaceTestIndexToName};
  for (KuroInterfaceScenario scenario = KuroInterfaceStable; scenario <= KuroInterfaceZeroSocket; scenario++) {
    memset(&KuroInterfaceFixture, 0, sizeof(KuroInterfaceFixture)); KuroInterfaceFixture.scenario = scenario;
    KuroCoreInterface observation; memset(&observation, 0xa5, sizeof(observation)); NSString *error = nil;
    errno = EBUSY; // A short/zero result must not report an unrelated stale errno.
    BOOL success = KuroObserveCoreInterfaceWithReader(KuroInterfaceTestIdentity, &observation, &reader, &error);
    if (scenario == KuroInterfaceStable || scenario == KuroInterfaceFDChanged || scenario == KuroInterfaceTCPChanged ||
      scenario == KuroInterfaceUDPChanged || scenario == KuroInterfaceFDAdded) {
      if (!success) fprintf(stderr, "scenario %u rejected: %s\n", scenario, error.UTF8String);
      CHECK(success && !error && KuroInterfaceFixture.identityReads == 2 && KuroInterfaceFixture.listReads == 2 && KuroInterfaceFixture.socketReads == 4);
      CHECK(observation.process.pid == 4242 && observation.process.startMicros == 456 && observation.descriptor == 9);
      CHECK(observation.controlUnit == 8 && observation.controlID == 17 && observation.interfaceIndex == 70 && !strcmp(observation.interfaceName, "utun7"));
    } else {
      KuroCoreInterface empty = {0}; CHECK(!success && error.length && !memcmp(&observation, &empty, sizeof(empty)));
      if (scenario == KuroInterfaceHandleChanged || scenario == KuroInterfacePCBChanged || scenario == KuroInterfaceControlIDChanged)
        CHECK([error isEqual:@"Core utun FD/control-socket identity changed during verification"]);
      if (scenario == KuroInterfaceIndexChanged) CHECK([error isEqual:@"Core utun interface index changed during verification"]);
      if (scenario == KuroInterfaceShortSocket || scenario == KuroInterfaceUnrelatedReadFailed || scenario >= KuroInterfaceSocketEPERM) {
        CHECK([error hasPrefix:@"Core socket read is denied, incomplete, or raced with a closed FD; socketRead "]);
        int expectedErrno = scenario == KuroInterfaceSocketEPERM ? EPERM : scenario == KuroInterfaceSocketEACCES ? EACCES : scenario == KuroInterfaceTargetSocketClosed ? EBADF : 0;
        int expectedResult = scenario == KuroInterfaceShortSocket || scenario == KuroInterfaceUnrelatedReadFailed ? (int)sizeof(struct socket_fdinfo) - 1 : 0;
        CHECK(([error containsString:[NSString stringWithFormat:@"sample=%d fd=%d ", scenario == KuroInterfaceUnrelatedReadFailed ? 2 : 1, scenario == KuroInterfaceTargetSocketClosed ? 9 : 5]]));
        CHECK(([error containsString:[NSString stringWithFormat:@"returned=%d expected=%lu errno=%d", expectedResult, (unsigned long)sizeof(struct socket_fdinfo), expectedErrno]]));
        CHECK([error lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 512);
      }
    }
  }
  // Exercise real libproc only on this process: it cannot be its own direct
  // child, so the production entry rejects before any socket/interface lookup.
  struct proc_bsdinfo self = {0}; CHECK(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &self, sizeof(self)) == sizeof(self));
  KuroCoreIdentity identity = {getpid(), self.pbi_start_tvsec, self.pbi_start_tvusec};
  KuroCoreInterface observation = {0}; NSString *error = nil;
  CHECK(!KuroObserveCoreInterface(identity, &observation, &error) && [error containsString:@"direct-child"]);
  identity.pid = 0; CHECK(!KuroObserveCoreInterface(identity, &observation, &error));
  InterfaceTargetTests();
  InterfaceSocketCloseRaceTest();
  puts("native Core/interface association: 38 injected snapshots (including unrelated FD/TCP/UDP churn) and real self-identity rejection passed; no Core spawn, utun creation or network mutation");
}
