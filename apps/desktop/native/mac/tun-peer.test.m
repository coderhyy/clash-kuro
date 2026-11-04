static void PeerIdentityTests(void) {
  int transport[2]; CHECK(!socketpair(AF_UNIX, SOCK_STREAM, 0, transport));
  pid_t process = fork(); CHECK(process >= 0);
  if (!process) {
    close(transport[0]); int owned[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, owned)) _exit(2);
    char byte = 'p'; struct iovec iov = {.iov_base=&byte,.iov_len=1};
    union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr message = {.msg_iov=&iov,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof(control.bytes)};
    struct cmsghdr *header = CMSG_FIRSTHDR(&message); header->cmsg_level=SOL_SOCKET; header->cmsg_type=SCM_RIGHTS; header->cmsg_len=CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(header), &owned[0], sizeof(int));
    if (sendmsg(transport[1], &message, 0) != 1) _exit(3);
    if (read(transport[1], &byte, 1) != 1) _exit(4);
    close(owned[0]); close(owned[1]); close(transport[1]); _exit(0);
  }
  close(transport[1]); char byte;
  struct iovec iov = {.iov_base=&byte,.iov_len=1};
  union { struct cmsghdr align; unsigned char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
  struct msghdr message = {.msg_iov=&iov,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof(control.bytes)};
  CHECK(recvmsg(transport[0], &message, 0) == 1);
  struct cmsghdr *header = CMSG_FIRSTHDR(&message); CHECK(header && header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS);
  int peer; memcpy(&peer, CMSG_DATA(header), sizeof(peer));
  NSString *error = nil; KuroPeerIdentity *identity = [KuroPeerIdentity observePeer:peer error:&error]; CHECK(identity && identity.isLive);
  CHECK(write(transport[0], "q", 1) == 1); int status; CHECK(waitpid(process, &status, 0) == process && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  CHECK(!identity.isLive); // Holding the passed socket cannot keep the client identity alive.
  close(peer); close(transport[0]);
  puts("native peer identity: kernel audit identity observed, passed FD cannot survive original peer exit");
}
