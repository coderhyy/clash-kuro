# macOS TUN 集成验收

Status: needs-info
Type: validation
Blocked by: 04 helper技术门、06生命周期接入与最终组合验证；01仅具体产品影响，双栈/参数技术选型已批准；真实系统操作等维护者明确“开始”；不依赖 Windows 05/07
Owner: 主会话集成与最终验证；验收 agent 准备记录

## 负责范围

在同一源码/精确 App/helper/Core 产物上集成 [04](04-macos-privileged-adapter.md) 与 [06](06-state-and-ui.md)，核验最终 CI、打包和真实结果。沿用原票及原型证据，不新增验收票；Git/公共接线与同机器系统时段由主会话统一协调。

## 验收标准

- 自动检查、构建/打包与产物身份齐全；配置准入、双向互斥、失败/未知关门、退出与准确 owner 清理符合 ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)。正常重开先残留检查、TUN 关闭且仅手动开启。
- 管理员授权安装/取消、精确产物绑定、完整客户端认证、有限 broker、升级/卸载与失败恢复按 04 核验；已安装不代表代理中，不借卸载丢失恢复能力。不依赖付费会员，fake/原语不代替真实权限证明。
- 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；操作前后读回路由/DNS/代理/进程及归属，恢复基线；未知结果如实保留。双栈固定模板/无高级 UI 已批准，具体参数依据固定版本作技术选择；核验root schema通过先于模板实现，候选未实验不能记通过；不静默关闭 IPv6 或夸大覆盖/防泄漏。
- 人工安装/卸载、路由/代理、登录项与会话实验须等“开始”，主会话串行并恢复基线；Backup 验收及恢复先于登录项。结果不泄露 Profile/订阅或私人证据，不复用旧包替新代码验收。

## Comments

2026-11-04 组合检查：State127/127；桌面prepare/fetch-core最终23项及backup-ipc/Profile调用方17项通过；根`bun run typecheck`四包通过；diff空白检查通过。没有新CI或新验收包；2617cf9旧包不包含当前配置门禁、Backup停止证据及准备器。真实资源prepare命令因原生helper/pin尚缺exit1，未生成安装产物。这些结果不关闭本票或替代TUN真机验收。

2026-11-04：本轮只整合票据与已批准策略，尚无新增真实验收。04/06 的最终源码、自动检查、精确产物与人工证据待回填；Windows 07 独立保留。

2026-11-04 本轮后续：生产客户端/State/UI接线，阶段UI25项/renderer typecheck通过；主会话报告State151、desktop359通过/17skip、全量typecheck通过。原生仍关门拒绝未完成的可信链/root配置/未知清理；native修复、最终build/CI和精确产物仍待主会话回填。双栈范围不再待批，不复用2617cf9或早期计数证明新实现；真实系统操作仍无“开始”授权。

2026-11-04 集成检查点：API12、Core138、State166、Desktop376通过，共692项通过；Desktop16项按平台跳过。Desktop包含普通用户bundled Core loopback整合，网络写入mock，未运行App/真实helper安装。四包typecheck、production build和本地DMG构建通过；native隔离build/test、ad-hoc runtime签名与strict校验通过，prepare/package/fetch31项包含在Desktop计数内，不重复相加。两路独立复核后修复resume/退出竞态、严格代理停止读回、native --serve、preflight祖先验证与卸载恢复入口。

CI配置已串联native隔离测试→App dmg→disabled helper pkg，并保存source-commit/SHA256SUMS/helper pin/manifest。最终CI与精确产物记录由主会话下条结果追加，旧2617cf9不代替当前代码。TUN start/完整attestation/root schema与broker/native owner-death lease/双栈网络清理仍未交付；disabled pkg仅供审阅，不进入本轮Backup与登录项安装验收。真实系统操作没有“开始”授权。
