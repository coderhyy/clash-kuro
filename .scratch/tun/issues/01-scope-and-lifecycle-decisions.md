# 首批 TUN 范围与生命周期决定

Status: resolved（产品决定完成，不代表实现/验收完成）
Type: decision
Blocked by: 无；安全实现与真实验收继续由04/06/08跟踪
Owner: 主会话协调维护者

## 负责范围

产品边界依 ADR-0014/0015、[0016](../../../docs/adr/0016-macos-tun-manual-start.md)、[0017](../../../docs/adr/0017-macos-tun-dual-stack.md) 与 [0018](../../../docs/adr/0018-macos-tun-network-boundaries.md)；实施汇合 [04 helper](04-macos-privileged-adapter.md)、[06 生命周期](06-state-and-ui.md)、[08 验收](08-tun-integration-acceptance.md)。

## 已批准与验收标准

- macOS 首版，传统管理员安装 LaunchDaemon + 小型 helper、可卸载；无付费会员前置，不使用 setuid Core/任意 root 命令路径，SMAppService/Developer ID/公证延期。
- 退出停 TUN/Core，仅清自有网络；安装不等于运行。TUN/System Proxy 互斥，确认旧退出后才启目标，未知关门。正常重开/登录启动先恢复残留，保持关闭，仅用户手动开启。
- 双栈固定模板、无高级参数 UI、参数可依据固定版本技术选择。不关闭用户 IPv6；两族路由/接口变化、AAAA/回退、停止/异常恢复与绕过测试由04/06/08取证。
- 保持 LAN/split DNS，不新增 DNS 供应商；使用明确且安全支持的 Profile DNS，缺失/不支持具体报错并拒绝，不静默换上游或丢字段。
- 遵守显式 DIRECT；故障不自动切 DIRECT/其他模式。首版无独立 kill switch，路由消失后系统可能直连；开启/故障说明明确提示，不宣称全流量/防泄漏。
- 产品选择已完成；root 有限 schema/可信链/准确 owner 与网络恢复仍须验证。真实系统操作仍等维护者明确“开始”。

## Comments

历史记录（当前决定以上文与 ADR-0018 为准）：

2026-11-04：ADR-0014 已接受上述产品生命周期。Status 仅因正常启用偏好与参数未决定而保持 needs-info，已批准部分不再当作全局阻塞。


2026-11-04：正常重开关闭/先残留检查/手动开启已批准，不再等待该产品选择；本票仅剩网络范围/参数，最终实现与证据待 04/06/08 回填。

2026-11-04 后续决定：ADR-0017 已接受双栈固定模板、无高级 UI、参数可技术选定，取代以上历史“网络范围/参数待批准”的描述。该检查点尚余的两组产品影响现已由 ADR-0018 批准；本票 resolved 仅表示产品决定完成，04/06 技术门与08验收继续。
