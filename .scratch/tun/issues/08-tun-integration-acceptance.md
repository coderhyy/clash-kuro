# macOS TUN 集成验收

Status: needs-info
Type: validation
Blocked by: 04安装后动态鉴权/生产service-network汇合/真实双栈归属恢复、06最终组合验证；01已resolved，root闭合schema已有隔离证据；新真实系统实验须另获授权；不依赖Windows05/07
Owner: 主会话集成与最终验证；验收 agent 准备记录

## 负责范围

在同一源码/精确 App/helper/Core 产物上集成 [04](04-macos-privileged-adapter.md) 与 [06](06-state-and-ui.md)，核验最终 CI、打包和真实结果。沿用原票及原型证据，不新增验收票；Git/公共接线与同机器系统时段由主会话统一协调。

## 验收标准

- 自动检查、构建/打包与产物身份齐全；配置准入、双向互斥、失败/未知关门、退出与准确 owner 清理符合 ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)。正常重开先残留检查、TUN关闭且仅手动开启；[ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 的LAN/split DNS保持、无新DNS供应商、缺失/不支持DNS具体拒绝、显式DIRECT与无独立kill switch已批准，不再等待产品选择。
- 管理员授权安装/取消、精确产物绑定、完整客户端认证、有限 broker、升级/卸载与失败恢复按 04 核验；已安装不代表代理中，不借卸载丢失恢复能力。不依赖付费会员，fake/原语不代替真实权限证明。
- 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；操作前后读回路由/DNS/代理/进程及归属，恢复基线；未知结果如实保留。双栈固定模板/无高级 UI 已批准，具体参数依据固定版本作技术选择；核验root schema通过先于模板实现，候选未实验不能记通过；不静默关闭IPv6或夸大覆盖/防泄漏。开启与故障状态均提示无独立kill switch、路由消失可直连；验证不自动换DNS供应商/丢字段或因故障切DIRECT。
- 人工安装/卸载、路由/代理、登录项与会话实验须等“开始”，主会话串行并恢复基线；Backup 验收及恢复先于登录项。结果不泄露 Profile/订阅或私人证据，不复用旧包替新代码验收。

## Comments

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
