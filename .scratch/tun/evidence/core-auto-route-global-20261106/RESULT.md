# Exact Core auto-route RTF_GLOBAL observation

## Current result (2026-11-10): 0102 failed start recovered and fully removed

Source `0102e49c80819f166a747ddf703bad5b5fff314a`, package SHA256 `43ff2b7e6d5d1e77dc862011d852d76fcd9e6168881eef3ce93dcccf1a4fd815`. CI 42204832391 passed on macOS and Windows; actual package and exact window scripts passed independent review. The new source0102 production preflight passed and its complete stable-route, DNS and interface snapshots matched the explicitly approved current baseline. No third-party conflict was present. The prior22 installation had already been exactly removed before this fresh window.

Actual installed App reached ready, then the fixed Core created a dual-stack utun with auto-route enabled. Start failed at process/network readback with `Core FD/socket/interface observation changed during verification`. This is a real combined-observation rejection. The saved diagnostic does not identify which FD, socket or interface field changed; no individual field is established as the measured cause. No controlled flow probe succeeded, and this is not a successful active-TUN/normal-stop acceptance result.

Same-session recovery passed: requested SIGTERM, observed exit0, stdout/stderr EOF, and networkRecovery.restored=true. The durable held-stop proof records childReaped, cleanupComplete, routesOff and dnsOff all true. After actual App Quit, the exact job was booted out, native uninstall completed, all expected installation paths were absent, and only the newly recorded exact Installer receipt was forgotten. Independent job readback returned113 and the receipt was absent. Full production stable routes, DNS and interfaces matched the approved baseline; no third-party settings were changed. Protected diagnostic evidence remains local as designed.

The next bounded change is a stable projection of the unique held utun. It must preserve complete process/FD/socket identity, interface uniqueness, and failure-on-unreadable checks. That implementation is being prepared by the windows agent; it is not validated by this failed window and must pass regression, independent review and a new same-version window. Do not remove the observation gate or infer a specific FD change from the generic diagnostic.

Local-only evidence: `/private/tmp/kuro-0102e49-window-o1r06wsa`. The package/preflight/source pins, approved raw snapshot, actual failure diagnostic, held proof, and precise uninstall/receipt results remain there; no raw network/process/session data is copied into this repository.

### Prior22 cleanup and native test evidence

On2026-11-10 the previously paused22 cleanup completed: exact job, native installation and receipt were removed. Original baseline bytes were preserved. Independently reviewed differences were only Apple awdl/llw link-local address rotation; an exact new stop-only snapshot was approved for cleanup, without changing interface or third-party configuration. That stop-only approval was not reused as startup approval: the0102 window captured and separately approved its own full snapshot. Local-only cleanup/reference evidence remains at `/private/tmp/kuro-resume-readonly-20261110-dycka_1r`.

The historical native run failed after8.156s at a socket-creation/bind assertion without recorded errno. It remains an unexplained assertion failure, not a measured timeout. A later ordinary-UID full native run outside the sandbox passed, and a separate UID501 socket check observed successful creation and bind of both endpoints with errno0. These passes do not establish the earlier failure's cause or erase its evidence; the raw logs remain local. CI42204832391 passed both platforms.

The sections below retain earlier results and their original limits. In particular,22's cleanup-hold paragraph describes its state at that time; it is superseded by the completed2026-11-10 cleanup above. Controlled successful TUN traffic, external IPv6 and abnormal recovery remain unverified.

## Historical27a GLOBAL observation

Controlled normal-window source27a1e54f690282e029488024f7c3fd938a97e000 passed both-platform CI42194367408 and independent source/package review. Phone-disconnected baseline passed before fresh installation.

Actual installed App authenticated to ready. Fixed Core created the TUN adapter, but readback rejected the lower IPv4 /1 route. Exact closed tuple matched destination/prefix/family/gateway and held utun identity; actual flags1073809411 (0x40010803) versus expected67587 (0x10803). Sole difference0x40000000=RTF_GLOBAL, defined by macOS SDK route.h. Fixed XNU route.c SA_DEFAULT checks zero destination without checking prefix, and adds GLOBAL to non-host RTM_ADD. This supports only lower IPv4/IPv6 /1 in the fixed plan, not the upper halves or internal /30.

Minimal correction permits optional GLOBAL only on those two keys. Other bits, route keys, gateway, exact interface index/name and observation/recovery checks remain mandatory. Regression replays actual tuple through the real observer; old code rejects, new code accepts, invalid material flags/gateway/interface and GLOBAL on other plan keys still reject. Coordinator fixture now uses the same source-grounded route samples.

Same-session failed-start recovery: SIGTERM exit0, both output EOF, durable child/network-off proof, no work/journal/owner residue. Routes and DNS restored exactly. Two unrelated Apple peer-interface linklocal addresses rotated; after independent saved-diff review, cleanup used a separately pinned stop-only snapshot. Original install baseline preserved, no interface or third-party setting modified. Exact job/install/receipt cleanup completed. Raw network/device/session evidence remains local and is not uploaded.

No traffic probe was attempted. Normal active TUN traffic and shutdown, external IPv6 and abnormal recovery remain unverified. USB/peer-interface dynamics require later compatibility validation; exact whole-baseline comparison in this controlled experiment is not a product requirement to reject all unrelated network changes.

Full local native/upgrade fixtures, fixed Core syntax validation, all eight production admission chains and bounded-output tests passed; no root/service/network activation. Raw execution log remains /private/tmp/kuro-global-full-native.log.

## dd312 controlled retry

Exact source dd312b63bb890cf97a14edecfd18addfa1a2a818, package SHA764e0061317e88767cec9431f4ab6f6262e31f81325f01adf06b0ca1979aa6c9; both-platform CI42198982549 and actual package review passed. Same approved Profile, disconnected-phone baseline, fresh install. Actual App reached ready; route readiness and internal DNS checks proceeded beyond the previous GLOBAL refusal. Resolver publication then failed with `temporary DNS write was not independently confirmed; journal retained`.

Core logs contain background connections classified MATCH,DIRECT, proving delivery into this Core but not successful outbound forwarding. Several TCP ENETUNREACH messages occurred before the final shutdown log; their timing does not resolve possible cleanup races. No controlled flow probe completed. Fixed runtime interface binding remains enabled and must not be relaxed based on these logs.

Same-session recovery passed: SIGTERM exit0, both output EOF, durable child/route/DNS-off proof, exact baseline route/DNS restoration. App exited after proof; accurate job/native uninstall and exact receipt cleanup succeeded. No install/process/job residue. Raw evidence remains local at /private/tmp/kuro-dd312b6-window-952rhs4a; retained protected diagnostics are local only.

Source review found the DNS generic error overwrites three distinct failures: readback backend error, value mismatch, and post-write admission error. Next minimal diagnostic change preserves the real branch/reason without changing acceptance, retrying, or adding network reads. Full TUN start/traffic/normal stop remains unverified.

## 22b controlled retry and cleanup hold

Source22b1a56f2f6fff6ef23ce0030b25a73b6e1fda3b, package SHA30a33d87089e02688ee6d3096c6fc0c599de1bc1fb4bd11b811f11422428ca6a. Both-platform CI42202031924 and independent actual-package/window review passed. Two current phone-disconnected production preflights matched the fixed baseline; previous installation/job/receipt and competing App/Core were absent. Fresh install and actual App ready passed.

Start failed at process/network readback with `route confirmation lacks this actor's prepared live Core`. This message combines journal, preparation and live-ownership failures; the exact branch is not yet established. Core created the dual-stack auto-route adapter and logged background MATCH,DIRECT handling, including outbound ENETUNREACH. No controlled flow succeeded or was attempted; do not equate ingress logs with successful forwarding.

Original-session recovery reported SIGTERM/exit0, complete output EOF, network restored, and durable childReaped/cleanupComplete/routesOff/dnsOff. Owner, work and network journals were absent. App then exited normally. Before uninstall, the independent baseline check rejected new broad capture routes and changed effective DNS. Read-only process evidence then confirmed competing third-party App and Core running again. This is a changed cleanup environment, not evidence that the original start failed because of that later process.

Cleanup stopped before job bootout/native uninstall; exact helper installation, job and receipt remain. No unknown route or third-party setting was changed. Local window evidence: /private/tmp/kuro-22b1a56-window-22jrq022. Protected diagnostic session: /Library/Application Support/Clash Kuro/TunDiagnostics/37E5F838-9766-47C2-8A0A-39E29176BDEA. Raw process/network/flow data stays local. System retries wait for a stable, conflict-free baseline and completion of exact cleanup. Independent diagnostic implementation continues; no acceptance or identity checks are relaxed.

The follow-up route-confirmation diagnostic preserves record validation errors and separates record/prepared-binding/ownership stages. Focused regression ran new tests against old production source (exit1, missing stage/original cause), then the changed production source (exit0). Seven real journal/actor cases cover valid confirmation, malformed journal, session mismatch, fresh actor, explicit ownership reason, absent reason and bounded text. Existing route observation/absence/GLOBAL tests pass; rejected paths retain their journal, with unchanged ownership/snapshot call counts. This validates error preservation, not the root cause of the real ownership failure.

## acf5 verification hold

Source acf5beef14a3bda931cbe14f380adbb06296ee94 fixes the independently reproduced unrelated-FD/socket snapshot rejection while retaining unique utun identity and complete reads. Local full native tests, App build and actual package review passed; package SHA03a56130144b60301af0306422839cad2577b443b2327fa895e491780037afd8. Read-only current baseline matched and no previous installation remained. This candidate was not installed: CI42794386304 failed both initial and one same-source retry.

Attempt1: native-suite SIGALRM at80325ms, exact stalled case unknown due buffered output; Windows test-port query exceeded5000ms. Attempt2: native-service DNS diagnostic equality assertion failed at33180ms (not a timeout); Windows queries again exceeded5000ms and a migration evidence collector exceeded10000ms. These are separate failures, not a demonstrated shared cause. Original logs are local at /private/tmp/kuro-acf5bee-ci-failure.log and /private/tmp/kuro-acf5bee-ci-attempt2-failure.log.

A deterministic real-service fixture reproduced a false DNS assertion: controller-secret prefix0 correctly redacts the final0 in ordersMatch=0, while raw failure retains the exact cause. The original CI omitted actual values, so this does not prove its unique root cause. Test-only correction stabilizes the three original exact-error scenarios and adds an exact suffix-redaction case. Production redaction/deadlines stay unchanged. Native test stdout is unbuffered to retain completed-test evidence on watchdog termination. Windows inventory logs add bounded suite/worker/ordinal/start/end/status/output-size evidence without output contents, keeping budgets, serial calls, failure propagation and cached rejection unchanged. No further network trial occurs before validation passes.


### 2026-11-10：3445848 正常窗口（DNS 准入拒绝，精确清理完成）

`78e4b89` macOS CI 通过，Windows CI 42797078504 的失败报告被可选日志路径阻塞。最小 failure-only stdout 顺序修复 `3445848df9cd55aa2bcc2b5c7223786ea09a9532` 保留成功路径、2200ms/exit42 与所有成功门；本地提取生产函数旧 RED／新 GREEN，新增实际 Windows 复合故障及双平台 CI 42799632296 通过。

同提交实际 finite-session 包 SHA256 `dbe20abf655b018a812d872188a5f8cf0ac6ab3975c99d59b3b82970cbfd237e` 经独审后 fresh 安装。只读现场路由、DNS、接口与批准快照一致；有效 DNS 为批准的路由器，系统代理关闭，无第三方 App/Core 接管。实际 App ready 后单次开启，越过此前 held-utun 观察拒绝，最终失败为 `temporary DNS write was not independently confirmed; journal retained; stage=post-write-admission; reason=DNS baseline changed; preserving existing resolvers and stopping this session`。尚未发送受控流量，不计正常启停通过。

原会话 SIGTERM→Core exit0、stdout/stderr EOF、networkRecovery restored 及 childReaped/cleanupComplete/routesOff/dnsOff 持久证明均通过。App 退出后原生精确卸载、job/进程/安装路径缺席及本次 receipt 清除通过。生产稳定路由、DNS、接口与当轮快照完全一致，系统代理和原始 DNS 读回一致；原始 netstat 文本有邻居缓存及到期时间差异，不称逐字节全路由一致，不删除这些对象。

原始受限证据只留本地 `/private/tmp/kuro-3445848-window-w7uma0cq`；受保护诊断 `/Library/Application Support/Clash Kuro/TunDiagnostics/E709508E-12A7-4E97-902C-AA686464FA48`。本轮未捕获 DNS 变化的具体字段；当前门仅移除自有 service key 后整表比较，configd 派生 Global 变化是源码支持的候选原因，不是已确认现场原因。下一步仅补有界差异诊断，不放宽 Global 或其他归属检查。受控流量工具已离线独审；未执行的请求/observer 不计作实机通过。

差异诊断修复：仅在原 DNS 全表不等分支追加最多 512 字符的固定 Global 字段摘要与相等布尔，复用已有快照，无新增系统读取、不改变准入或恢复。旧生产源码配相同新组合测试可编译并实际 RED；新源码两个 post-write-admission 拒绝场景及原四项 metadata 测试 GREEN。测试中的 Global 派生为注入后端，不能代替本机实测字段。原始 fixture/日志留本地 `/private/tmp/kuro-dns-baseline-diagnostic`。
