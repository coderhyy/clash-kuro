// Unprivileged experiment only: exact native code identity is not Electron bundle attestation.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef VARIANT
#define VARIANT "trusted"
#endif

#define CHECK(condition) do { if (!(condition)) { \
  fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #condition, errno); exit(1); \
} } while (0)

static CFDataRef code_hash(SecCodeRef code) {
  CFDictionaryRef info = NULL;
  CHECK(SecCodeCheckValidity(code, 0, NULL) == errSecSuccess);
  CHECK(SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info) == errSecSuccess);
  CFTypeRef hash = CFDictionaryGetValue(info, kSecCodeInfoUnique);
  CHECK(hash && CFGetTypeID(hash) == CFDataGetTypeID());
  CFRetain(hash);
  CFRelease(info);
  return (CFDataRef)hash;
}

static int connect_client(const char *path) {
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  CHECK(strlen(path) < sizeof(address.sun_path));
  strcpy(address.sun_path, path);
  int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  CHECK(socket_fd >= 0);
  CHECK(connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) == 0);
  // Keep this process alive until the server has inspected its kernel-supplied audit token.
  char acknowledgement;
  CHECK(read(socket_fd, &acknowledgement, 1) == 1);
  CHECK(close(socket_fd) == 0);
  printf("client fixture: %s\n", VARIANT);
  return 0;
}

int main(int argc, char **argv) {
  alarm(15);
  if (argc == 3 && strcmp(argv[1], "--client") == 0) return connect_client(argv[2]);
  CHECK(argc == 2);
  CHECK(geteuid() != 0);
  SecCodeRef self = NULL;
  CHECK(SecCodeCopySelf(0, &self) == errSecSuccess);
  CFDataRef trusted_hash = code_hash(self);
  CFRelease(self);

  char directory[] = "/tmp/kuro-peer-XXXXXX";
  CHECK(mkdtemp(directory));
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  CHECK(snprintf(address.sun_path, sizeof(address.sun_path), "%s/socket", directory) < (int)sizeof(address.sun_path));
  int listener = socket(AF_UNIX, SOCK_STREAM, 0);
  CHECK(listener >= 0);
  CHECK(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
  CHECK(listen(listener, 1) == 0);

  for (int variant = 0; variant < 2; variant++) {
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
      close(listener);
      const char *executable = variant == 0 ? argv[0] : argv[1];
      execl(executable, executable, "--client", address.sun_path, (char *)NULL);
      _exit(127);
    }
    int peer = accept(listener, NULL, NULL);
    CHECK(peer >= 0);
    audit_token_t token;
    socklen_t length = sizeof(token);
    CHECK(getsockopt(peer, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0);
    CHECK(length == sizeof(token));
    CHECK(audit_token_to_pid(token) == child);
    CHECK(audit_token_to_euid(token) == geteuid());

    CFDataRef token_data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    const void *key = kSecGuestAttributeAudit;
    const void *value = token_data;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, &value, 1,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef guest = NULL;
    CHECK(SecCodeCopyGuestWithAttributes(NULL, attributes, 0, &guest) == errSecSuccess);
    CFDataRef peer_hash = code_hash(guest);
    int authorized = CFEqual(trusted_hash, peer_hash);
    CHECK(authorized == (variant == 0));
    printf("PASS: same UID, kernel peer PID, %s executable %s\n",
      variant == 0 ? "pinned" : "different", authorized ? "accepted" : "rejected");
    CHECK(write(peer, "x", 1) == 1);
    close(peer);
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CFRelease(peer_hash);
    CFRelease(guest);
    CFRelease(attributes);
    CFRelease(token_data);
  }
  CFRelease(trusted_hash);
  close(listener);
  CHECK(unlink(address.sun_path) == 0);
  CHECK(rmdir(directory) == 0);
  return 0;
}
