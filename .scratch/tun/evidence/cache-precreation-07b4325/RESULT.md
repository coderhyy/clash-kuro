# Fixed Core cache initialization: real normal / EOF passed

Source `07b432572a77a7df0f8ea0cca9180c76c4598778`. Frozen runner SHA256 `15794a6184b2a9b65a84bd220c6ffaaa7b5c9c2f4d0d458d845f0168e437132a`; fixed Core SHA256 `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`. Complete SHA256SUMS and `--inspect` passed before execution. Epoch `AE8BE158-9168-4AED-B65E-AA5F07BE4E26`.

Independent review passed; integrated frozen runner self-test passed 212 harmless fixture assertions. Under the continuing ordinary-user non-TUN authorization, normal ran first. Its complete success, exact process/directory absence and cache identity readback were independently checked before EOF ran.

Both real stages passed with runner exit0: private fixed-Core version, mode/selector readbacks, two point-in-time NoIP observations, requested SIGTERM and Core exit0/no signal. Normal received owner-stop ACK; EOF observed owner-connection EOF without ACK. EOF is not actual Electron exit.

Both precreated empty cache files remained on the same device/inode, owner and mode0600 after Core initialized their contents. EOF final cache size was 65536 bytes; final digests and both full identity snapshots are retained. This proves the tested fixed Core initialized these valid empty files in place. It does not imply corrupted caches cannot be replaced: the source has a remove/reopen path, and replacement remains rejected by the experiment.

Independent `proc_pidpath` returned ESRCH for normal Core/worker 87105/87104 and EOF 88628/88627. Both entire dedicated runtime bases were absent. No extra signal or deletion was needed. Restricted original diagnostics remain `/private/tmp/kuro-core-evidence-WsIJ1t` and `/private/tmp/kuro-core-evidence-MqqvLz`.

No installed service, root Core, TUN, system proxy/route/DNS or login-item operation occurred. Same-inode initialization permits preparing a production cache-origin receipt; it does not authorize cross-helper cleanup without trustworthy writer-exit evidence, prove all detached descendants absent, or establish network recovery. Production session/service were not changed by this experiment.
