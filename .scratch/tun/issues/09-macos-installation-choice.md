# macOS 持久 helper 安装路线决定

Status: resolved
Type: decision
Blocked by: 无（路线选择已解决；技术安全设计/实现另 04，真实系统操作另等“开始”）
Owner: 主会话记录维护者决定；macOS 平台 agent 承接 04

## 负责范围与交付物

维护者已选择 [ADR-0015](../../../docs/adr/0015-macos-traditional-privileged-helper.md) 的传统管理员安装 LaunchDaemon + 小型 helper，不依赖付费开发者会员；SMAppService、Developer ID、正式公证延期。[安装路线记录](../macos-installation-options.md) 保留比较与先前一手研究事实；不将历史 SMAppService 建议当当前选择。

## Answer

路线决定已完成。禁止 setuid Core、任意 root 命令或路径接口；安装不等于继续代理，必须可卸载，退出 App 停止准确 Core/TUN 并只清理本应用网络。ADR-0014 生命周期边界继续有效。

具体授权安装入口、受保护目录、产物与调用者认证、最小 IPC、升级/卸载及失败恢复由 04 的 `../macos-helper-security.md` 方案明确，经主会话接受后实现。此技术依赖不重开路线或付费签名身份选择，不以 resolved 宣称实际安装和网络验收完成。

## 验收标准

- 已记录维护者明确路线与不依赖付费会员的约束；引用 ADR-0015。
- 明确 SMAppService/Developer ID/公证延期，既有研究事实保留；产品最低 macOS 与安全可行性由 04 核对，不暗示传统机制无需安全校验。
- 04 承接安装、认证、升级、卸载和失败恢复技术设计/实现；06（含原03/10）的契约/既有入口测试不再等待本票。
- 正常重开关闭/先残留检查/手动开启已由 ADR-0016 批准；DNS/路由与 IPv4-only 仍归 01 未决，安装路线不批准网络模板。
- 没有执行真实授权安装、卸载或网络实验；用户明确说“开始”后才由主会话协调。

## Comments

2026-11-04：先前比较建议 SMAppService，但维护者现已选择传统管理员安装 LaunchDaemon + 小型 helper。本票由 needs-info 转 resolved；剩余安全设计/实现归 04，不继续以身份或路线待选阻塞。
