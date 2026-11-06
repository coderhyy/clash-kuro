# Fixed Core internal IPv6 address retention

Three files only: production tun-session.m adds the fixed `SKIP_SYSTEM_IPV6_CHECK=true` to the existing explicit PATH/LANG spawn environment; session.test.m adds a real held harmless child observation; helper.test.m routes that child before Foundation main-body work. No shared source, Core, -t, system network or installation was run.

## Evidence and minimal behavior

Pinned mihomo v1.19.33 commit `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8` source files were checked against existing local Git tree blob SHA1s (pinned-source-evidence.json).

- [config.go:717](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L717) calls parseIPV6 before DNS/TUN parsing. [1680–1684](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L1680) clears raw Tun.Inet6Address when the system capability test fails even if explicit top-level ipv6 is true.
- [utils.go:188–206](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/utils.go#L188) accepts the exact `SKIP_SYSTEM_IPV6_CHECK` true override; otherwise it only accepts an already present IPv6 GlobalUnicast address. Thus an IPv4-only upstream can strip the explicitly requested internal utun IPv6 address. The 432 log showing Tun IPv6 [] and the runtime containing inet6-address is consistent with this exact code path.
- This fix preserves the approved dual-stack internal interface even without physical global IPv6. It does not claim IPv6 Internet reachability, widen the root schema or remove real dual-stack readiness/address/route gates. The flag is fixed by the helper, not caller/RPC/environment input.

## DNS mode is a separate path; no speculative parameter change

[sing_tun/server.go:277–307](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/server.go#L277) accepts disabled mode and unconditionally adds each internal IPv4/IPv6 address Next():53 to dnsAdds. It assigns that list to the listener handler at318–325. [dns.go:21–50](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/dns.go#L21) matches those exact destinations for TCP/UDP and relays to the Core DNS service. The locked sing-tun Darwin configureDNS disabled branch only skips its system DNS registration, which is owned by our helper. No source evidence requires changing dns-mode or broadening dns-hijack. Actual IPv6 creation and both reserved static-host probes still require the controlled real window.

## Verification

Strict production/focused compilation exit0; actual KuroOwnedSession suspended/resumed/reaped test-binary child receives the fixed values, ignores parent SKIP_SYSTEM_IPV6_CHECK=false, exits0 and cleans the protected temporary owner/work. Child runtime environment is compared to the exact three expected entries, permitting only Foundation's derived __CF_USER_TEXT_ENCODING key; that derived key is not an input in the literal three-entry posix_spawn array. All other extra runtime keys fail. Old source with the same new fixture fails the exact environment expectation (RED); commands/log hashes in freeze.json.

Initial fixture development tried a copied platform /usr/bin/env executable; it produced signal9 without stdout/stderr, so this was not used as evidence of environment behavior. A no-work fixture initially intentionally routed output to /dev/null via existing production behavior; the final fixture uses the actual protected work/capture path. An intermediate exact runtime comparison exposed the Foundation-derived field and was corrected specifically rather than allowing arbitrary inherited environment. Initial failed logs are retained; only final-* and red-* are acceptance evidence.

No claim is made that the live Core has now created IPv6, passed internal DNS readiness or successfully proxied traffic. Main session must integrate, verify, freeze a new candidate and perform any authorized real operations.
