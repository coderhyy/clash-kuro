#import "tun-interface.m"

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
  KuroInterfaceStateChanged,
} KuroInterfaceScenario;
static struct {
  KuroInterfaceScenario scenario;
  unsigned int identityReads, listReads, socketReads, indexReads;
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
  if (scenario == KuroInterfaceShortSocket || (scenario == KuroInterfaceUnrelatedReadFailed && descriptor == 5 && KuroInterfaceFixture.listReads == 2)) return size - 1;
  struct socket_fdinfo socket = {0}; struct socket_info *info = &socket.psi;
  info->soi_so = (uint64_t)descriptor + 100; info->soi_pcb = (uint64_t)descriptor + 200;
  info->soi_family = AF_INET; info->soi_type = SOCK_STREAM; info->soi_protocol = IPPROTO_TCP; info->soi_kind = SOCKINFO_TCP;
  if (descriptor == 5 && (scenario == KuroInterfaceTCPChanged || scenario == KuroInterfaceUDPChanged)) {
    if (scenario == KuroInterfaceUDPChanged) { info->soi_type = SOCK_DGRAM; info->soi_protocol = IPPROTO_UDP; info->soi_kind = SOCKINFO_IN; }
    info->soi_state = KuroInterfaceFixture.listReads == 1 ? SOI_S_ISCONNECTING : SOI_S_ISCONNECTED;
    if (KuroInterfaceFixture.listReads == 2) { info->soi_so++; info->soi_pcb++; }
  }
  if (((descriptor == 9 || (descriptor == 10 && scenario == KuroInterfaceTunFDChanged)) && scenario != KuroInterfaceNoTun) ||
    (descriptor == 3 && (scenario == KuroInterfaceMultiple || scenario == KuroInterfaceMultipleAppeared))) {
    info->soi_family = AF_SYSTEM; info->soi_type = SOCK_DGRAM; info->soi_protocol = SYSPROTO_CONTROL;
    info->soi_kind = SOCKINFO_KERN_CTL; info->soi_state = SOI_S_ISCONNECTED;
    struct kern_ctl_info *control = &info->soi_proto.pri_kern_ctl;
    control->kcsi_id = 17; control->kcsi_unit = 8; strlcpy(control->kcsi_name, UTUN_CONTROL_NAME, sizeof(control->kcsi_name));
    if (scenario == KuroInterfaceHandleChanged && KuroInterfaceFixture.listReads == 2) info->soi_so++;
    if (scenario == KuroInterfaceUnitChanged && KuroInterfaceFixture.listReads == 2) control->kcsi_unit++;
    if (scenario == KuroInterfaceDisconnected) info->soi_state |= SOI_S_ISDISCONNECTING;
    if (scenario == KuroInterfaceWrongFamily) info->soi_family = AF_INET;
    if (scenario == KuroInterfaceMissingKind) info->soi_kind = SOCKINFO_GENERIC;
    if (scenario == KuroInterfaceBadName) memset(control->kcsi_name, 'x', sizeof(control->kcsi_name));
    if (scenario == KuroInterfaceZeroHandle) info->soi_so = 0;
    if (KuroInterfaceFixture.listReads == 2) {
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
  CHECK(index == 70 || index == 71);
  strlcpy(name, KuroInterfaceFixture.scenario == KuroInterfaceReverseChanged ? "en0" :
    KuroInterfaceFixture.scenario == KuroInterfaceUnitChanged && KuroInterfaceFixture.listReads == 2 ? "utun8" : "utun7", IF_NAMESIZE);
  return name;
}
static void InterfaceTests(void) {
  CHECK(geteuid() != 0);
  const KuroInterfaceReader reader = {KuroInterfaceTestPIDInfo, KuroInterfaceTestFDInfo, KuroInterfaceTestNameToIndex, KuroInterfaceTestIndexToName};
  for (KuroInterfaceScenario scenario = KuroInterfaceStable; scenario <= KuroInterfaceStateChanged; scenario++) {
    memset(&KuroInterfaceFixture, 0, sizeof(KuroInterfaceFixture)); KuroInterfaceFixture.scenario = scenario;
    KuroCoreInterface observation; memset(&observation, 0xa5, sizeof(observation)); NSString *error = nil;
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
      if (scenario == KuroInterfaceUnrelatedReadFailed) CHECK([error containsString:@"socket read is denied, incomplete"]);
    }
  }
  // Exercise real libproc only on this process: it cannot be its own direct
  // child, so the production entry rejects before any socket/interface lookup.
  struct proc_bsdinfo self = {0}; CHECK(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &self, sizeof(self)) == sizeof(self));
  KuroCoreIdentity identity = {getpid(), self.pbi_start_tvsec, self.pbi_start_tvusec};
  KuroCoreInterface observation = {0}; NSString *error = nil;
  CHECK(!KuroObserveCoreInterface(identity, &observation, &error) && [error containsString:@"direct-child"]);
  identity.pid = 0; CHECK(!KuroObserveCoreInterface(identity, &observation, &error));
  puts("native Core/interface association: 34 injected snapshots (including unrelated FD/TCP/UDP churn) and real self-identity rejection passed; no Core spawn, utun creation or network mutation");
}
