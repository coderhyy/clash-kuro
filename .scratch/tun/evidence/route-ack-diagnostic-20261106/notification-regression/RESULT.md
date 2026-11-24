Known Darwin multicast notification fix

The e2 observed first 32 bytes and receive length 64 identify a short RTM_NEWMADDR/ifma_msghdr. Existing code aborted before waiting for an ACK. The fixture uses that prefix and length, with a clearly synthetic zero tail, and does not claim a full captured packet or prove an ACK was present in the real window.

The production loop now ignores only short, complete/self-sized RTM_VERSION/RTM_NEWMADDR headers with nonzero interface index. It counts ignoredNotifications separately from foreign PID/sequence headers. Notification is never an ACK. Matching ACK validation, 1000ms/256 bounds, failure readback and ownership/delete rules are unchanged. Unknown/malformed short packets still fail.

Exact final regression test bytes with old production source: RED exit1, first valid-notification-before-ACK case rejects at recv, actual error saved. Final source: GREEN exit0, all RouteTests including 9 failure-readback, 24 existing wire-loop and 10 notification scenarios, staged journal/ownership/durability/parser suites. Strict clang compiles exit0. No socket/sysctl/Core/App/helper/system operations executed.

Local SDK net/route.h RTM_NEWMADDR=0xf; net/if.h defines ifma_msghdr. Fixed XNU f6217f891ac0bb64f3d375211650a4c1ff8ca1ea bsd/net/rtsock.c1309-1313 selects this header;1661-1705 constructs membership notification with IFP/IFA. Cached source /private/tmp/kuro-ipv6-multicast-source-review/rtsock.c. Independent reviewer macos_acceptance handles final review.
