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


### 2026-11-10：29e1883 实际 DNS 样本与一次原会话恢复

源码 `29e188362196af65242095b9aefab7b3a57c097c`、包 SHA256 `197e092863cb23fe5221ac6865f7e45b27d7d71edfc5d64c8738d98e5d10a179` 经双平台 CI 42803904766 和实际包独审后运行。实际 App ready 后启动仍拒绝；新增诊断确认只改一个 Global DNS 记录，无增删 key，变更字段为 cid/if/flags/servers/searchOrder，无未知字段。Default flags=2/interface14 变为本 session Supplemental、flags=16386、无接口索引；servers 精确为自有固定值，DomainName 缺席、SearchOrder=1。该真实样本支持收窄的 configd 派生形状处理，不能据此忽略任意 Global 或非 Global 变化。

Core SIGTERM→exit0、双路EOF；首次自动恢复因合并的 route/DNS baseline 检查失败保留 owner/network/work，无 stopped proof。稍后只读完整 stableRoutes/DNS/interfaces 已回原基线；旧错误未区分当时 route 与 DNS，不能倒推只因 configd 延迟。用户随后单独批准一次原 App/helper 会话恢复：只点击一次恢复，持久 childReaped/cleanupComplete/routesOff/dnsOff 全通过，准确会话记录及 work 清退；正常退出 App 后原基线核验、job/安装路径/进程缺席及精确 receipt 清理全部通过。未重启 Core/TUN、未手改 DNS/route/第三方设置。

受控流量未执行，先前 IPv4 出站 ENETUNREACH 尚未解释；固定 en0 绑定源码与 GLOBAL/NECP 线索不等同根因。原始证据留本地 `/private/tmp/kuro-29e1883-window-_9ow03kl` 与受保护诊断 `/Library/Application Support/Clash Kuro/TunDiagnostics/F89F129D-531B-471E-8B3E-72BAF00B933B`。本轮只证明该保留会话可显式恢复及准确卸载，不算正常流量/停止验收通过。

最小修复范围：活动时只在原自有 UUID key 两路读回准确后，允许本会话严格五字段 Supplemental Global，原 Default 也限实测闭合形状，其他完整 DNS 记录不变。恢复只在准确 Core/interface/writer 缺席、自有 DNS 清理完成后对同一精确派生记录等待入口起算最多 200ms；路由或其他 DNS 变化立即拒绝。连续两次完整原 baseline 才可进入原 route absence 及持久退休流程；DNS 清理持久化失败保留 route journal。启动诊断保留有限字段差异，恢复错误区分 owner-binding/owner-exit/route-read/route-changed/dns-read/dns-changed/derived-timeout/dns-retirement。外层 2s 不变，不能保证单次同步 OS 调用硬耗时上限。


### 2026-11-10：1252 DNS 修复候选（FD 复核拒绝，精确清理完成）

源码 `1252d09edb63a0ccebd0de134207e208b5db4ca9`、包 SHA256 `f7703b9c7911bac74f831ebeadab7d765c69b6f39f4059adf781a9d6cd702da2` 经完整本地 native、双平台 CI 42811038198、实际包及窗口独审后运行。安装前 stableRoutes/DNS/interfaces 与原已恢复快照完全一致，有效 DNS 为批准路由器，系统代理关闭。fresh 安装及实际 App ready 通过；单次开启失败原因为 `temporary DNS write was not independently confirmed; journal retained; stage=post-write-admission; reason=Core socket read is denied, incomplete, or raced with a closed FD`。这证明临时 DNS key 写入和直接值读回已通过；后续 ownership 检查拒绝，不能据此确认整个派生 Global 兼容路径已实机通过。未执行受控流量。

原会话 SIGTERM→exit0、双路 EOF、networkRecovery restored 与四项持久停止证明通过；owner/network/DNS journal/session-work 清退。App 退出后原基线 stableRoutes/DNS/interfaces 全等，准确 job bootout、原生 uninstall、安装路径/进程缺席及 receipt forget 通过。原始证据仅留本地 `/private/tmp/kuro-1252d09-window-j871vh71`，受保护诊断 `/Library/Application Support/Clash Kuro/TunDiagnostics/4E163013-3F02-43A9-BA45-56FB19212E0C`。

当前唯一原错误位于逐 socket FD 的 proc_pidfdinfo 长度检查，尚未记录 errno/实际长度/失败 FD，无法区分权限拒绝、短读与枚举后关闭竞态。保持拒绝条件，下一步补真实无害 child FD 关闭复现及有限诊断，不直接跳过未知失败。背景 IPv4 DIRECT ENETUNREACH 再现，仍无受控流量关联或根因证明；无物理 IPv6 出口不能解释 IPv4 错误。正常启停、代理节点及完整双栈验收均未通过。

核验层最小修复：首次 discover 保留原完整枚举、唯一 utun、两完整样本及 process/index 门；后续 ownership 只双读原会话目标 FD，复用原 socket/control 校验并比较原绑定，背景连接不再被当作该目标归属条件。没有 retry/sleep、新 schema、writer 或清理权限。target 权限/短读/替换、原 process/start/parent/index 变化仍拒，未知不作 exited。先前重采样候选经独审发现 partial-target 问题，已撤回且未进入生产。

真实普通用户 direct-child/socketpair fixture 经 pipe 屏障在枚举后由准确 child 关闭 FD：原读返回792/errno0，关闭后真实 proc_pidfdinfo 返回0/EBADF9，准确 waitpid exit0。它证明此动态机制而非1252现场的缺失 errno；未知目标初次发现仍拒绝。同背景读失败的旧完整复核 RED／新目标复核 GREEN，目标替换、访问拒绝、短读及身份变化回归通过；替代三文件 patch `c2276506f94e28db7d1f949477d81b6cb2c8a48a27f6cddce92edd7c575ed2c7` 独审通过，完整 native/CI 由主会话继续核验。有限失败诊断新增 sample/fd/ordinal/returned/expected/errno/mode，不输出地址或 opaque handles。

三项目固定源码对照及逐项核验边界已写现有 spec/ADR-0014。未发现需借鉴公共 DNS、setuid、按名称或旧PID清退的理由；路由仍由固定 Core 独占写入。受控流量和真实正常停止仍未验收，IPv4 ENETUNREACH 未解释。
