# macOS TUN 集成验收

Status: needs-info
Type: validation
Blocked by: 04 helper技术门、06生命周期接入与最终组合验证；01产品决定已resolved；真实start仍受完整native可信链/root schema/broker/owner及网络恢复边界阻塞；真实系统操作等维护者明确“开始”；不依赖 Windows 05/07
Owner: 主会话集成与最终验证；验收 agent 准备记录

## 负责范围

在同一源码/精确 App/helper/Core 产物上集成 [04](04-macos-privileged-adapter.md) 与 [06](06-state-and-ui.md)，核验最终 CI、打包和真实结果。沿用原票及原型证据，不新增验收票；Git/公共接线与同机器系统时段由主会话统一协调。

## 验收标准

- 自动检查、构建/打包与产物身份齐全；配置准入、双向互斥、失败/未知关门、退出与准确 owner 清理符合 ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)。正常重开先残留检查、TUN关闭且仅手动开启；[ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 的LAN/split DNS保持、无新DNS供应商、缺失/不支持DNS具体拒绝、显式DIRECT与无独立kill switch已批准，不再等待产品选择。
- 管理员授权安装/取消、精确产物绑定、完整客户端认证、有限 broker、升级/卸载与失败恢复按 04 核验；已安装不代表代理中，不借卸载丢失恢复能力。不依赖付费会员，fake/原语不代替真实权限证明。
- 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；操作前后读回路由/DNS/代理/进程及归属，恢复基线；未知结果如实保留。双栈固定模板/无高级 UI 已批准，具体参数依据固定版本作技术选择；核验root schema通过先于模板实现，候选未实验不能记通过；不静默关闭IPv6或夸大覆盖/防泄漏。开启与故障状态均提示无独立kill switch、路由消失可直连；验证不自动换DNS供应商/丢字段或因故障切DIRECT。
- 人工安装/卸载、路由/代理、登录项与会话实验须等“开始”，主会话串行并恢复基线；Backup 验收及恢复先于登录项。结果不泄露 Profile/订阅或私人证据，不复用旧包替新代码验收。

## Comments

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
