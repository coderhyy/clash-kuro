# TUN 接入生命周期

Status: ready-for-agent（生产客户端/State/UI已接线；完整安全适配与最终验证分阶段）
Type: task
Blocked by: 04受保护安装后动态鉴权与生产service/network hooks、真实双栈归属/恢复及最终组合验证；共享配置/V2/State/UI已接入，01产品决定已解决
Owner: TUN 接入 agent；主会话统一 Core/State/桌面公共接口与源码分工

## 负责范围

共享契约、配置准入、FakePlatform/调用方、State/UI/托盘/i18n/demo 接入同一生命周期。合并 [03 配置/契约](03-shared-contract-and-config.md) 和 [10 测试矩阵](10-mode-transition-contract.md)，[contract.md](../contract.md) 作为票内实施清单，旧票只留历史，不形成票间审批循环。与 [04 helper](04-macos-privileged-adapter.md) 的安装/认证实验并行；正式源码只采用主会话统一的最小接口。

## 实施清单与验收标准

- 共享契约：区分安装、Core、实际网络、unknown 与转换门；共享包无 OS/DOM/提权依赖，复用 Command 队列、Platform 和首次关闭截止时间，不造第二套状态机。
- 配置准入：普通 Core 最终 `tun.enable=false`，Profile/Override/Backup 不绕过应用准入；原文不变、无 tun 不新增模板。特权入口另经批准门禁，不能提供任意 true 参数或路径。保留现有配置禁用切片证据。
- 已批准启动策略：正常重开 App 也先检查/恢复自有残留，保持 TUN 关闭，用户手动开启；异常/重连/唤醒/Backup 不自动开启，未知时提示处理且阻止新模式写入。安装不等于运行，不从持久偏好/导入内容恢复 TUN。
- 转换及调用方：旧模式退出、归属/停止确认后才启目标；覆盖 Profile/Override/Settings 重载、Backup/remove、quit、native-stop、resume。迟到 Promise 不重开门；Backup 停止证据不足不提交导入，保留普通 MVP 兼容范围。
- 测试矩阵：双向互斥；停止失败/未知目标零启动；部分启动与清理失败；并发/退出/超时/迟到；无 Active Profile 恢复；正常重开关闭并需手动开启；旧 Settings/Backup；卸载前清理。fake 只证明受测门禁，不替代 08。
- 网络/界面：配合 04 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试。双栈固定模板/无高级 UI/参数可技术选定已由 [ADR-0017](../../../docs/adr/0017-macos-tun-dual-stack.md) 批准，首个候选见spec，root schema与离线候选已通过当前隔离验证；真实开启仍等04可信链、活跃会话与网络归属/恢复汇合。LAN/split DNS保持、不新增DNS供应商、不支持DNS具体拒绝及显式DIRECT已由 [ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 批准。开启与故障状态均展示无独立kill switch、路由消失可能直连；状态、忙碌/禁用、中英文与demo一致，不声称全流量/防泄漏，不静默关闭用户IPv6。
- Core/State/桌面受影响测试、类型检查与构建通过；真实适配与产物验收交 [08](08-tun-integration-acceptance.md)，不能以 UI 可点击标记完成。

## Comments

2026-11-04：03/10 仅票务归并，未表示 TUN 已实现。历史证据包括普通配置准入 Core138/State125/桌面调用方7项及类型检查、既有生命周期定向12项；详见历史票，不跨范围宣称通过。后续源码由实施 agent 交付，最终命令与证据待回填；没有真实系统操作。

2026-11-04 后续：Backup 历史停止证据缺口已修复生产 store：importBackup 入口与 await stop 后均 requireSession()，预先异常锁/备份中异常/stop 挂起异常迟到结果三时机均拒绝目标数据替换，无重启或代理写入。主会话报告三时机回归、State 全127/127和typecheck通过，文档已核对源码检查点；不把它扩大为完整TUN网络停止证明。最终组合CI/产物证据仍待回填。

2026-11-04 本轮生产接线：主会话统一TunStatus、snapshot.tun与setTun/recoverTun，桌面macOS客户端、State和双语UI已接入。未安装不假报安装；blocked/unknown展示真实error并可请求恢复；仅ready且off/on、非忙碌才正常切换；demo不假装native可用，重开手动启用文案无全流量承诺。UI/i18n/dev-bridge25/25及renderer typecheck通过；主会话随后报告State151、desktop359通过/17skip与全量typecheck通过。后续native修复、组合build/CI与精确产物由主会话最终回填，不能以接线或阶段数关闭本票。

2026-11-04 生产接线收口：state166/166（含39项TUN矩阵）通过；UI→IPC→既有Command队列→macOS socket客户端接通。独立TUN恢复锁不清掉native restart锁；startup/no-profile先检查恢复；转换/Backup停止证据/配置重载手动重开/late-result/quit/dispose门禁已接入。resumeCore作为仅main调用的方法整段进入原队列，避免唤醒把已排队TUN切回普通Core；普通流订阅按owner暂停/恢复。平台start入口受shutdown门禁与in-flight等待控制，始终沿首次deadline，超时不报告成功。macOS clearSystemProxy新增每服务HTTP/HTTPS严格Enabled:No读回，失败阻止后续模式启动；既有全局清理范围未改变，不称已实现自有TUN网络恢复。

原生start仍拒绝，故当前没有可用双栈TUN会话。root闭合schema与离线候选已实现并通过隔离验证；native owner/lease组件测试不等于生产会话接通。剩余门为完整可信链/有限broker、活跃session与并发独立status接入、网络owner清理/恢复的生产汇合，不再把schema本身列作未实现，也不等待用户再次批准双栈。仅取消/恢复/门禁的fake矩阵通过不能关闭本票。本轮开启与故障状态常显双语无kill switch/路由消失可能直连/显式DIRECT说明，并纳入开关aria-describedby；相关UI/i18n/demo27项及renderer typecheck通过，未改启用门禁或执行真实启动。


2026-11-04 当前实现复核：生产 Profile → Override → 当前 mode 的受限 TUN 配置先准入，再停止旧模式；反向 `startCore` / `setSystemProxy` 通过 `stopTunIfNeeded(beforeStop)`，在 inspect 确认活跃后先离线验证目标普通配置，失败不调用 TUN stop/普通 start/代理 set。主会话报告 State170/170，本 agent 只读复核并重跑该两项回归通过。V2客户端完整发送重验后的config，无V1start回退；有限帧/严格UTF-8与重复键/sequence/单心跳/lease、断链unknown和停止独立status读回已实现，会话捕获竞态已修复，临时socket43/43及main typecheck通过。原生Serve仍串行并拒绝open，活跃session/并发status与可信链/broker/网络归属恢复仍未汇合；本票保持进行中，无真实系统验收授权。


## 当前检查点：生产调用方与原生组件（2026-11-04）

本节覆盖上文“原生Serve仍串行”“活跃session/有限broker/路由未接入”“网络hooks只无条件拒绝”的历史状态。原生已有单owner V2服务、并发独立status、lease/stop、私有Core socket及有限mode/select；桌面完整config重验、离线准入先于停止旧模式、恢复锁、重开手动启用与无kill switch文案不变。主会话接入生产鉴权及network hooks，外层真实启动策略门仍关闭；组件fixture不代表真实会话验收通过。

本轮 [`tun-production-network.m`](../../../apps/desktop/native/mac/tun-production-network.m) 已实现真实系统后端的协调路径：认证后的preflight读取route/DNS/interface基线；仅接受同一已验证physical接口的双栈默认出口；持有原Core子进程的utun socket/名称/index与固定双栈地址/flags观测后，才以journal→确认→readback顺序安装四条`/1`和自有临时DNS key。运行中复核接口检查route receipts、保留基线、exact own DNS、physical/utun及本机解析器，供主会话每秒调用，失败走停止/unknown，不切换普通Core或System Proxy。

LAN/split支持边界具体为：保留现有更具体route及已识别的search/supplemental/scoped DNS原记录；Profile literal私有端点与既有DNS服务器须有可证明保留的更具体路径（Core出口还须匹配physical绑定），default-only私网路径、分离双默认出口、已有split-default owner、固定内部地址冲突、未知DNS字段/scoped literal等具体拒绝。不静默新增DIRECT规则、上游供应商或修改既有设置，不宣称枚举并保留任意LAN。内部唯一保留域`kuro-tun-ready.invalid`由root固定hosts映射，A/AAAA仅向utun内固定resolver发包并验证精确静态答复；不查询公共测试域名，内部域不构成DNS隐私产品变化。App闭合schema不开放physical接口/hosts字段。

同一held session恢复先移除精确自有DNS，再按当前归属恢复route；原Core已退出且utun消失仅接受相关route已absent，不盲删残留。全新helper的`recoverSession:nil`只校验保护receipt与目标route/DNS absence并清退receipt；有任何目标prefix/key、未知/变更记录则保留、返回恢复需要，绝不从持久PID推导kill/route写权限。此API仅证明网络组件，不能清除Core owner或冒报整会话off。

普通用户注入验证：生产协调层13场景（含基线变化、默认私网不支持、分离双默认、local probe失败、部分DNS写入、归属未知、跨重启冲突/absence、运行中DNS篡改与route消失）及原有route/DNS用例通过；构造对象不读网络，测试不调用Darwin网络后端、Core或`-t`。最终全量native/desktop/build和产物身份由主会话回填。

剩余实机证据保持有限：固定Core真实utun/address/flags与本地静态DNS A/AAAA；Darwin PF_ROUTE flags/ack/精确readback及并发删除窗口；physical绑定、既有LAN/split DNS优先级；正常stop、App失联、Core/helper异常及重启后receipt/临时DNS/route absence。PF_ROUTE与SCDynamicStore无公开CAS，不能把注入验证当成原子compare-delete实证。[Electron候选](../electron-auth-verification.md)隔离验证不代替受保护安装后的动态peer鉴权；fresh-only升级未齐。实验A仅无网络fixture，本轮未执行Core、utun、路由/DNS或root安装，也无新增真实系统操作授权；本票保持进行中。

跨 helper 重启恢复的代码边界（2026-11-04）：服务已允许仅有 `network.json` / `network-dns.json` 的状态进入既有只读 absence 恢复，完成后独立确认 receipts 已清除才报 off；`owner.json`、`session-work` 或仍持有的 Core 子进程存在时继续拒绝。旧 Core 的跨重启身份/退出证明、受保护工作目录与 `owner.json` 安全清退尚无实现，不能只列作实机证据缺口；当前不接管持久 PID、不据此 kill、不自动重启，仍保持 unknown，需要单独完成恢复设计与实现后才能关闭本票。


2026-11-04 固定候选检查点：最终集成已固定提交 `1ad5f06ad17495fd4e45cc1f94e54979bddf4842`；修复network-only receipts进入恢复hook的前置条件，并独立确认receipt消失才off。全部native fixture通过，不代替实机。跨helper重启Core owner/work清退仍是实现缺口，真实utun/双栈/LAN/split/stop/异常恢复仍缺实机证据。 见[结果与证据](../evidence/auth-observation-1ad5f06/RESULT.md)、[精确产物](../auth-observation-artifact.json)和[执行步骤](../auth-observation-experiment.md)。


2026-11-04 离线恢复增量完成：future format2 owner保存runtime配置hash/socket device+inode，重复明确ESRCH、网络absence及精确工作内容匹配后清退owner/work；存活/复用/无法观测PID、未知对象、旧format1有work全部保留，不kill/adopt。17聚焦场景及主会话全量native fixture通过，显式skip Core -t。此处替代上节“完全无跨重启Core owner清退实现”，但仅证明记录进程absence，不证明后代退出，真实mihomo/网络仍须实机；activation保持关。[验证记录](../evidence/owner-recovery-offline-20261104/RESULT.md)。


2026-11-05：既有format2 owner/work恢复保留证据边界：反复明确ESRCH只证明记录进程不存在，不能证明全部后代退出；未知工作文件仍保留。真实固定Core的私有控制/退出/工作目录行为先由[普通UID nonTUN实验](../core-control-experiment.md)验证。生产网络预检新增拒绝已有default REJECT/BLACKHOLE，防止新split-default绕过管理员阻断路由；现有dual-stack归属与同session恢复接线继续保留。跨helper重启对仍存在的网络项目前仅保守阻塞/absence恢复，不记作完整异常恢复已交付。真实utun、LAN/split DNS、双栈路由及停止后的恢复尚未运行。


2026-11-05 已授权639c64f普通UID真实Core normal实际失败：Core控制ready前自行exit1、无信号，runner exit2；EOF按门禁未执行。准确Core/worker均ESRCH，guardian组空，owner/work/socket清退；仅固定Core副本及证据按失败策略保留。Core输出被旧候选丢弃，根因未知；下一最小修复为有界诊断日志并另冻候选，不重试原包。本轮授权结束。[实际结果](../evidence/core-control-execution-639c64f/RESULT.md)。


2026-11-05 离线源码核对证实v1.19.33 select会先初始化cache.db，再判断store-selected=false；本轮仅实验增加已reap后安全类型/owner/nlink/大小、稳定dev/inode/时间/内容hash的精确cache清退，未知/替换对象保留。生产root旧owner/work schema并未据此开放cache删除，继续列为其集成缺口。Unix controller不验证Bearer，私有目录和socket身份才是访问边界；并不宣称同UID隔离。

2026-11-05 新候选8ee323a仅运行一次normal：Core原始错误 `Parse config error: yaml: found unknown escape character`，自行exit1，阶段private-version-readiness；EOF未执行，未改配置或重试。日志完整保留，Core/owner/work及组消失证据已记录；失败策略保留固定Core副本与诊断。授权结束，见 [执行记录](../evidence/core-control-execution-8ee323a/RESULT.md)。

2026-11-05 真实固定Core前置闭环通过：`98f1afbe6822999bab02723d62820a96c395571e`同epoch normal及EOF均runner0；version、mode/选择读回、stop ACK/owner EOF、SIGTERM→Core exit0与独立进程/整个运行目录消失通过。无root/TUN网络操作，不等于实际Electron退出/后代全退出或网络恢复；诊断保留。见 [证据](../evidence/core-control-execution-98f1afb/RESULT.md)。04/06/08继续开放。

2026-11-05 集成生产cache归属清退和owner断链状态通知：cache仅同held/reaped实例记录闭合receipt，未知/旧无receipt/改变对象保留；App断链进入既有队列独立inspect，unknown锁写，仅明确off再同步普通Core，不自动recover/start。完整native suite含固定Core-t通过，TS148focused和State/main类型检查通过，独立未参与实现review无阻塞。见 [集成证据](../evidence/production-integration-20261105/)。仍未证明真实root/TUN网络。


2026-11-05 已收敛macOS代理清理：仅回退本adapter已记录且当前仍匹配的写入，未知/第三方状态保留；TUN启动独立确认HTTP/HTTPS关闭，清代理失败仍停止普通Core。内存归属与非原子外部竞争限制明确保留。 见[集成证据](../evidence/upgrade-proxy-integration/RESULT.md)。


2026-11-05 有限独审确认跨helper恢复仍缺：活Core退出证明、仍存自有网络项的有限清理授权、reap前cache来源凭据。固定mihomo/sing-tun源码逐blob核对支持沿用现有launchd组策略，无需据当前证据增加监护层；源码审查不等于发布Core运行证据。下一步在既有生命周期实验中准备无TUN固定Core组清理验证，未授权/未执行真实job+Core强杀。普通Core normal/EOF和原helper仍活时的recover不得外推跨helper恢复已完成。


2026-11-05 `07b4325`冻结普通UID无TUN实验真实normal/EOF均通过；预创建0600空cache由固定Core原地初始化，同inode/owner/mode，准确停止Core exit0且独立进程/运行目录消失。仅证明此cache兼容性，不授权跨helper清退。见[真实证据](../evidence/cache-precreation-07b4325/RESULT.md)。另已准备d62675f fresh → 9763482升级的同helper/Core、不同封印App版本对，两源CI通过，实际升级未执行；[产物对](../evidence/app-only-upgrade-pair/RESULT.md)。


2026-11-05 `aaa85e82376cd7a99009730a06c6cae8f231b21a`生产有界诊断及共享capture已集成，双平台CI通过；新冻结执行器真实无TUN normal/EOF均exit0，私有接口读回、SIGTERM→Core exit0、独立Core/worker ESRCH、组空及整个运行目录消失均通过。EOF仅owner连接断开，不是实际Electron退出；root/Core组强杀、真实TUN双栈/LAN/分域DNS及异常网络恢复仍未通过。见[本次精确产物及执行证据](../evidence/production-diagnostics/core-execution-aaa85e8/RESULT.md)。

2026-11-05 恢复增量：精确归属 DNS 可在旧 Core/work 门阻塞时独立清退；总体仍保留 live/unknown Core 与 origin-only cache 拒绝，fresh 不造 held-stop 证明。owner/socket/DNS/routes 同步失败必须重试成功才可 off；同实例保留原始停止证据。双实现 agent＋独立 reviewer 无阻塞，隔离测试通过，主会话合并验证及新产物随后记录。见 [实现与证据边界](../evidence/recovery-durability-20261105/RESULT.md)。

2026-11-05 `4a8c7ac`组合native＋固定Core -t及真实normal→独立absence→EOF通过，两个Core均SIGTERM后exit0；同源码finite-session包已构建并独立离线解包核验，未安装/未TUN。CI原生通过但旧readiness TS用例API超时失败，现仅修测试前置条件并保留500ms/原断言，等待新CI。证据见[恢复验证](../evidence/recovery-durability-20261105/RESULT.md)。
