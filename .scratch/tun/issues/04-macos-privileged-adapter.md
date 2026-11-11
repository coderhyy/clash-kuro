# macOS 特权 helper

Status: ready-for-agent（740受限恢复及format3成功；App/job/Core退出；原fresh卸载因control.sock白名单缺口拒绝，安装/receipt完整保留，本窗口已停止）
Type: task
Blocked by: 原740 fresh卸载不接受服务遗留control.sock，须准备最小修复及另行授权；IPv4 ENETUNREACH未定因；运行期全局路由门仍待收敛。
Owner: macOS helper agent；主会话分配安装/认证文件范围并集成


## 最新实际收尾结果（2026-11-11）

已按批准的固定工具完成准确bootout、原writer/进程组缺席、生产恢复及持久format3，随后正常菜单Quit原App。原740 `--uninstall` 返回1：`unknown files preserved; uninstall refused`。只读目录确认唯一白名单外项为固定run目录的 `control.sock`；原fresh路径仅允许service.lock/auth.sock。检查早于安装删除、receipt改写及format3消费者校验，因此当前安装和receipt完整保留，未重试或删除socket。本次授权随停止终止，不包含新网络实验。

模型限制：此前真实临时安装模型未执行Serve或创建其control.sock；其旧consumer正例不覆盖此真实服务残留布局。现场socket的具体遗留退出分支尚无证据，不能推定worker超时。下一项仅准备严格归属、停止证明与锁保护下的固定socket清理兼容修复；当前不执行。IPv4出站错误仍独立未解释，本次恢复成功不是TUN功能验收通过。

## 当前状态（2026-11-11）

当前有效问题、原始错误及成功标准统一见 [08 当前阻塞表](08-tun-integration-acceptance.md#当前有效阻塞2026-11-11暂停新增-tun-重试)。恢复把全部系统路由回到旧基线误当作自有设置清除，现已确认；IPv4 出站错误是实际 Core 错误，尚未定因，不能以恢复修复代替转发验证。当前仅准备受限恢复，不启动 Core、不改网络；工具冻结与独审完成后集中申请授权。

## 历史交付状态（auto-route 决定后，以下不代表当前授权）

- 当前：`1252d09` 同提交完整 native／双平台 CI／实际包独审通过；实际启动在 DNS 写入后的 socket FD 复核拒绝。原会话自动退出、网络恢复、持久停止证明及精确卸载通过；未发受控流量。真实关闭 FD 机制已在无害 child 复现，现场 errno 仍未知。收敛为首次完整唯一发现、后续原目标 FD 双读及原 process/socket/interface 精确复核；不再把背景连接 FD 稳定性当作目标归属条件。IPv4 出站错误仍未解释。

- 最新真实结果：`3445848` 双平台 CI 42799632296 与实际包独审通过；fresh→ready→start 在 DNS post-write-admission 报 `DNS baseline changed`，未发送受控流量。原会话 exit0、网络恢复、四项持久证明、job/安装/receipt 精确清理通过。正在补具体 DNS 差异诊断，不据推测忽略 Global；[记录](../evidence/core-auto-route-global-20261106/RESULT.md)。

- 当前（2026-11-10）：0102 的双平台 CI 42204832391、包及窗口独审通过；实际 fresh→ready 后，固定 Core 建立双栈 utun/auto-route，随后在验证阶段报 `Core FD/socket/interface observation changed during verification`。原会话 SIGTERM/exit0、两路输出 EOF、网络恢复及持久证明的 childReaped/cleanupComplete/routesOff/dnsOff 四项均通过；App Quit 后准确 job、安装与 receipt 清理完成，无第三方冲突，完整批准基线精确恢复。没有受控流量成功，不计正常 TUN 验收通过。见[本轮记录](../evidence/core-auto-route-global-20261106/RESULT.md)。

- 历史准备：`acf5bee` 已完成唯一 held utun 稳定投影、旧 RED／新 GREEN 与独审；`78e4b89` 完整本地 native 和 macOS CI 通过。CI 42797078504 的 Windows desktop 测试通过，但隔离 helper 在失败报告日志路径未返回前达到原 2200ms 截止，stdout 缺少 shutdown；此 Windows 阻塞已由上述 3445848 修复及 CI 解除。0102 的具体变化字段仍未捕获，不将源码推断写为实测根因。

- 上轮清理与测试边界：22b 已在本轮准确卸载，原安装基线保留；仅 Apple awdl/llw link-local 旋转经独审采用新 stop-only 快照，未改第三方配置。0102 沙箱外完整 native 与 UID501 单 socket/bind 检查通过；旧 8.156s native socket 创建/bind 断言失败及缺失 errno 仍保留，不称超时或已定位原因。

- 历史（27a）：实机已取证，lower IPv4 `/1` 仅多合法 `RTF_GLOBAL`，准确网关/接口/范围一致；窄修复及真实样本回归见[记录](../evidence/core-auto-route-global-20261106/RESULT.md)。失败恢复和精确卸载完成；新候选正常流量仍待验证。USB/无关接口变化保留为后续兼容性验收，不定义为最终产品全量基线锁定。

- 历史（c7da1ba）：[首轮实机](../evidence/core-auto-route-live-c7da1ba-20261106/RESULT.md)。实际 App fresh→ready 通过，Core 建立双栈 utun6；路由 gateway/interface/flags 核验拒绝，SIGTERM exit0 后完整恢复、持久停止证明和精确卸载通过。尚未进行测试流量，不计正常启停通过。下一步仅补实际失败路由与预期元组诊断，不放宽门禁。

- 新增证据：[auto-route 组合结果](../evidence/core-auto-route-20261106/RESULT.md)。手工 writer 已删除；fresh/start/stop 与部分路由启动失败恢复八条生产链通过（模拟系统后端），固定 Core -t 通过；尚无新实机流量结论。
- 负责范围沿用本票；04 移除手工 writer、保留鉴权/监督，06 接入固定配置与只读网络生命周期，08 负责生产组合回归、独审/CI 和同范围真实正常启停。
- Blocked by：当前 DNS 具体差异定位、相关回归独审及同版本新候选；不以异常恢复全部完成阻塞首次正常启停。
- 验收：fresh→ready→start→stop、启动失败恢复；真实流量经过本会话 Core/utun、停止后网络恢复和持久证明、准确卸载。源码支持与模拟测试不代替实机。
- Core 独占路由写入，helper DNS 保持；旧账本只允许缺席退役，未知不删。持续正常窗口授权有效，管理员弹窗由维护者处理；异常注入/升级另行安排。

以下为保留的历史记录，旧“建议/暂停”状态已由本节替代。

## 路线复核结论（2026-11-06）

没有固定版本证据证明已批准需求必须由helper手写PF_ROUTE；推荐仅将路由交回固定Core auto-route，保留鉴权、受保护安装、准确Core监督/互斥、原Profile及现helper DNS。需把host2/split4写账本改为有限Core计划与held-utun只读证明，停止后仍独立核对缺席，未知不删；不能只翻布尔值。固定源码依据、最小落点与验收边界集中在[规格“路由执行方复核”](../spec.md)。

本次ACK根因是RTM_NEWMADDR短通知被误判；局部补丁离线RED/GREEN及独审通过但未部署。另有LLINFO精确读回不符及未验证网络行为，不能说仅剩一个局部问题。按维护者要求暂停新增网络重试，上一轮已完整恢复/卸载；不新增票或通用网络框架。

## 当前状态（2026-11-06，e2addf7实机）

- e2addf7实机：IPv6 host ADD188字节完整写出，先读到64字节/type0x0f通知并被当短ACK拒绝；未读匹配ACK，目标路由实际存在。Core退出/网络恢复/持久证明及精确卸载全部通过。[具体证据](../evidence/route-ack-diagnostic-20261106/candidate-e2addf7/REAL-WINDOW.md)。仅修复通知分类，不放宽ACK或归属检查。
- 实际安装App鉴权恢复ready/off、固定Core及双族utun创建通过；路由写入ACK失败，尚无on或测试流量通过证据。[实机及清理证据](../evidence/internal-dns-probe-20261106/candidate-95a8808/REAL-WINDOW.md)。
- 原会话Core SIGTERM/exit0、网络恢复与持久停止证明通过；job/安装/socket/receipt准确清除。DNS192.168.0.1、系统代理及生产稳定路由基线匹配，Profile未修改。
- 当前仅定位真实ACK失败；不放宽归属或回执检查。持续正常窗口有效，异常恢复/升级验收另排。隔离普通子进程超时仍独立未解释。

## 前轮状态（2026-11-06，11902实机证据与路由修复）

- 11902实际App鉴权ready及双族utun创建通过，拒绝的是本会话utun6的 `ff00::%25/8`，flags `0x01800101`。Core正常终止、网络恢复、停止证明及准确卸载通过；job/receipt/安装与进程缺席。[实际结果](../evidence/7c351-route-rejection-20261106/11902-real-result.md)。
- 固定XNU与旧接口基线支持该路由属于系统IPv6多播伴生项。最小识别仅接受held接口/索引、精确三种形状/flags及新鲜唯一link-local网关；不增加删除权。独立修复四条split路由的精确PRCLONING读回，ADD/DELETE请求不变；两处RED/GREEN与独审通过。[证据](../evidence/utun-multicast-20261106/implementation.md)。
- `dd3f0d4`双平台CI/包独审通过后实机确认内部IPv4 DNS在send/1ms返回EHOSTUNREACH65，尚未发公网流量；准确Core退出、网络基线/持久停止证明、job/安装/receipt清理通过。[实机证据](../evidence/internal-dns-probe-20261106/candidate-dd3f/REAL-WINDOW.md)。
- 单账本host2→双族probe→exact6→系统DNS修复已集成并独审；不改Profile/DNS模式/时限。旧协调器同P2P组合明确RED；完整生产组合GREEN/新候选冻结进行中，旧4记录恢复兼容。
- 尚无成功on状态或TUN流量证据；MATCH,DIRECT不能证明代理节点转发，外网IPv6未验证。持续正常窗口授权有效，异常恢复/升级不混入本次范围。

## 历史准备状态（保留原时间和产物边界）

### 当时状态（2026-11-05，eb4beec）

- **持续窗口已授权，c138安装前只读预检**：实际生产route/interface/config通过，Global DNS系统元数据被拒；未安装/未修改网络，前后基线一致。[现场记录](../evidence/c138-readonly-preflight-20261106/RESULT.md)。修复回归与同版本只读预检继续，无需逐包确认；未知归属/恢复失败/扩大范围仍停下询问。

- **最新可验收候选**：`c138652131a6bf9035225b0ff93b74b9c360b21d`，包SHA256 `f3b7fbdbb3fc7f49da44b9006418fc9cbc24cb6a1ebcd503f9adf0fed2c9f8d8`；CI42148141090双平台成功、干净源码构建及实际包离线独审通过。尚未安装/启动；[冻结](../evidence/darwin-route-parser-20261106/freeze-c138.json)及[新正常窗口](../evidence/darwin-route-parser-20261106/NEXT-WINDOW.md)。

- **2026-11-06 最新真实结果**：eb4 fresh安装及实际App身份核验通过，但自动恢复被 `routes: invalid route mask` 阻止；未启动Core/TUN。准确卸载、job/receipt/进程缺席，网络与新基线一致。窗口结束；[现场证据与下一修复](../evidence/eb4-tun-window-20261106/RESULT.md)。以下eb4准备记录仅为历史，不再重试旧包。
- 后续离线修复：Darwin压缩mask与LOCAL/HOST IPv6 zone兼容已集成；原decoder在实际恢复链blocked，新decoder7/7组合通过，标准原生与固定Core-t通过。[整合记录](../evidence/darwin-route-parser-20261106/INTEGRATED.md)。

- **当前候选**：源码 `eb4beec05283c60dd99715bf2b702a58c0fb9d44`，包 `kuro-tun-finite-session-0.1.0-arm64-eb4beec05283.pkg`，SHA256 `78cc71471ca1674e19caf4630798878330b452fb5b6ef2894fbdbda0fbc717d7`。[CI 42057942407](https://github.com/coderhyy/clash-kuro/actions/runs/42057942407) 双平台成功；标准原生测试含真实固定 Core `-t`、7条准入组合链通过。App 未运行；**独立离线包审查通过**，实际展开文件与本次构建及源码字节核对一致；[证据](../evidence/production-admission-20261105/offline-package-eb4/RESULT.md)。
- **实现与门禁**：初始 `blocked/off` 必须经实际 App 鉴权恢复并独立读回 `ready/off`；held 停止证明、同安装 format3 恢复证明和普通 Core socket 就绪权限修复已集成。metadata 的 `disabled=true` / `serviceAutoStart=false` 表示安装时不自动启动服务；finite `startAvailable=true` / `productionActivation=true` 表示候选具备有限启动能力，实际运行仍需通过鉴权、恢复及网络读回门禁。
- **下一窗口**：按 [NEXT-WINDOW](../evidence/production-admission-20261105/NEXT-WINDOW.md) 串行执行 fresh → 实际 App 鉴权/recover → 基线一致才使用已确认 router Profile → TUN 正常启停 → Core 流量/utun 与停止证明 → Quit/准确卸载，预计25–40分钟。第三方工具由用户关闭；基线变动不静默改 Profile。外网 IPv6、helper 强杀、TUN-on App 退出及实际升级不属于此窗口。
- 49f7dd6 窗口未启动 Core/TUN且已清理；它是历史失败证据，不代表当前包已执行。当前验收仍未完成，下列历史记录保留时间与产物边界。

## 历史记录（不作为 eb4 当前完成状态）

- **最新真实窗口**：49f7dd6 fresh安装、实际App字节核验及helper启动成功，但生产初始blocked/off与客户端off短路导致无法ready；未运行Core/TUN。已正常退出App、卸载准确job/安装/receipt，代理/DNS/双族路由与新基线一致。[结果](../evidence/first-tun-window-20261105/RESULT.md)。窗口已结束；修复正在隔离实现并独立审查，不重试原包。
- 真实held停止证明在owner清退前耐久保存的四文件修复已通过独立审查并集成；完整写出前崩溃仍不能合成held证明。它不在49包内，也不算真实TUN恢复通过。以下保留前一阶段状态。

- `3728bc7` CI 已通过；生产候选 `49f7dd6e610e18b2a4c59c85b92f2c29045b95d4` 的 CI 亦通过：https://github.com/coderhyy/clash-kuro/actions/runs/42017796326 。标准原生测试、固定 Core 普通用户 `-t`、硬化 App 和 fresh finite-session 包构建完成，未安装或运行新候选。
- 已接通真实安装版本/manifest/receipt/Core/helper、会话与工作目录身份绑定；origin-only 缓存通过重复稳定快照、文件同步与持久检查点恢复，拒绝跨安装或未知对象。不凭旧 PID、空组或实验通过扩大删除权。[实现证据](../evidence/installed-recovery-20261105/RESULT.md)。
- **首次正常启停**：产物已冻结，独立包审查通过；仍需现场冲突解除后的新 baseline、Profile 核对和首次 TUN 窗口授权。现有非本应用 utun 路由覆盖固定池及 split-default，当前会被启动前检查拒绝；不自动关闭第三方工具。IPv4-only 上游可用，外网 IPv6 验收需要相应环境。
- **异常恢复/正式交付**：真实 helper 强杀后网络与缓存恢复、崩溃后的停止证明及卸载/升级仍未验收；真实 held-stop 证明写入与 owner 清退间的持久性修复独立推进，不作为首次正常启停的笼统前置。
- root697 实验已完成且授权结束，结果只证明既定无网络监督场景；不重复。历史记录与证据保留，旧包/旧待执行状态不代表当前状态。详细边界见 [首次窗口准备](../evidence/first-tun-readiness-20261105/READINESS.md)。

## 负责范围

管理员安装传统 LaunchDaemon + 小型 helper：受保护安装、升级卸载、peer 认证与有限 broker、准确 Core owner、自有网络归属和清理。合并 [11 安装事务](11-protected-install-transaction.md) 与 [12 认证/broker](12-peer-authentication-and-broker.md)，保留其原型与证据；不改 State/UI。依据 [安全方案](../macos-helper-security.md)、ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)，不依赖付费会员，不使用 setuid Core、任意 root 命令/路径、关闭 SIP 或全局 Gatekeeper。

安装事务与认证/协议实验可并行；生产 pin 必须来自受保护安装记录，不能信请求方自报 PID/hash 或仅 UID。与 [06](06-state-and-ui.md) 的机制无关契约/测试并行，生产接入再汇合。

## 验收标准

- 安装事务：固定目标和精确产物，拒绝目录逃逸、symlink、可写祖先、setuid/setgid 与篡改；管理员批准字节绑定实际消费并在受保护 staging 复核。升级先确认旧 writer 停止；取消/部分失败可观察，只删清单确认的自有组件，未知时保留恢复能力。
- 认证与 broker：内核 peer 身份结合完整 Electron 资源/启动/注入边界与受保护 pin；有限操作逐项校验参数、大小、版本、会话和重放，拒绝未知/额外字段。root Core 控制 socket 保持私有，不开放通用 HTTP/configs/provider/升级绕过入口。
- 生命周期：单一准确 owner；安装不启动代理，App 退出/客户端消失有界停止 TUN/Core，仅恢复本应用网络。正常重开先检查残留，保持 TUN 关闭，用户手动开启；归属或清理未知则关门，异常不重启 TUN，卸载先清理再移组件。
- 网络工作清单：IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；明确 IPv4/IPv6/DNS 归属和第三方冲突。双栈固定模板/无高级 UI/技术参数选定已批准，候选和版本证据见 [spec](../spec.md#固定版本事实与技术候选)；root 有限 schema 验证通过前不接入模板，候选不等于网络通过；保持LAN/split DNS、不新增DNS供应商，DNS缺失/不支持具体拒绝；显式DIRECT与无kill switch/路由消失可能直连已由 [ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 批准。不静默关闭IPv6，不宣称全流量/防泄漏。
- 隔离/负例、Core/平台回归、typecheck 与打包通过；原型通过不等于生产认证/真实 root/launchd/网络验收，后者交 [08](08-tun-integration-acceptance.md) 串行执行。

## 最小闭环设计记录（2026-11-04，按最新用户边界收敛）

**推荐：安装时授权本 App 使用有限 TUN 能力，正常使用仍在 App 内单次点击；暂不增加原生确认组件。** 上一版“每次确认窗口＋会话组件”未获批准，已撤回作为前置依赖。用户不要求完全抵御已被攻陷的用户会话，但任意本地程序直接冒充 App、常规启动参数/环境注入、root 任意执行与文件访问仍须阻断。下面是选择的实现方向，不是生产鉴权已经通过。

**用户已批准上述安装级有限授权与单次点击方案。** 本轮仅实验 A 获真实系统操作授权；实际 Electron 鉴权验证通过前保留生产拒绝门，未授权运行 Core 或任何网络实验。

### 威胁、现有证据与最小方案

| 必须覆盖 | 已有机制／必须补齐 |
| --- | --- |
| 其他本地程序直接连接、伪造 PID/路径/hash、重放会话或转交 FD 延续会话 | 内核 audit token/PID version、动态 SecCode、管理员安装的完整 App pin 与保护路径；同 UID 不放行；原实例存活、单会话、序号及 lease。已有 peer/FD 负例只证明基础原语 |
| 篡改 App/ASAR/Core 或借可信 App 的公开环境/调试/代码加载入口发请求 | 完整 seal、受保护代码与资源、固定 Core pin；现有 Node/inspect fuses 和 ASAR 校验继续保留。候选为 Hardened Runtime＋仅必要的库校验例外，不允许 get-task-allow 或 allow-dyld-environment-variables；实际 Electron 的插件/动态库/Chromium 调试入口须审计与负例验证 |
| 恶意 Profile 让 root 执行任意程序、加载用户路径或写任意文件 | helper 独立闭合 schema、固定 Core/工作目录、有限控制操作；禁止任意命令、可执行路径和通用 Core controller。语法检查不代替权限验证 |
| App 消失、helper 崩溃后残留或误删第三方网络 | 准确直接子进程、原客户端生命绑定、持久自有网络记录、读回与比较恢复；未知拒绝开启，不能按持久化 PID 盲杀 |

首版不承诺抵御恶意 root、已取得 App 主进程任意代码执行的漏洞或已获用户授权的 Accessibility 自动化。该限制不豁免上表中的公开注入入口，也不允许被攻陷客户端越过 helper 的有限 root 操作边界。

**安装授权为什么可以承担长期授权：** 授权对象可以是“管理员批准的精确 App 版本＋固定有限操作”，无需每次重新证明用户点击。用户已选择此体验。helper 必须验证当前调用者确实属于这些受保护字节，并自己校验每个请求；只安装 helper、只验 UID/CDHash 或只靠 schema 都不够。安装/升级写入 App pin、更新前停止旧会话，旧实例/旧 pin 不再获新会话；无需新增共享 secret 或常驻转发器。

**原生窗口增加的只是独立的逐次用户意图确认。** 如果组件接受任意程序请求后自动转发，它确实是 confused deputy；只有不可自动跳过的确认与不可变请求绑定才能补上该保证。它不替代 helper 鉴权、配置校验或残留恢复，也无法保证抵御已授权 UI 自动化。当前范围没有要求这项逐次确认，因此没有证据证明它不可替代。

**上一轮结论修正：** 现有 `check-adhoc-library-validation.mjs` 证明严格库校验拒绝分别 ad-hoc 签名的动态库，不证明 “ad-hoc Electron 必须有另一个授权 App”。应先核验 Hardened Runtime 下的最小库校验例外与其余注入防护，不把“关闭库校验”误等同于“所有运行时保护关闭”，也不直接认为此例外已安全。

本轮在同一脚本最小增补并实际验证：runtime＋disable-library-validation 能加载该 ad-hoc 库；没有 allow-dyld-environment-variables/get-task-allow 时，`DYLD_INSERT_LIBRARIES` constructor 注入负例未执行；去掉 runtime 的阳性对照确实执行。只运行普通用户临时 C loader，无 App、网络或服务操作。这推翻了“该库兼容障碍必然需要独立授权窗口”的推断，但没有验证 Electron 的所有加载路径，也不构成放行依据。

具体待封闭入口而非抽象“完全安全”：当前 BrowserWindow 未关闭生产 DevTools；Electron 45 本地类型文档说明默认开启。现有 Node inspect fuse 不证明 Chromium `remote-debugging-port/pipe` 已禁用；固定 Framework 包含这些参数，尚未实测可达性。若 CDP 可达，可通过 renderer 的 `window.kuro.run` 触发有限命令，helper 的进程身份不会把它与正常 UI 点击区分。需核对生产 DevTools/CDP、启动参数及可加载脚本/原生库路径；不把同 UID 外部调试默认为“会话已攻陷”而跳过。

一手代码证据：`apps/desktop/native/mac/kuro-tun-helper.m` 的 `Authorize` 当前拒绝库校验例外且末尾无条件拒绝；`client.json` 目前只有读取没有安装写入；`ProtectBundle` 对正常 framework 内部 symlink 的严格拒绝尚需改为受限解析并验证受保护目标。`electron-builder.yml` 当前仍为 hardenedRuntime:false；`verify-macos-app.cjs` 只验证静态 seal/fuses。`src/main/index.ts` 已限制窗口 IPC、导航与 packaged renderer 来源，但这些不证明完整运行时鉴权。**本轮不删除任何拒绝门，不把候选配置直接发成可用 TUN 包。**

落地顺序：先完成受保护 App 安装/pin 契约与实际 Electron 入口负例，再调整 `Authorize` 的精确允许策略；并行继续准确 owner、有限服务和网络恢复。若候选仍存在无需攻陷会话即可利用的代码加载入口，再集中给出具体绕过证据及可选代价；不默认恢复每次弹窗方案。

实验 A 期间并行完成[实际 Electron 产物离线核验](../electron-auth-verification.md)：现有 dist App seal/fuses 与 ASAR 摘要通过，但包内 15 个 Mach-O 均无 runtime flag，不能进入放行阶段。报告记录各产物独立摘要，未将 dist App 与 DMG/CI 包混用；下一步需构建并验证硬化候选的调试/代码加载负例和正常加载，测试入口须隔离现有用户数据并确保不启动 Core/触碰网络。所有动态项仍未执行。

### 三个结果与阻塞

| 结果 | 关键剩余条件 |
| --- | --- |
| 可信启动固定 Core、建立真实 TUN | 上述 App 信任链验证与安装接线、有限 Core 控制/并发 status、真实 utun 与双栈路由/DNS 就绪。当前 start 仍拒绝 |
| 正常停／App 断线，准确停止并确认自有清理 | 接通已有 direct-child/lease 原语；准确路由 journal、读回与冲突保留；真实 DNS/接口清理证据 |
| helper 强杀后识别恢复、不重开 | 实验 A 先验证 launchd 对无网络子进程行为；随后固定 Core 真实行为与跨重启网络恢复。实验 child 的自退出不得冒充 launchd 清理通过 |

### 独立实验 A

[源码、离线验证和执行说明](../prototypes/helper-lifecycle/README.md)。不依赖授权窗口方案，不运行 Core、不创建 TUN、不改变路由/DNS/登录项。补齐路径为：记录精确 epoch/PID/start-time/可执行文件身份，只读识别；残留 child 自行处理本次 epoch 的受保护停止标记，并有单调时钟寿命上限；不把观察 PID 转换为稍后 kill(pid)。观察窗口内组清理失败即记失败，恢复成功不能改写结果。

准备状态：**已具备用户授权后执行本轮有限实验的产物、命令和残留 child 恢复步骤，尚未执行系统实验。** 原生严格编译/self-test 与 8 项驱动隔离测试通过；主会话复核相同结果和最终摘要。review `/private/tmp/kuro-lifecycle-a-review`，binary SHA256 `6a9c665c6af2dc3428db026d61ad5b734577afff809e00dba08ed968173798ef`；driver SHA256 `4b1c05025816da23ffe702eaaaa7598c12d4663c0c8836c608f059479ee64953`。仅使用 README 当前 epoch `668F8E2A-414B-476C-A648-1DC49D24788B`，旧 review 不用。

流程为精确安装→启动测试 job→30 秒内按 job 强杀→1/5 秒只读观察→epoch marker/TTL 恢复→确认两进程与 job 不存在再移除精确文件，通常 3–5 分钟；TTL 兜底约 5–7 分钟清醒时间。原生观察器使用与证据相同的时钟判定观察窗口，不混用 Python 时基。脚本删除前输出证据，用户保存终端即可。部分安装/缺 evidence/身份未知仍保留现场并阻塞，不能称完备自动回滚安装器。

真实安装、服务变更和强杀均仍等“开始”。实验只回答此 fixture 的进程生命周期，不能证明 Core 或生产网络清理。Backup／登录项不因此重打包。完整命令、产物摘要、影响范围、耗时与停止条件以实验 README 为准。

## Comments

### 集成前检查点（历史保留，当前状态以上方为准）

**本轮集成：** 新 root 完整窗口已接入旧四文件精确退役/证据归档、新候选构建、normal→kill、独立失败恢复和成功清理；主会话集成验证21项driver＋9项archive通过，独立审查确认源码一致。[集成证据](../evidence/next-root-window-20261105/RESULT.md)。未执行新root窗口；生产跨helper writer证明与真实TUN仍未完成。

诊断fixture取证补丁已集成，未放宽1秒期限或断言；偶发启动失败仍在定位。32af9dd的CI已通过，不据此宣布稳定性问题已解决。

**最新真实窗口：** root normal 的 Core 私有接口、SIGTERM exit0及 native清退通过，但观察器把布尔输出为数字1，严格驱动拒绝；kill未执行。原retire同门失败后，单独获准的独立恢复入口已bootout；宿主独立读回job不存在。四安装文件及受限证据保留，不重跑normal/kill。[结果与准确残留](../evidence/root-core-window-20261105/RESULT.md)。

安装鉴权、有限控制、held-child 停止证明、升级事务及精确卸载已有实现/隔离证据；真实普通用户 Core normal/EOF 已通过。fresh 安装/卸载历史验收通过，不代表升级或运行后卸载通过。跨 helper 精确 DNS 可独立清理；origin-only cache 和未知 writer 继续保留，不能报告完整恢复。

本轮已补齐旧组非空/不可完整观察时的恢复拒绝及升级最后回执fsync重试，两项均通过独立审查和组合隔离测试；不把空组当writer证明，修复尚未进入旧包。[增量证据](../evidence/recovery-followup-20261105/RESULT.md)。

root 无网络窗口的正常收尾采用固定四文件清理：成功 normal/kill 且 job、准确进程/完整组确认退出后移除专用 binary/plist/两份 Core；批准、原始诊断、身份/观察记录及 kill 后 owner/work/cache 保留。部分安装失败或未知身份不套用成功清理；不把保留证据目录称为完整卸载。具体入口、复核和授权范围见 08。

诊断fixture的hash相关断言输入已定位并窄修（不改生产脱敏/断言），但主会话独立启动fixture仍有未定位失败，不能据观测版单次通过声称稳定性或完整CI已通过。[准确证据边界](../evidence/service-diagnostic-ci-20261105/RESULT.md)。

精确产物与证据见 [当前候选](../evidence/finite-candidate-4abee24/RESULT.md)。人工操作集中见 [08 当前窗口](08-tun-integration-acceptance.md#当前人工窗口与前置条件)。历史记录保留，不将旧拒绝门或旧授权描述当作当前状态。


2026-11-04 实验 A 实证：获用户明确授权后执行固定 epoch，强杀测试 supervisor 后约 1s/5s 两进程均 absent，job runs=1 且未重启；没有停止标记/到期退出证据，判定本 fixture 的 launchd 组清理通过。随后精确 bootout/清单移除成功，最终独立只读核验 job 与三个安装目标均不存在。共享父目录及用户态 review/build 留存。完整[结果和原始证据](../prototypes/helper-lifecycle/results-668F8E2A/RESULT.md)。该结果不证明 mihomo 不脱组或网络清理；生产仍需固定 Core/接口行为及路由/DNS恢复实证，另行准备和授权，不能沿用 A 授权。安装级 App 鉴权离线核验并行推进，start 继续拒绝。

2026-11-04：11/12 已归并，本票未实现完成。既有安装目录模型 16/16（setuid 为元数据模拟）、C 身份原语两分支是有限证据，原记录见历史票。源码由实施 agent 交付，最终命令、产物与验证证据待回填；没有真实系统授权。

2026-11-04 后续：离线产物准备器已接入 `bun run --cwd apps/desktop prepare-macos-helper darwin-arm64`。它从固定锁/缓存验压缩包，解压后与现有 Core 资源逐字节比较，另验 helper pin、Mach-O 头部/架构/权限及路径，生成禁用 plist 与 executable hash manifest；不安装、不执行 helper。新增20项（含arm64/x64）+fetch-core既有3项测试通过，独立复核通过。真实资源执行按预期exit1：原生 helper 与 helper.lock 尚缺，不生成可安装产物。头部检查不证明实际可加载性，临时构建目录检查不证明 root/ACL/同UID竞态安全；安装与运行入口仍等相应实现与验证。

2026-11-04 本轮检查点：原生 helper/socket 服务与桌面客户端已有生产源码，仍明确拒绝未完成的完整 Electron 启动/注入可信证明、root Core 配置验证及未知网络清理；上述“原生源码尚缺”是较早检查点，不是当前缺文件。具体剩余门为可信链、固定模板/root schema/有限 broker、准确 owner 与两族路由/DNS journal/readback/recovery。双栈已批准，参数可技术选型，不等09或IPv6批准；root schema先行，模板不在本轮文档中实现。主会话阶段State151/desktop359+17skip/typecheck绿不证明native安全或网络成功，后续native修复/build与最终证据待回填。

2026-11-04 原生切片集成：Objective-C helper、固定版本1 socket协议、audit-token/SecCode认证检查和完整可信链拒绝门已落生产源码；start仍硬拒绝，未开放root Core。build --test在普通用户隔离目录实际通过，并生成ad-hoc hardened helper及strict codesign校验。打包前只读native preflight验证固定目标祖先/root/ACL/symlink与service absence；固定--serve参数已对齐。卸载使用独立受保护恢复入口与hash绑定批准记录，测试覆盖主installer删除、部分payload缺失、State已清理、坏record拒绝、末尾仅恢复入口残留；未知文件保留。prepare20+package8+fetch3测试通过。独立review发现的参数、前置路径验证和恢复入口问题已修复并复核。

本切片不是04完成：包为fresh-only、disabled service候选，升级仍拒绝未知或已有安装；完整Electron启动/注入可信链、受限Core配置/broker、准确owner/客户端消失lease、双栈网络journal与恢复尚未实现。真实Installer/root/launchd未验证。禁用包安装后没有服务socket，App保守显示unknown并禁止普通网络写入；因此不提供给用户作为当前TUN可用验收包，也不与Backup/登录项验收混装。

2026-11-04 受限会话切片：生产新增独立root闭合schema/JSON候选、audit-token+CDHash存活检查、direct-child监督与lease、SCDynamicStore自有临时DNS记录组件。原生全套普通用户隔离测试通过；候选经固定Core v1.19.33的真实-t通过，修复JSON/YAML转义兼容性并留回归；CI先fetch固定Core并要求该用例不得跳过。客户端收到完整V2配置，不再通过V1启动。固定plist显式AbandonProcessGroup:false，残留检查覆盖network-dns.json。

这仍不是04交付完成：真实open拒绝；完整可信授权、有限Core控制broker、长连接与并发status服务、helper SIGKILL后的组约束、准确utun/双栈路由恢复未齐；DNS组件只有自有key级证据。安装仍fresh-only且服务禁用，升级未补齐。App加入fuses/ASAR seal离线检查，但ad-hoc hardened动态库实验验证了Team ID兼容障碍，不能将静态验包当完整调用者鉴权；详见安全方案新增实验证据。


## 当前检查点：service / routes / client pin（2026-11-04）

本节覆盖上文“service串行”“broker/路由组件尚未实现”“client pin只有读取”“Framework链接一律拒绝”“Electron尚无硬化动态证据”等旧检查点；历史产物和实验结果仍仅适用于原对象。当前已有单owner的V2服务、并发独立status worker、私有Core socket及有限mode/select控制；普通用户无网络child fixture覆盖启动拒绝、lease/stop、状态读回与失败保留。路由组件已有有界PF_ROUTE编解码/后端、双栈精确条目、journal与持久确认、独立readback和保守compare-delete；wire/注入测试通过，没有调用真实PF_ROUTE/sysctl。原Core已退出且接口消失只允许确认记录路由不存在，跨helper重启或归属未知保留现场。四条`/1`仅为离线计划候选，不证明LAN/split路由、egress或全流量覆盖。

安装manifest可选完整client pin现已接Install/Uninstall；固定目标为`/Library/Application Support/Clash Kuro/Client/Clash Kuro.app`，允许受限、受保护的Framework内部相对链接；卸载只移精确批准记录，保留App。临时普通用户fixture已验证签名/篡改及pin落盘清理；打包显式限制主App与ChildBundles的relocation/version skip。fresh-only仍拒绝已有/部分安装，升级、安装失败恢复与管理员精确包消费绑定尚未完成真实验证。

[冻结Electron候选](../electron-auth-verification.md)已通过15个Mach-O的runtime/最小entitlement、seal/ASAR/fuse核验，14/14隔离启动/UI/IPC与环境/调试负例，以及3/3离线篡改/重签比较；不使用真实Platform/Core/helper/network。它不等于安装后动态鉴权，也不穷尽所有Chromium/DYLD入口。`Authorize`最终拒绝仍保留，生产`ready`/`applyNetwork`/`recoverNetwork` hooks均拒绝；DNS激活须实际route receipts、live owner和内部resolver probe，真实PF_ROUTE竞争/flags、LAN/split DNS/AAAA与回退、接口变化、异常恢复未验。实验A只证明其无网络fixture的launchd组清理，不证明mihomo或网络行为。本票未完成；本轮最终组合测试/精确产物摘要由主会话另填。

2026-11-04 最终组合检查点：[精确产物、摘要、离线解包证据与下一实验前置](../evidence/electron-candidate-20261104/RESULT.md)。硬化 App 的隔离功能/入口负例已测，最终 native 构建通过；启动取消与 stop ACK/status 两个并发窗口均修复并通过屏障回归。内嵌 App 禁用包 SHA256 `c3cdf1af1f5bd9f7745171b55958c78589c564db53152de69e8d9f4ed6a5b6bf`；9 个 bundle 固定位置/严格标识、预期 root BOM、展开身份与摘要已复核。未安装，仍不能执行真实 TUN；不要求用户开始。完整鉴权观察入口、生产网络接线、升级及真实系统验收仍未完成。

2026-11-04 下一检查点（覆盖上述未提交/观察入口缺失状态）：[有限鉴权实验](../auth-observation-experiment.md)已实现共享生产AuthorizeClientAt的只读观察、Electron auth-only入口、候选封印限制、fresh回执/精确inventory与部分安装恢复。真实签名live fixture正例与身份/资源变化负例通过，不再要求穷尽Chromium/DYLD。生产激活门独立保留；身份成功无Core/network能力。生产网络hooks与每秒归属确认已接通，真实Core/utun/路由/DNS证明尚未取得。主会话将固定源码提交后构建候选，实验仍须用户另行授权。


2026-11-04 固定候选检查点：有限 auth-only 实验候选已从干净提交 `1ad5f06ad17495fd4e45cc1f94e54979bddf4842` 构建，App/native/pkg同提交，实际Electron隔离14项、desktop446/16skip、native与typecheck通过。修复实际/private/tmp空ACL误拒绝并有先失败后通过回归；fresh回执/失败恢复/准确卸载已普通UID验证，实际Installer仍待本次授权。有限动态正例/身份负例必须通过同一生产AuthorizeClientAt；请求协议错误或超时不算身份拒绝。完整升级保留未完成，不阻塞此fresh实验。 见[结果与证据](../evidence/auth-observation-1ad5f06/RESULT.md)、[精确产物](../auth-observation-artifact.json)和[执行步骤](../auth-observation-experiment.md)。


2026-11-04 授权实验实际结果：指定1ad5f06/7bf9ce2b观察包已管理员尝试fresh安装，preinstall因本机/private/var/run=root:daemon0775被严格父链检查拒绝，安装退出1。实际Electron正例、动态负例、非观察操作测试均未进入；不能标通过。固定安装目标、socket/身份/回执、job和Installer receipt均无残留，本次Installer临时目录已消失，未执行额外删除或kill。授权已随实验和清理核对结束。详见[实验证据](../evidence/auth-execution-1ad5f06/RESULT.md)。后续固定socket目录须迁到严格保护祖先并统一客户端/卸载；不放宽父链或chmod系统目录。新包另需授权。


2026-11-04 socket路径修复：固定run目录迁到`/Library/PrivilegedHelperTools/dev.kuro.tun-run`，native fresh/observer/service lock/恢复/卸载均从同一个SocketDirectory派生，TS auth/control共享路径和完整祖先检查，脚本共用authEndpoint并有跨语言一致性回归。旧run仅作残留冲突检测，不连接/迁移/删除，不改系统目录权限。保护路径诊断附具体path与owner/mode/symlink/ACL原因；public祖先需other-execute，不可搜索时拒绝。新包须另获授权；测试和摘要见后续固定候选记录。06仅记录Core不存在的证据边界不变。


2026-11-04 新鉴权候选已冻结：实现e8ae1dc394ce59d447051d2a3fff4fdcd51a6492，包SHA256 `98562290ab91af7372cf1d7d2c8d2145e6e1f0453adb6c1203710c3d319a6177`；新受保护socket路径全链同步，native全套/desktop485+16skip/typecheck/实际隔离Electron14通过，解包验证通过。实际root安装与动态auth仍未执行；等新授权，不沿用1ad实验授权。[结果](../evidence/auth-observation-e8ae1dc/RESULT.md)、[产物](../auth-observation-artifact.json)、[步骤](../auth-observation-experiment.md)。


2026-11-04 e8ae1dc/98562290有限鉴权实验实际通过且清理完成：root fresh安装和App seal/inventory/client/fresh身份核验通过；实际安装Electron authenticated=true；重签App明确身份拒绝、外部Node硬化拒绝；正例后start/open/stop/recover/exec全部拒绝。observer正常exit0，准确卸载与receipt forget exit0，最终路径/进程/socket/身份回执/job/receipt无残留；本次授权结束。[实际证据](../evidence/auth-execution-e8ae1dc/RESULT.md)。不是Core/TUN/网络/升级验收，不开放生产门。


2026-11-05 下一交付收敛：已通过的auth-only安装实验不重跑，原包继续禁止会话操作。生产动态AuthorizeClient之后增加安装绑定的有限session准入：显式boolean activation、完成事务、执行helper/manifest/client/inventory/fresh管理员receipt、实际plist及恢复入口必须相互匹配。首次Core resume前须持久废止neverStarted；运行过后不能再使用原fresh-only卸载证明。准备器仍默认activationAllowed=false，不提供已获授权的root启动候选。运行后准确卸载、完整升级与root组合实验证据仍未完成。

先准备[普通UID固定Core实验](../core-control-experiment.md)，复用实际有限Unix控制与准确direct-child监督，独立编译nonTUN模板；不伪造生产utun ready。normal→EOF按证据顺序执行，helper强杀不在本次实验入口。新实验须冻结源码/产物并获新授权，普通UID通过也不等于root App/helper组合通过。


2026-11-05 已授权639c64f普通UID真实Core normal实际失败：Core控制ready前自行exit1、无信号，runner exit2；EOF按门禁未执行。准确Core/worker均ESRCH，guardian组空，owner/work/socket清退；仅固定Core副本及证据按失败策略保留。Core输出被旧候选丢弃，根因未知；下一最小修复为有界诊断日志并另冻候选，不重试原包。本轮授权结束。[实际结果](../evidence/core-control-execution-639c64f/RESULT.md)。


2026-11-05 诊断修复沿用本票：普通UID候选必须有独立受限证据目录、每流64KiB输出上限及持续drain、会话secret脱敏、启动元数据和真实termination；缺失有效capture管道拒绝spawn。失败先持久化诊断再清runtime，错误分开记录。生产helper宏外stdio未在本轮改动，后续root真实实验候选也必须满足诊断保留要求，不得以丢弃全部输出进入验收。

2026-11-05 新候选8ee323a仅运行一次normal：Core原始错误 `Parse config error: yaml: found unknown escape character`，自行exit1，阶段private-version-readiness；EOF未执行，未改配置或重试。日志完整保留，Core/owner/work及组消失证据已记录；失败策略保留固定Core副本与诊断。授权结束，见 [执行记录](../evidence/core-control-execution-8ee323a/RESULT.md)。

2026-11-05 真实固定Core前置闭环通过：`98f1afbe6822999bab02723d62820a96c395571e`同epoch normal及EOF均runner0；version、mode/选择读回、stop ACK/owner EOF、SIGTERM→Core exit0与独立进程/整个运行目录消失通过。无root/TUN网络操作，不等于实际Electron退出/后代全退出或网络恢复；诊断保留。见 [证据](../evidence/core-control-execution-98f1afb/RESULT.md)。04/06/08继续开放。

2026-11-05 已实现same-held停止证明与运行后准确卸载，beforeStart/resume持久撤销旧proof，neverStarted=false不回真；已集成finite-session源码候选构建/严格同commit身份打包及固定测试数据隔离，auth-only不扩权。独立审查无阻塞，全native含固定Core-t通过。真实root/TUN仍未验，升级事务未实现；[准备证据](../evidence/stopped-proof-preparation/RESULT.md)。

2026-11-05 同一helper的已reap会话现在保留原worker，通过现有已鉴权recover显式重试原线程清理；owner字节变化、并发/过期请求及新open/控制仍拒绝。独立审查及8个真实无害子进程fixture通过；网络回调为fixture，不代表真实TUN恢复。见[恢复证据](../evidence/retained-recovery-20261105/RESULT.md)。跨helper现存网络项、真实root/TUN及完整升级仍未验收。


2026-11-05 已实现protocol-2安装升级事务及明确恢复入口，102个中断点和真实截断载荷拒绝fixture通过；截断/未知载荷保留，不宣称自动修复。App-only升级以完整client inventory摘要区分release。真实管理员安装升级卸载验收仍待执行。 见[集成证据](../evidence/upgrade-proxy-integration/RESULT.md)。


2026-11-05 `d62675f583c3794fa4c75dcdf4c2e514d2db74d8`双平台CI通过；同提交fresh/upgrade实际包离线独审通过。新fresh包真实管理员安装、精确身份/neverStarted回执核验、固定入口卸载及Installer receipt清理均通过，job始终未启动、Core/App/TUN未运行。空的既有Client父目录原inode保留；无手工删除或PID终止。升级包尚未真实升级，运行后卸载及网络验收仍未通过。见[本次证据](../evidence/finite-candidate-d62675f/RESULT.md)。


2026-11-05 `07b4325`冻结普通UID无TUN实验真实normal/EOF均通过；预创建0600空cache由固定Core原地初始化，同inode/owner/mode，准确停止Core exit0且独立进程/运行目录消失。仅证明此cache兼容性，不授权跨helper清退。见[真实证据](../evidence/cache-precreation-07b4325/RESULT.md)。另已准备d62675f fresh → 9763482升级的同helper/Core、不同封印App版本对，两源CI通过，实际升级未执行；[产物对](../evidence/app-only-upgrade-pair/RESULT.md)。

2026-11-05 cache来源接入生产service：启动前独占预创建0600并fsync，owner保存cacheOrigin，resume前核对完整初始身份，原held child reap后才允许同来源终态清退。独立审查、主会话严格生产/test编译和全native fixture通过；origin-only仍拒绝跨helper恢复。见[集成证据](../evidence/production-cache-origin/RESULT.md)。下一步补生产有界诊断，日志失败不得阻断网络恢复，也不得绕过证据保留清退work；真实root Core/网络尚未验。

2026-11-05 生产有界诊断已接通，两个实验caller复用同一capture。准确waitpid终态、闭合配置凭据脱敏、失败stage和停止原因在清退前持久化；日志失败仍尝试原网络恢复，但不确认完整清退。固定TunDiagnostics证据目录卸载后保留并明确提示。独立审查、生产严格编译及主会话全native含固定Core-t通过；实验caller无害自测通过。见[集成记录](../evidence/production-diagnostics/RESULT.md)。下一步冻结新产物，重跑已授权普通UID真实normal/EOF；root/TUN及网络恢复未据此标为通过。


2026-11-05 `aaa85e82376cd7a99009730a06c6cae8f231b21a`生产有界诊断及共享capture已集成，双平台CI通过；新冻结执行器真实无TUN normal/EOF均exit0，私有接口读回、SIGTERM→Core exit0、独立Core/worker ESRCH、组空及整个运行目录消失均通过。EOF仅owner连接断开，不是实际Electron退出；root/Core组强杀、真实TUN双栈/LAN/分域DNS及异常网络恢复仍未通过。见[本次精确产物及执行证据](../evidence/production-diagnostics/core-execution-aaa85e8/RESULT.md)。

2026-11-05 恢复增量：精确归属 DNS 可在旧 Core/work 门阻塞时独立清退；总体仍保留 live/unknown Core 与 origin-only cache 拒绝，fresh 不造 held-stop 证明。owner/socket/DNS/routes 同步失败必须重试成功才可 off；同实例保留原始停止证据。双实现 agent＋独立 reviewer 无阻塞，隔离测试通过，主会话合并验证及新产物随后记录。见 [实现与证据边界](../evidence/recovery-durability-20261105/RESULT.md)。

2026-11-05 `4a8c7ac`组合native＋固定Core -t及真实normal→独立absence→EOF通过，两个Core均SIGTERM后exit0；同源码finite-session包已构建并独立离线解包核验，未安装/未TUN。CI原生通过但旧readiness TS用例API超时失败，现仅修测试前置条件并保留500ms/原断言，等待新CI。证据见[恢复验证](../evidence/recovery-durability-20261105/RESULT.md)。

2026-11-05 最终候选源码`4abee2431de852244e43bf5ecab86cfcf91fb259`：macOS/Windows CI通过，同提交fresh finite-session包SHA`f283dc18921aaf03980ca341c139d3721b38e5fffaafed15b711951f4365f4f6`已构建并独立离线核验。原生与刚通过真实normal/EOF的4a字节相同，不把旧执行重标为新执行。尚未安装该包、未获/执行root真实Core监督死亡或首次TUN窗口；异常writer退出证明、实际升级和运行后卸载仍开放。见[最终候选证据](../evidence/finite-candidate-4abee24/RESULT.md)。

### 前次状态快照（替代69728e6前，保留历史）

- 集成提交 `822b7fb1e6d01dc167d3c3f4fb451264079b8bba` 的 macOS／Windows CI 已通过。新 root 无网络候选已冻结，完整清单、源码blob、无害fixture和独立审查通过；[精确产物与完整窗口](../evidence/next-root-window-20261105/WINDOW.md)，待一次集中授权，尚未执行。
- 下一窗口覆盖旧四文件退役/证据归档、fresh安装、normal→kill、独立恢复和精确清理。主会话21项driver＋9项archive集成测试通过；生产跨helper writer证明、origin-only工作目录清退和真实TUN网络仍未通过。
- 诊断fixture取证已接入，有限10次/80场景未复现旧失败；历史exit97和零输出TERM15仍缺根因，不增加timeout/重试。[证据边界](../evidence/service-diagnostic-ci-20261105/RESULT.md)。
- IPv4-only上游兼容修复已在源码；双栈能力保留，实际网络与第三方冲突验收另需窗口。正常重开保持TUN关闭。

### root697执行前状态（历史）

- 替代源码 `69728e6abeb27f45f1bbea5b47b5e638d5f0ae9e` 已冻结；13项清单、27项源码blob、实际driver、固定恢复依赖和生成cleanup已独立核验，旧822候选不再执行。[精确产物与完整窗口](../evidence/next-root-window-20261105/WINDOW.md)。
- 22项driver、8项独立恢复回归通过；停止证明修复通过完整原生fixture和独立生产调用链复核。该提交macOS／Windows CI均已通过；未重复本机真实Core或root实验。
- 下一窗口包含旧四文件退役/证据归档、fresh安装、normal→kill、独立恢复及精确清理，待集中授权。跨helper writer证明、origin-only清退、真实TUN及升级验收仍未完成；IPv4-only上游保留双栈能力，真实网络验证另安排。
