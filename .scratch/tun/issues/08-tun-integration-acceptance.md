# macOS TUN 集成验收

Status: ready-for-agent（eb4 正常窗口已准备；独立包审查通过，待用户授权执行）
Type: validation
Blocked by: 首次正常启停：现场基线/Profile一致性及主会话统一窗口；正式交付：真实异常恢复与升级验收
Owner: 主会话集成与最终验证；验收 agent 准备记录

## 当前状态（2026-11-05，eb4beec）

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

在同一源码/精确 App/helper/Core 产物上集成 [04](04-macos-privileged-adapter.md) 与 [06](06-state-and-ui.md)，核验最终 CI、打包和真实结果。沿用原票及原型证据，不新增验收票；Git/公共接线与同机器系统时段由主会话统一协调。

## 验收标准

- 自动检查、构建/打包与产物身份齐全；配置准入、双向互斥、失败/未知关门、退出与准确 owner 清理符合 ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)。正常重开先残留检查、TUN关闭且仅手动开启；[ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 的LAN/split DNS保持、无新DNS供应商、缺失/不支持DNS具体拒绝、显式DIRECT与无独立kill switch已批准，不再等待产品选择。
- 管理员授权安装/取消、精确产物绑定、完整客户端认证、有限 broker、升级/卸载与失败恢复按 04 核验；已安装不代表代理中，不借卸载丢失恢复能力。不依赖付费会员，fake/原语不代替真实权限证明。
- 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；操作前后读回路由/DNS/代理/进程及归属，恢复基线；未知结果如实保留。双栈固定模板/无高级 UI 已批准，具体参数依据固定版本作技术选择；核验root schema通过先于模板实现，候选未实验不能记通过；不静默关闭IPv6或夸大覆盖/防泄漏。开启与故障状态均提示无独立kill switch、路由消失可直连；验证不自动换DNS供应商/丢字段或因故障切DIRECT。
- 已授权的既定 fresh/鉴权/普通用户 Core 范围不逐包重复确认；新增 root 监督窗口、首次 TUN 网络窗口及扩大范围须明确批准，管理员弹窗由维护者处理。系统实验由主会话串行；Backup 验收及恢复先于登录项。结果不泄露 Profile/订阅或私人证据，不复用旧包替新代码验收。


## 历史人工窗口与前置条件（已被顶部新窗口替代）

本节保留822/4ab阶段的历史计划与当时前置条件，不是当前执行顺序；其中“A尚未执行”等状态已被后续root697及顶部eb4记录替代。当前只执行顶部链接的NEXT-WINDOW正常窗口，不按下表重跑旧实验或操作旧产物。下方旧“逐包授权”和旧产物说明均只作历史证据。

| 阶段 | 已准备 | 仍缺什么 | 维护者最少操作 |
| --- | --- | --- | --- |
| A：root 固定 Core，无 TUN | 822b7fb 新冻结候选、两个独立epoch、完整清单、旧858精确退役归档、normal/kill/独立恢复/四文件cleanup；CI与离线复核通过 | 本候选的真实normal与kill观察尚未执行 | 一次批准[完整15–20分钟窗口](../evidence/next-root-window-20261105/WINDOW.md)，本人处理管理员弹窗；不重跑旧858 |
| B：首次 TUN 正常启停及实际 App 退出 | 4abee24 finite-session 候选、双平台 CI、生产鉴权/会话/双栈/停止和恢复入口；固定 job 命令 | A 的结果评估；现场只读 baseline、真实 DNS/Profile 可表达性、精确 YAML/hash 与受控 IPv4/IPv6/LAN/分域目标；load-F/rootTUN/实际Quit/运行后卸载实证 | 在上述前置核验后集中批准约35–50分钟窗口；管理员弹窗；必要时确认现有 Profile/受控目标，无需逐参数选择 |
| C：helper 强杀及下次启动完整恢复 | 精确 DNS 局部恢复、旧 Core 身份拒绝门、工作目录校验 | **实现和实证均缺**：可信且绑定原会话的 writer 退出依据、origin-only cache 清退、完整恢复/停止证明；仍存在的 route 不因记录 PID 获得删除权 | 当前不请求故障注入授权；不得因 A 组观察通过就跳过实现门 |
| D：实际升级及恢复 | 升级事务/回滚入口、已冻结 App-only 升级对、隔离中断测试；末次fsync重试已修复并通过隔离测试 | 实际升级/失败恢复验收；运行过后升级需先有准确停止证明 | 单独明确非网络升级范围及管理员弹窗；不把 fresh 授权扩大为主动中断升级 |

### A 窗口历史授权范围（已执行并因观察协议失败停止，勿重试）

精确产物：[85834ab冻结记录](../evidence/lifecycle-core-preparation-85834ab/RESULT.md)，目录 `/private/tmp/kuro-lifecycle-core-review-85834ab`。fixture SHA256 `e5c949f29785297b8ba8ac5a5be76f8483dea17d0bf7daf20860cbd33daeb1f1`；approval SHA256 `c20eb39a0032b73a4b6b5b229377642f2504aac30b77fe9ae592b3bb5ed29ec1`。它是独立监督实验，不是4abee24生产安装包；本轮未修改/重冻它。

补充清理入口：[源码与操作说明](../prototypes/helper-lifecycle/root858-cleanup/README.md)，执行路径 `/private/tmp/kuro-root858-cleanup-candidate/cleanup-root858.py`，SHA256 `768d0938c0d0e321f8152c0328c8a629d0e30379ad57aa3052f1094ccfe482dc`。12项普通用户隔离检查通过，另经未参与实现的agent独立审查；未运行root清理，原858包11项清单重新核验一致。

1. 主会话复核完整 SHA256SUMS、精确四路径和job无冲突、祖先保护；保存结果。维护者处理管理员授权后，仅安装固定实验文件，尚不bootstrap。
2. 执行一次normal：真实固定Core只私有Unix controller，TUN/DNS/IP监听关闭。必须同时满足接口读回、held-child停止、独立准确进程/组与owner/work消失、job恰好runs1/exit0，才能继续。
3. 切换独立kill epoch，仅bootout准确normal job并替换精确plist。核对实时身份后，仅向 `system/dev.kuro.tun.lifecycle-a` 发 SIGKILL；约1秒/5秒分别核对supervisor/Core/完整组消失。超时fallback不算launchd通过。
4. 消失证据充分才retire准确job并确认job absent。随后用单独冻结的 `cleanup-root858.py` 核验两stage成功证据、当前job/准确进程/完整组均absent，先持久化root0600四目标身份批准，再逐个复核并移除下表四个安装文件。每次重试仍重新确认absence；任何身份或证据变化立即停止。此入口不发信号、不卸job、不接受路径参数，也不递归删除目录。

| 对象 | 正常完成后的处理 |
| --- | --- |
| `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a` | 固定摘要、inode/设备/权限核验后删除 |
| `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist` | 仅精确kill epoch的plist，job absent后删除 |
| `TunLifecycleExperimentA/normal/mihomo`、`kill/mihomo` | 固定Core摘要与文件身份核验后删除 |
| `TunLifecycleExperimentA/approval.json`、两stage原始诊断/配置摘要/身份/成功或观察记录、`cleanup-approved-root858.json` | root受限证据保留；支撑来源、停止和清理中断复核 |
| `kill/owner.json`、`kill/session-work` 内配置/socket/cache及目录 | 保留原状；原进程/组消失不构成所有脱组writer退出证明，本次不清退这些工作数据 |
| 未知、被替换或权限变化对象；部分安装失败已写对象 | 保留并报告；本成功清理入口不处理部分安装失败 |

保留根目录为 `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA`，目录0700/证据文件0600。无Installer receipt（独立驱动安装，不调用pkg Installer）；不安装生产App/helper，也没有新增登录项。原冻结review包和外层命令记录留在本地作为来源/执行证据。实验安装文件清理通过不等于生产恢复、完整卸载或脱组后代证明。

停止与恢复：摘要/路径/身份不符、normal失败、超时、live/unknown残留就停止后续阶段；仍持有的准确child仅走原有bounded stop。helper死亡后不按旧PID/PGID补杀。安装部分失败尚未bootstrap时，原位保留并报告已写对象；现驱动没有自动回滚，不尝试用要求完整安装的retire伪装清理。完整安装后只用当前stage的精确retire卸job，前提是原进程/组已确认消失；未知对象和证据保留。无代理、路由、DNS、登录项、注销/重启/关机或第三方修改。

### B 当前环境预检结果

只读预检已发现既存经utun1024的IPv4 `/1` 路由，宿主IPv6默认路由查询返回not in table。当前生产预检分别拒绝第三方split-default冲突，以及缺少IPv6默认路由；后者是旧候选的IPv4-only兼容性限制，不是已批准的产品启动要求；当前源码已补兼容与端点保护，隔离检查通过，旧冻结包尚未更新。完整外网双栈验收需要可用IPv6环境；产品本身不能因此要求上游必须双栈。固定本地双栈模板保留，IPv4-only上游兼容性纳入06；不自动关闭第三方VPN、改路由或静默关闭IPv6。现场冲突和Profile/目标尚未冻结，首次TUN窗口仍未准备完成。两项均不影响A的无网络测量。原始地址/域名仅本地受限保存，见[脱敏证据](../evidence/tun-readonly-preflight-20261105/RESULT.md)。

### B 窗口准备完成后的单次确认内容

按现有下方详细命令收敛为：保存现场baseline及现有DNS/精确受限Profile → fresh安装准确生产候选 → 固定 `load -F`（不用`-w`，不fallback enable）/print/kickstart并核对 → 真实安装App inspect/recover证明off → 导入并手动开TUN → 本地A/AAAA与预先明确的双栈/DIRECT/LAN/分域DNS验证 → 手动关闭并核对自有网络/Core/work/停止证明 → 再开后使用实际菜单Quit（不是关闭窗口入托盘）→ 重开保持off → 已确认停止后卸job、精确运行后卸载并核对baseline。任一步失败不进入下一步；同获准范围修复重试不逐包确认。

baseline含准确接口/两族route/resolver及scoped DNS/代理/既存VPN、自有job和安装/owner/work回执。第三方split-default、双默认出口不受支持、地址冲突或DNS不能无损表达则在写网络前停止，不关闭第三方VPN或替换DNS来换取通过。只影响本次准确Core的utun、固定自有route和临时DNS key；不新增公共DNS供应商。正常停止或恢复无法确认就保留unknown及证据，不用卸载/flush/reset/旧PID kill绕过。无独立kill switch，路由消失可能恢复直连。**此阶段暂不包含helper强杀。**

## Comments

### 集成前检查点（历史保留，当前状态以上方为准）

**本轮集成：** 新 root 完整窗口已接入旧四文件精确退役/证据归档、新候选构建、normal→kill、独立失败恢复和成功清理；主会话集成验证21项driver＋9项archive通过，独立审查确认源码一致。[集成证据](../evidence/next-root-window-20261105/RESULT.md)。未执行新root窗口；生产跨helper writer证明与真实TUN仍未完成。

诊断fixture取证补丁已集成，未放宽1秒期限或断言；偶发启动失败仍在定位。32af9dd的CI已通过，不据此宣布稳定性问题已解决。

**最新真实窗口：** root normal 的 Core 私有接口、SIGTERM exit0及 native清退通过，但观察器把布尔输出为数字1，严格驱动拒绝；kill未执行。原retire同门失败后，单独获准的独立恢复入口已bootout；宿主独立读回job不存在。四安装文件及受限证据保留，不重跑normal/kill。[结果与准确残留](../evidence/root-core-window-20261105/RESULT.md)。

冻结生产候选 4abee2431de852244e43bf5ecab86cfcf91fb259，同提交 macOS/Windows CI 与离线包核验通过；普通用户真实 Core normal/EOF 通过。本轮恢复/升级增量单独提交，尚未进入该包；首次相关验收前再冻结，不为文档或未变链路重打。下一步 root Core → TUN 正常启停 → 实际 App 退出 → 条件满足后异常恢复。未批准的系统操作不执行；相关实现未变不重复普通用户实验或重打包。

本轮[恢复/升级增量](../evidence/recovery-followup-20261105/RESULT.md)已通过独立审查和组合隔离测试；未据此重跑真实Core或生成新包。

精确产物与证据见 [当前候选](../evidence/finite-candidate-4abee24/RESULT.md)。人工操作集中见 [08 历史窗口](08-tun-integration-acceptance.md#历史人工窗口与前置条件已被顶部新窗口替代)。历史记录保留，不将旧拒绝门或旧授权描述当作当前状态。

真实Foundation序列化→严格驱动回归，以及独立证据→失败恢复串联回归已集成并独审通过；数字1验收仍拒，live/unknown/错误epoch/记录变化仍阻止恢复。[测试和实际恢复证据分列](../evidence/recovery-separation-20261105/RESULT.md)。

### 已完成的最小恢复与后续授权边界

固定normal job恢复入口（source ecb303c，SHA `29c5fc0ae37902f77a89ed1f03ff2fcaeabe4dbad541d096d24ab6432a61fd27`）经单独批准已执行exit0，主会话独立读回launchctl113/service不存在；所有文件保留。[原始恢复说明](../prototypes/helper-lifecycle/root858-normal-retire/README.md)及上述结果记录共同保存。

验收判定与失败恢复分开：验收仍严格拒绝numeric1，恢复独立复核受保护安装/normal凭据、当前准确job及kernel进程/完整组absence。后续同一已批准实验范围内，仅为停止/卸载本次准确job所需的恢复修复无需逐脚本确认，须先复核新源码/摘要并留证据；不扩展为Core启动、网络变更、未知删除或旧PID信号。当前不重复root normal/kill，先完成真实协议及失败恢复回归后再集中安排新窗口。


2026-11-04 实验 A 已获明确授权并完成：独立无网络 LaunchDaemon 的 supervisor 强杀后约 1s/5s，准确 child 均 absent；无 marker/TTL 自退出，job 未重启。清理驱动 bootout 并移除精确安装文件；独立最终读回确认 job、binary、plist、实验数据目录不存在。详见[本轮结果与保存证据](../prototypes/helper-lifecycle/results-668F8E2A/RESULT.md)。这是测试 fixture 的 launchd 组清理实证，不是生产 Core、utun、路由或 DNS 验收；未运行 Core/改网络/改登录项。后续系统实验须另获授权，04/06/08不关闭。

2026-11-04 组合检查：State127/127；桌面prepare/fetch-core最终23项及backup-ipc/Profile调用方17项通过；根`bun run typecheck`四包通过；diff空白检查通过。没有新CI或新验收包；2617cf9旧包不包含当前配置门禁、Backup停止证据及准备器。真实资源prepare命令因原生helper/pin尚缺exit1，未生成安装产物。这些结果不关闭本票或替代TUN真机验收。

2026-11-04：本轮只整合票据与已批准策略，尚无新增真实验收。04/06 的最终源码、自动检查、精确产物与人工证据待回填；Windows 07 独立保留。

2026-11-04 本轮后续：生产客户端/State/UI接线，阶段UI25项/renderer typecheck通过；主会话报告State151、desktop359通过/17skip、全量typecheck通过。原生仍关门拒绝未完成的可信链/root配置/未知清理；native修复、最终build/CI和精确产物仍待主会话回填。双栈范围不再待批，不复用2617cf9或早期计数证明新实现；真实系统操作仍无“开始”授权。

2026-11-04 集成检查点：API12、Core138、State166、Desktop376通过，共692项通过；Desktop16项按平台跳过。Desktop包含普通用户bundled Core loopback整合，网络写入mock，未运行App/真实helper安装。四包typecheck、production build和本地DMG构建通过；native隔离build/test、ad-hoc runtime签名与strict校验通过，prepare/package/fetch31项包含在Desktop计数内，不重复相加。两路独立复核后修复resume/退出竞态、严格代理停止读回、native --serve、preflight祖先验证与卸载恢复入口。

CI配置已串联native隔离测试→App dmg→disabled helper pkg，并保存source-commit/SHA256SUMS/helper pin/manifest。最终CI与精确产物记录由主会话下条结果追加，旧2617cf9不代替当前代码。TUN start/完整attestation/root schema与broker/native owner-death lease/双栈网络清理仍未交付；disabled pkg仅供审阅，不进入本轮Backup与登录项安装验收。真实系统操作没有“开始”授权。

2026-11-04 最终CI/产物：源码`9990da69c565cef973e8560636fd2fb68fddbf15`，[CI 41774486923](https://github.com/coderhyy/clash-kuro/actions/runs/41774486923) macOS/Windows均success；草稿PR #3依赖PR #2，未合并。App：`/tmp/clash-kuro-acceptance-9990da6/kuro-macos-arm64/clash-kuro-0.1.0-arm64.dmg`；SHA256 `df1116f64e4719e11135442bc24b4a08b08b36ea0ae4bc57f2314ce6fd1ba130`，下载后匹配CI清单且hdiutil verify VALID。禁用helper：`/tmp/clash-kuro-acceptance-9990da6/kuro-macos-helper-disabled-arm64/dist/kuro-tun-helper-disabled-0.1.0-arm64.pkg`；SHA256 `1a5711bfd26228d715d1d52b689bb479525457246d1a9429019cd5259b141333`，与同commit的helper.lock/manifest/pkg.json身份交叉核验通过。本地实际pkg另做离线解包，四份helper/Core摘要、固定preflight/install脚本及BOM祖先0755/私有0700通过；没有执行安装脚本。产物及操作步骤见[人工验收入口](../../phase2/manual-acceptance.md)。真实系统验证继续等待明确“开始”；此CI结果不关闭04/06/08，不证明TUN可启动或全流量被接管。

2026-11-04 受限会话切片本地整合：State正反切换均先校验目标配置再停止旧模式；V2长连接客户端已接闭合配置、lease和独立stop读回；修复并发inspect清空session的引用竞态。原生测试包含真实普通用户direct-child/SCM_RIGHTS peer退出、固定Core-t及29项DNS mock/temp场景，均通过。四包typecheck/production build通过；本地App目录包经afterSign的seal/ASAR/fuse核验通过，篡改副本被拒绝。没有运行真实App/root服务或网络写入。

真实三结果仍为：启动不支持（native gate）；停止/清理仅组件隔离证据，未完成真实TUN闭环；异常恢复仅direct-child与自有DNS journal组件，未证明helperSIGKILL/双栈route恢复。不把该检查点当作可安装TUN验收包。最终同提交CI身份由主会话回填，原9990da6产物只代表旧版本；人工顺序与授权要求不变。

2026-11-04 最终结果：源码`f8376911308b80677dac923ba9e5fbe3c0095f77`，[CI 41787576501](https://github.com/coderhyy/clash-kuro/actions/runs/41787576501) macOS/Windows全部success。首轮2197af4的macOS打包失败因PR默认跳过ad-hoc签名；保持完整性校验并在无证书/无密钥环境显式执行ad-hoc签名后已修复，未绕过检查。最终本地API12/Core218/State170/Desktop407共807项通过，desktop16平台skip；native隔离suite、固定Core-t、四包类型检查、构建和验包通过。

已下载同提交App与disabled helper，source-commit与CI完全一致。App路径`/tmp/clash-kuro-acceptance-f837691/kuro-macos-arm64/clash-kuro-0.1.0-arm64.dmg`，SHA256`6c6b256cad37b3c16cc72339650b9a9c0e7a8002190b3aa5fc5a7923bbdd8cb4`；hdiutil verify VALID。helper审阅pkg SHA256`94ab97e2a5142c0d37d4ca534083adc2f2718bdf9cc40befef85fd69d53fb69b`；摘要/manifest/lock匹配，离线展开后的helper、installer、preflight-native、uninstall、Core分别匹配pin，未执行脚本。详细准备步骤与保存项见[人工验收入口](../../phase2/manual-acceptance.md)。仅App用于Backup/登录项准备，禁用helper不安装；真实TUN三结果仍不具备，04/06/08保持开放。


## 当前检查点与下一最小实验（2026-11-04）

本节覆盖上述较早“未实现”描述及旧产物检查点，不改变其历史CI/摘要。当前已有受限root schema、V2客户端/单owner原生服务与并发status、有限私有Core控制、client pin安装清理、双栈PF_ROUTE与DNS归属日志组件。组件通过普通用户fixture、wire/注入后端验证；[冻结Electron候选](../electron-auth-verification.md)有14/14隔离UI/IPC/环境调试负例与3/3离线篡改证据。没有据此验证root安装后的动态调用者鉴权、真实Core/utun、PF_ROUTE/DNS或跨helper异常恢复。生产`Authorize`及`ready`/`applyNetwork`/`recoverNetwork`仍拒绝；fresh-only不覆盖升级。实验A已完成，但仅是其无网络fixture的launchd组清理；A的授权不延伸到下一实验。最终组合测试、CI及本轮产物身份由主会话回填，不复用f837691等旧包作为新实现证据。

下一最小系统实验先限于**固定受保护App/helper的fresh-only安装与无网络鉴权读回**，不启动Core、不创建utun、不写路由/DNS/系统代理/登录项。进入条件是：精确包/独立摘要与管理员实际消费绑定完成审阅；安装/恢复清单和固定位置策略离线核验；提供经审阅的只观察鉴权且不获得启动能力的入口，能区分正常安装App、不同binary、重签与资源篡改副本（目前无条件拒绝不能当这些负例通过）；确认无既有安装/owner残留并独占系统操作时段。上述前置尚未齐全，因此本节不提供现成执行命令，也不请求维护者现在“开始”。

预期影响仅为经批准的固定安装路径、安装记录及必要的临时服务；操作时长须待精确候选与脚本冻结后给出，不沿用实验A的时长。恢复仅停止已确认的本次job/进程、按批准hash清单移除自有helper/pin，并按明确清单处理本次App副本；当前helper卸载会保留App，不能称全部恢复。部分安装、未知对象或停止/归属不明均保留恢复材料并阻塞。只有这一步取得安装/鉴权证据后，才另行准备固定Core的无自动路由/无DNS接管接口实验，再准备有限双栈路由/DNS的正常停止、App失联和异常恢复；各步单独审阅影响与恢复且另获授权。目前没有可启动真实TUN的完整候选，04/06/08保持开放。

2026-11-04 最终组合检查点：[精确产物、摘要、离线解包证据与下一实验前置](../evidence/electron-candidate-20261104/RESULT.md)。硬化 App 的隔离功能/入口负例已测，最终 native 构建通过；启动取消与 stop ACK/status 两个并发窗口均修复并通过屏障回归。内嵌 App 禁用包 SHA256 `c3cdf1af1f5bd9f7745171b55958c78589c564db53152de69e8d9f4ed6a5b6bf`；9 个 bundle 固定位置/严格标识、预期 root BOM、展开身份与摘要已复核。未安装，仍不能执行真实 TUN；不要求用户开始。完整鉴权观察入口、生产网络接线、升级及真实系统验收仍未完成。

2026-11-04 新实验范围收敛：沿用04的[auth observation实验](../auth-observation-experiment.md)，只做fresh受保护安装、合法App实际动态auth及冒充/身份负例、准确恢复卸载。产物必须同一干净源码提交，App seal含sourceCommit与auth-only，native build record同提交/测试/显式skip Core -t。无网络实验独立于06实现；完整TUN、升级和Backup/登录项验收不混入此授权。


2026-11-04 固定候选检查点：下一步鉴权实验已准备可执行，实际安装鉴权未跑。精确提交、包、摘要、脚本和负例目录已固定；计划8–12分钟，仅fresh安装/前台auth observer/正负例/精确卸载及receipt清理，不bootstrap job、不运行Core/-t或系统网络变更。等待维护者本次明确“开始”；先前实验A授权不沿用。 见[结果与证据](../evidence/auth-observation-1ad5f06/RESULT.md)、[精确产物](../auth-observation-artifact.json)和[执行步骤](../auth-observation-experiment.md)。


2026-11-04 授权实验实际结果：指定1ad5f06/7bf9ce2b观察包已管理员尝试fresh安装，preinstall因本机/private/var/run=root:daemon0775被严格父链检查拒绝，安装退出1。实际Electron正例、动态负例、非观察操作测试均未进入；不能标通过。固定安装目标、socket/身份/回执、job和Installer receipt均无残留，本次Installer临时目录已消失，未执行额外删除或kill。授权已随实验和清理核对结束。详见[实验证据](../evidence/auth-execution-1ad5f06/RESULT.md)。后续固定socket目录须迁到严格保护祖先并统一客户端/卸载；不放宽父链或chmod系统目录。新包另需授权。


2026-11-04 新鉴权候选已冻结：实现e8ae1dc394ce59d447051d2a3fff4fdcd51a6492，包SHA256 `98562290ab91af7372cf1d7d2c8d2145e6e1f0453adb6c1203710c3d319a6177`；新受保护socket路径全链同步，native全套/desktop485+16skip/typecheck/实际隔离Electron14通过，解包验证通过。实际root安装与动态auth仍未执行；等新授权，不沿用1ad实验授权。[结果](../evidence/auth-observation-e8ae1dc/RESULT.md)、[产物](../auth-observation-artifact.json)、[步骤](../auth-observation-experiment.md)。


2026-11-04 e8ae1dc/98562290有限鉴权实验实际通过且清理完成：root fresh安装和App seal/inventory/client/fresh身份核验通过；实际安装Electron authenticated=true；重签App明确身份拒绝、外部Node硬化拒绝；正例后start/open/stop/recover/exec全部拒绝。observer正常exit0，准确卸载与receipt forget exit0，最终路径/进程/socket/身份回执/job/receipt无残留；本次授权结束。[实际证据](../evidence/auth-execution-e8ae1dc/RESULT.md)。不是Core/TUN/网络/升级验收，不开放生产门。


2026-11-05 当前下一实验改为[普通UID固定Core有限控制](../core-control-experiment.md)：不安装、不启动job、不改系统网络；需要另行授权真实Core执行。只准备normal与成功后EOF，不提供helper强杀入口。验收以实际version/有限控制读回、准确child退出、工作目录及socket清理为准；配置和fixture不替代实证。生产root启动前还缺运行后可卸载的停止证明及完整候选，升级继续保留交付要求。原鉴权实验通过范围不变，授权已结束。


2026-11-05 固定前置实验：源码`639c64fbfd3d371057dfd59d8b01b882c8aebbe3`，独立普通UID runner已离线构建、严格签名校验及最终产物38 fixture断言通过；全native fixture通过，Core/-t显式未执行。精确目录、摘要、5–8分钟normal→EOF步骤与有限恢复方法见[准备结果](../evidence/core-control-preparation/RESULT.md)。状态为可执行、等待新授权；不包含root/TUN或helper强杀。


2026-11-05 已授权639c64f普通UID真实Core normal实际失败：Core控制ready前自行exit1、无信号，runner exit2；EOF按门禁未执行。准确Core/worker均ESRCH，guardian组空，owner/work/socket清退；仅固定Core副本及证据按失败策略保留。Core输出被旧候选丢弃，根因未知；下一最小修复为有界诊断日志并另冻候选，不重试原包。本轮授权结束。[实际结果](../evidence/core-control-execution-639c64f/RESULT.md)。


2026-11-05 639c64f旧包/失败证据保留，不修改或重试。新诊断候选按同范围normal→完整通过才EOF准备，仍需新提交/epoch/精确摘要及新授权。离线核对没有证明历史exit1原因；本轮不运行Core/-t。来源与结论见[固定版本离线核对](../core-control-offline-review.md)，最终新产物和fixture证据由主会话追加。

- 新诊断候选已固定到 `8ee323a48da5729217a0f730d4de850da867f0d9`；离线构建、全量 SHA256SUMS、inspect 与签名后 111 项 fixture 断言通过。normal/EOF 均未执行，等待新的同范围授权。精确产物、摘要、步骤及恢复边界见 [候选记录](../evidence/core-diagnostics-candidate-8ee323a/RESULT.md)。

2026-11-05 新候选8ee323a仅运行一次normal：Core原始错误 `Parse config error: yaml: found unknown escape character`，自行exit1，阶段private-version-readiness；EOF未执行，未改配置或重试。日志完整保留，Core/owner/work及组消失证据已记录；失败策略保留固定Core副本与诊断。授权结束，见 [执行记录](../evidence/core-control-execution-8ee323a/RESULT.md)。

## 长期交付执行授权（2026-11-05，覆盖旧的逐包等待约束）

用户明确要求长期goal持续至macOS TUN首版实现、验证和可合并交付。允许同既定范围自主修改/构建/提交/CI、固定Core -t及无TUN normal/EOF诊断修复重试；允许重复已有生命周期/鉴权/fresh安装卸载实验，新候选须先核对来源摘要并留版本/影响/清理。管理员凭据和系统弹窗仍由用户处理。首次真实TUN网络实验前集中确认完整窗口；该窗口内同范围修复重试不逐包确认。注销/重启/关机、未知归属数据删除、第三方设置变更或扩范围仍单独授权。主会话串行系统实验，独立agent审查实现和验收真阳性；不新增票。

已完成固定Core -t差分：仅将保存配置的 `\/` 改为 `/`，结果从相同unknown escape错误/exit1变为exit0。专用目录只含配置和日志；原始证据见 [差分结果](../evidence/yaml-core-differential/result.json)。该结果不等于normal/EOF或TUN通过。

2026-11-05 `6b45cb4`真实normal已完成固定Core v1.19.33控制接口、mode/选择读回、两次NoIP观测和stop ACK→SIGTERM→exit0，Core/组/整个base消失。严格success schema拒绝worker.ownerAbsent/workAbsent的数字1（应为boolean），runner exit2、无normal-success，EOF未执行；按已有长期授权修producer类型与真实worker到receipt回归后另冻epoch，不放宽schema。[证据](../evidence/core-control-execution-6b45cb4/RESULT.md)。

2026-11-05 真实固定Core前置闭环通过：`98f1afbe6822999bab02723d62820a96c395571e`同epoch normal及EOF均runner0；version、mode/选择读回、stop ACK/owner EOF、SIGTERM→Core exit0与独立进程/整个运行目录消失通过。无root/TUN网络操作，不等于实际Electron退出/后代全退出或网络恢复；诊断保留。见 [证据](../evidence/core-control-execution-98f1afb/RESULT.md)。04/06/08继续开放。


## 首次真实 TUN 完整窗口草案（2026-11-05，尚未执行）

本节沿用本票，覆盖历史“下一实验仍是auth/nonTUN”的顺序说明；长期授权已允许既定无TUN实验，**首次真实TUN网络窗口仍须主会话在候选与恢复条件齐全后集中确认**，此处不请求现在开始。`98f1afb`只证明普通UID固定Core normal/EOF；[本轮共享树148项/类型检查](../evidence/production-integration-20261105/RESULT.md)只证明TS订阅整合。两者均不证明root实际TUN。

### 进入条件与窗口范围

- 同一干净提交的 App/helper/Core/manifest/安装与恢复入口冻结并核对摘要、签名/资源/调用者pin；有限activation显式绑定该候选，auth-only/disabled包不获得启动能力。最终native与TS检查、真实安装布局离线验证通过；提供候选实际具备的执行/停止/恢复步骤后才约窗口，本文不编造可运行命令。
- 必须先补齐并fixture验证：首次resume持久记为已运行，cleanup完整成功后才持久记录准确停止证明，**运行后卸载**验证该证明并能保留失败恢复入口。`neverStarted=false`不能靠改回true或删除记录绕过。新旧安装/升级当前fresh-only，不覆盖现有安装；升级/回滚仍是04交付缺口，独立验收，不把fresh窗口通过写成升级通过。
- 明确所测每个故障的可执行恢复路径。跨helper现有absence-only恢复不能移除仍存在DNS/route，记录进程ESRCH也不证明后代全部退出；**在这些路径未补齐前不加入helper SIGKILL、跨helper restart或断电**。不能为了检验故障先制造已知无法安全恢复的root网络残留。
- 主会话独占本机系统时段；预留约**35–50分钟**（不含新修复构建），管理员弹窗由用户操作。每段完成并读回后才进下一段；故障修复/重新冻结后，同窗口同范围重试沿长期授权执行，超出约定影响则停止。注销/重启/关机、第三方设置修改另行授权。

### 只读 baseline 与允许影响

进入网络段前保存精确但本地受限的baseline：physical接口名/index/flags/地址、两族默认及更具体/scoped routes和flags、完整resolver优先级/search/supplemental/scoped DNS及自有store key不存在、HTTP/HTTPS代理状态、已存在utun/VPN、相关准确进程/服务、owner/network/DNS/work/install/恢复回执。明确哪些系统自动变化可解释；不能把所有系统进程或整张route表逐字相等当作归属证明。证据不提交Profile/订阅秘密。

不禁用第三方VPN、不flush路由、不reset DNS/代理、不修改网络服务顺序/永久配置、不关闭IPv6。baseline出现第三方split-default、固定地址冲突、分离双默认出口、无法证明保留的LAN/DNS路径或其它当前preflight不支持场景就**不写网络并结束该段**，不临时改第三方配置以获得绿色结果。已有System Proxy必须先明确归属并用当前批准的互斥停止/读回，不清除未知所有者设置。

允许的网络影响仅为本次候选准确Core持有的utun/固定双栈地址、计划内四条`/1`自有route和自有临时DNS key；保留已有默认/更具体route、LAN/scoped DNS。内部readiness只查询固定`.invalid`静态A/AAAA，不新增上游DNS供应商；后续数据面只用提前列明的本机/自有受控目的端与Profile已有DNS，未明确测试目的端时暂不测外网。无独立kill switch，显式DIRECT和路由消失后OS可能直连均在窗口说明中保留，不承诺全流量接管/防泄漏。

### 固定自有 job 的受控启动与停止（仅计划，未执行）

2026-11-05 只读核对本机 `/usr/share/man/man1/launchctl.1` 的 `load | unload`、`-F`、`-w`、`kickstart`、`print-disabled` 和 `/usr/share/man/man5/launchd.plist.5` 的 `Disabled`：`load -F` 忽略 plist 的 Disabled；`-w` 才持久覆盖该项。`enable/disable` 的状态跨启动保留，因此本窗口不使用它们，不编辑 launchd 状态库。此为本机手册事实，**尚未验证本机 OS 实际支持并成功执行该 legacy 路径**；legacy 命令 exit0 不能证明 job 已载入或运行。

前提是同提交有限候选已准确安装、无既存自有 job/未知残留，固定 plist 及 helper 与安装回执/hash 一致，plist 仍为 `Disabled:true`、`RunAtLoad:false`、`KeepAlive:false`、`AbandonProcessGroup:false`、准确 helper 的 `--serve`。只有主会话在获准的系统窗口执行以下固定对象命令；这里不执行、不自动探测替代方案：

```sh
# 操作前保存完整输出与退出码；精确 label 此时须未载入。
/bin/launchctl print system/dev.kuro.tun
/bin/launchctl print-disabled system
# 不加 -w，不改 Disabled，不自动 fallback enable/bootstrap。
sudo /bin/launchctl load -F /Library/LaunchDaemons/dev.kuro.tun.plist
/bin/launchctl print system/dev.kuro.tun
# 只有独立 print 核对精确 label/程序/参数正确后才继续；不加 -k。
sudo /bin/launchctl kickstart -p system/dev.kuro.tun
/bin/launchctl print system/dev.kuro.tun
```

每一步保存输出/退出码；独立读回 job 的准确程序路径/参数、PID 与实际受保护可执行文件身份、固定 socket 及安装绑定。job/service 就绪不等于 TUN 已开启，必须由已安装封印 App 的真实鉴权 status 证明 off。`load -F` 不支持、print 不存在/不一致、实际进程或 socket 身份不符立即停止，不自动 `enable`、不 `kickstart -k`、不按不可信旧 PID 杀进程。若此前已有持久 disabled override 或自有 job，先保留 baseline 并结束本 fresh 路径，不用覆盖来试通。

结束时先在准确 App 中手动 TUN 关闭，或走现有“检查并恢复 TUN”真实已鉴权入口；确认独立 status off、准确 Core/utun/自有 route/DNS/owner/work 清退及停止证明后，才执行：

```sh
sudo /bin/launchctl bootout system/dev.kuro.tun
/bin/launchctl print system/dev.kuro.tun
/bin/launchctl print-disabled system
```

核对 job/准确服务进程/socket 已消失，并比较本应用 label 的 disabled override 前后完全一致；不将其它系统 label 的异步变化误判为本应用写入，也不修改其它 label。命令失败、override 变化或清理不明则保留证据并停止，不能用 `disable/enable` 修饰结果。准确运行后卸载仍按最后阶段的受保护恢复入口和回执执行，不能以 bootout 代替完整网络/文件清理。helper 已死但仍有未知网络项的情况仍不在首窗口故障注入范围。

### 最低固定 Profile 与实际 App 操作

第一次网络窗口采用最小显式 DIRECT Profile，**尚未填入本机真实 baseline DNS、冻结 YAML 或验证该 OS 的准入**。不得将测试地址/虚构 resolver 填成可执行样例；候选最终配置须在本地受限证据中保存准确 YAML/hash 与准入结果。

| 字段 | 最低构成与边界 |
| --- | --- |
| `mode` / `ipv6` | `rule` / `true`；App 模式也选 rule，不关闭 IPv6。 |
| `proxies` / `proxy-groups` | 都为 `[]`，不新增订阅、远端节点或 provider。 |
| `rules` | 仅 `['MATCH,DIRECT']`，这是明确测试策略；不据此验收代理节点、规则分流或故障 fallback。 |
| `dns.enable` / `dns.ipv6` / `dns.enhanced-mode` | 明确 `true` / `true` / `redir-host`。 |
| `dns.nameserver` / `dns.default-nameserver` / `dns.proxy-server-nameserver` | 三项都必须是非空数组，值来自本机已授权使用且能证明保留访问路径的 baseline/Profile resolver；只支持显式单播 IPv4/IPv6 literal 的 UDP53，不新增供应商，不用 system/DoH/DoT/自选公共 DNS 或带端口/作用域的 token。实际值须在窗口前确定，不能只从 resolver 列表任取一项就宣称保持原 DNS 优先级。 |
| `dns.nameserver-policy` | 如 baseline/Profile 存在需保持的分域 DNS，则保留当前 closed schema 可表达的准确域/对应 resolver；无法无损表达或其路由不可证明保留时拒绝本次配置，不删掉分域配置继续。无该需求才省略。 |
| 其它顶层字段 / Override | 不添加超出 closed schema 的字段；候选 Override 保持空并核对实际值，不能让普通 Profile/Override 偷带 TUN/路由/DNS 参数。 |

仅满足以上结构仍不足以 start：真实 preflight 必须验证共同的双栈 physical 默认出口、无 split-default/地址冲突，以及 LAN/私有 DNS 等已有更具体 direct/scoped 路径可保留。default-only 私网路径或其它不支持基线具体拒绝；不得修改第三方路由/VPN/DNS以通过，也不得承诺任意 LAN 都可达。

使用候选固定隔离数据目录，启动准确已安装的 `Clash Kuro.app` 正常入口（不带 verification/自定义数据目录参数）。UI“导入 Profile → 本地 → 选择准确 YAML → 导入 → 启用”，然后在 System Proxy 附近**手动**开启 TUN，不先点普通 Core 启动。“启用”会走真实 `prepareRuntime` 的固定 Core 配置验证，可能执行 `-t`，不能记为不执行 Core 的导入步骤。TUN 仍通过真实 native adapter；blocked/unknown 时只用现有“检查并恢复 TUN”按钮，不能用任意 Node/socat/root CLI 冒充已鉴权 recover。服务不在时按钮不能自行启动 job，须按上节受控恢复服务后再读回。

新封印 finite-session 候选的 main 已禁止启动时自动清代理、普通 Core 自启、Profile scheduler/版本检查外联及 resumeCore 自动动作，保留真实 startup inspect/recover 和 unknown 关门；源级回归通过，**实际新候选正常启动仍待构建后的受控验证**。普通产品的 macOS stale proxy cleanup 仍只以 `127.0.0.1 + port` 匹配（`system-proxy.ts:124–131`），本次仅跳过候选自动写，未修复普通产品的准确归属缺口。

### 最小阶段与每段停止证明

| 阶段 / 预算 | 执行范围与进入条件 | 通过 / 停止 / 恢复 |
| --- | --- | --- |
| 0 基线与fresh安装，8–12分钟 | 摘要/布局/无冲突baseline通过后，有限授权安装；安装本身不启动Core/TUN。 | 合法App动态鉴权、首次状态off且无网络变化。任何身份/事务/保护祖先不符立即停止；仅按本次批准清单恢复安装，不覆盖旧目标。 |
| 1 首次手动开启与内部双栈就绪，5–8分钟 | 使用root closed schema接受的固定配置；准入先于停止旧模式。先验证准确Core/utun/address/flags，再由journal写自有route/DNS，独立读回；只测本机静态A/AAAA。 | 任一就绪/双族/readback/receipt不一致立即走正常stop。不得靠延时、换公共resolver、关闭IPv6或忽略失败变成on。停止后确认准确Core退出、utun消失及自有网络恢复。 |
| 2 有限数据面与正常停止，5–8分钟 | 仅阶段1通过后重开；使用事先明确的受控IPv4/IPv6目标，核验预期DIRECT/代理选择、既有LAN与split/scoped DNS优先级。若无外部IPv6，仅记本机双栈结果，外网IPv6未测。 | 独立捕获实际路径/DNS结果，不以UI为证明；只检查约定流量，不声称无任何绕过。验证stop ACK后独立status off、owner/work/cache清退、自有route/key消失及baseline保持。 |
| 3 实际App退出/断链与重开，5–8分钟 | 前两段稳定且准确会话终止/清理路径可恢复后，先正常App退出，再一次受控客户端连接失联；不强杀root helper、不按旧PID杀Core。 | 有界停止与独立网络/进程读回；UI断链由真实通知进入unknown/恢复状态，不自动开启或切换模式。重开先残留检查、off、手动再启；残留不明则阻止新writer，结束本段。 |
| 4 运行后卸载与最终基线，8–12分钟 | 最后一次正常停止证明齐全；从候选实际固定恢复入口执行精确卸载，允许批准对象缺失重试。 | 运行过的安装能安全卸载；准确自有文件/服务/socket/回执清退，第三方状态不变。Installer receipt仅核对本次身份后处理，不代替文件删除。任何未知对象/记录变化保留并报具体差异，不能泛化删除。 |

**统一停止条件：** 摘要/身份变化，baseline归属冲突，管理员取消，Core/utun/双栈DNS或route读回失败，lease/状态矛盾，第三方设置变化，网络不可达影响超出候选预期，或任一步无法证明清理。先停止发起新流量与新模式写入，走准确持有会话的正常stop，再独立读取网络/进程/回执。仅比较并恢复本应用已证明拥有的项；不采用持久PID kill、全局reset、未知文件删除或关闭系统IPv6。恢复失败就保持unknown和证据，列具体残留与已知影响，由主会话提供另审的最小恢复方案；不反复开启或借卸载丢失恢复材料。

helper死亡/跨重启对仍存在route/DNS的恢复、真实Core可能detach的后代约束、网络接口切换/单族回退、升级与回滚，继续保留在04/06/08验收清单；缺能力的段不在首窗口冒险执行，未测项目明确不通过，也不因窗口其它段成功关闭主票。

2026-11-05 已实现same-held停止证明与运行后准确卸载，beforeStart/resume持久撤销旧proof，neverStarted=false不回真；已集成finite-session源码候选构建/严格同commit身份打包及固定测试数据隔离，auth-only不扩权。独立审查无阻塞，全native含固定Core-t通过。真实root/TUN仍未验，升级事务未实现；[准备证据](../evidence/stopped-proof-preparation/RESULT.md)。

2026-11-05 同一helper的已reap会话现在保留原worker，通过现有已鉴权recover显式重试原线程清理；owner字节变化、并发/过期请求及新open/控制仍拒绝。独立审查及8个真实无害子进程fixture通过；网络回调为fixture，不代表真实TUN恢复。见[恢复证据](../evidence/retained-recovery-20261105/RESULT.md)。跨helper现存网络项、真实root/TUN及完整升级仍未验收。


2026-11-05 4441983候选已撤回，不安装。替代实现已通过原生含升级/固定Core语法验证、类型检查及94项代理/platform测试；尚未冻结新包或进行真实安装/网络实验。首次网络窗口授权仍待用户明确批准。 见[集成证据](../evidence/upgrade-proxy-integration/RESULT.md)。


2026-11-05 `d62675f583c3794fa4c75dcdf4c2e514d2db74d8`双平台CI通过；同提交fresh/upgrade实际包离线独审通过。新fresh包真实管理员安装、精确身份/neverStarted回执核验、固定入口卸载及Installer receipt清理均通过，job始终未启动、Core/App/TUN未运行。空的既有Client父目录原inode保留；无手工删除或PID终止。升级包尚未真实升级，运行后卸载及网络验收仍未通过。见[本次证据](../evidence/finite-candidate-d62675f/RESULT.md)。


2026-11-05 `07b4325`冻结普通UID无TUN实验真实normal/EOF均通过；预创建0600空cache由固定Core原地初始化，同inode/owner/mode，准确停止Core exit0且独立进程/运行目录消失。仅证明此cache兼容性，不授权跨helper清退。见[真实证据](../evidence/cache-precreation-07b4325/RESULT.md)。另已准备d62675f fresh → 9763482升级的同helper/Core、不同封印App版本对，两源CI通过，实际升级未执行；[产物对](../evidence/app-only-upgrade-pair/RESULT.md)。


2026-11-05 固定Core独立LaunchDaemon无TUN生命周期候选已冻结于85834ab，完整清单、源blob和无害自测及独审通过，尚未执行真实root job/Core。normal先通过再独立kill epoch，retire仅清job、root证据保留；不能把它算生产恢复/完整卸载。新组合须一次专门窗口授权，具体产物、10–15分钟步骤、范围与停止/恢复边界见[可执行准备](../evidence/lifecycle-core-preparation-85834ab/RESULT.md)。


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
