# Global default DNS metadata compatibility

Scope: four native source/test files only; existing Global resolver dictionary remains unchanged. This candidate supports the observed complete State:/Network/Global/DNS default shape. No Core, system network, service or installation was executed.

- Require all four private metadata fields together and only at State Global. Configuration ID is a bounded `Default: UUID 0` identifier, not authorization; order is an integer 0..INT32_MAX; interface is 1..UINT16_MAX and must agree with public InterfaceIndex. Flags accept only 0/2/4/6 (A/AAAA request bits). Scoped/service/supplemental or unknown bits, metadata elsewhere, incomplete shape and unknown fields remain refused.
- Production preflight consumes the private interface index through the existing interface-presence and preserved more-specific LAN/DNS-path checks. It does not discard scope or modify upstream DNS providers.
- Existing immutable full dictionary baseline, journal serialization, exact readback equality and owned-UUID-only deletion are unchanged. Four new coordinator fixtures prove unavailable interface and mismatched path refusal, full metadata journal preservation, active metadata mutation refusal and exact final baseline recovery.
- `DarwinDNSMetadataFixture()` is a static NSDictionary helper in tun-network.test.m before the production-test import. It uses anonymous Global/Service DNS 192.168.1.1 and interface2/en0, matching existing fixture topology. It is available to the separately owned seven-chain admission test.

## Primary-source basis

Pinned Apple configd commit `585b7f2fca293f4642d21d15c5daf187f63c4796`; source bytes/Git blob IDs are recorded in sources/provenance.json.

- [dns-configuration.c](https://github.com/apple-oss-distributions/configd/blob/585b7f2fca293f4642d21d15c5daf187f63c4796/Plugins/IPMonitor/dns-configuration.c): lines73–75 define FLAGS/IF_INDEX/ORDER; 195 writes resolver insertion order; 239–253 construct configuration identifier using `%s:%s%@ %ld`; 1169–1174 use Default/serviceID/0; 1222–1241 read IF_INDEX and set the actual resolver interface; 1245 onward consumes resolver flags. These are not merely arbitrary ignored fields.
- [dnsinfo.h](https://github.com/apple-oss-distributions/configd/blob/585b7f2fca293f4642d21d15c5daf187f63c4796/dnsinfo/dnsinfo.h): 83–84 define REQUEST_A_RECORDS=0x0002 / REQUEST_AAAA_RECORDS=0x0004; 89–91 define SCOPED=0x1000 / SERVICE_SPECIFIC=0x2000 / SUPPLEMENTAL=0x4000. Only the A/AAAA bits are admitted here. The public SystemConfiguration SDK does not define these private keys.

## Verification and limits

Strict production compile and focused NetworkTests exit0 (commands/stdout/stderr in verification.json and sibling logs). Focused run includes pure wire parser, fake route/DNS backends and protected temporary journals; it does not invoke the Darwin store or query/write system network. Old original source plus the new positive anonymous metadata fixture fails as expected; red-verification.json records that isolated build/run.

Actual full-system read-only preflight with this candidate source is still for the main session to execute before packaging/installation. Offline pass does not assert that the real snapshot, actual TUN startup, root authorization, DNS reachability or recovery was accepted. Other DNS variants remain conservatively unsupported.
