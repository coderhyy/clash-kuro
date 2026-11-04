# 首批 TUN 范围与生命周期决定

Status: needs-info
Type: decision
Blocked by: 仅 LAN/分域 DNS 与上游隐私、DIRECT/无独立 kill switch 两组具体产品影响；双栈/固定模板/参数技术选型已批准，不阻塞安全与隔离验证
Owner: 主会话协调维护者

## 负责范围

产品边界以 ADR-0014/0015 和 [ADR-0016](../../../docs/adr/0016-macos-tun-manual-start.md) 及 [ADR-0017](../../../docs/adr/0017-macos-tun-dual-stack.md) 为准；实施汇合 [04 helper](04-macos-privileged-adapter.md)、[06 生命周期](06-state-and-ui.md)、[08 验收](08-tun-integration-acceptance.md)。

## 已批准

- macOS 首版；传统管理员安装 LaunchDaemon + 小型 helper、可卸载，不依赖付费会员；SMAppService/Developer ID/公证延期，无 setuid Core/任意 root 命令路径。
- 退出 App 停 TUN/Core，仅清理自有网络；安装不等于继续代理。TUN/System Proxy 互斥，确认旧退出后才启目标，未知关门。
- **正常重开 App 也保持 TUN 关闭，先检查/恢复自有残留，再由用户手动开启。** 异常、恢复、重连或唤醒不自动重开；未知提示处理并阻止写入，不从旧偏好或 Backup 恢复 TUN。
- **IPv4/IPv6 双栈固定模板、无高级参数 UI 已批准，具体参数允许依据固定版本与验证作技术选择。** 不再把 IPv6 范围或每个参数当作待批准项。
- 人工系统操作仍等待维护者明确说“开始”；本决定不是系统操作授权。

## 未决产品影响与验收标准

- 只集中 [spec 两组产品影响](../spec.md#剩余产品影响与具体技术门)：建议保留 LAN/分域 DNS、复用明确安全可支持的 Profile DNS、缺失拒绝而不另选供应商；建议遵守显式 DIRECT 且失败不自动切 DIRECT，但首版无独立 kill switch、utun 消失后 OS 可能直连。此两组影响等待维护者确认，不再逐项询问 stack/地址/MTU。
- 技术首个候选与固定源码见 [spec](../spec.md#固定版本事实与技术候选)：mips、双族 auto-route/auto-detect、native DNS/内部双族 DNS 端点与 redir-host；只是源码支持和待实验建议，没有可启用配置模板或真实网络结果。
- 04/06/08 覆盖 IPv6 路由、接口变化、双栈 DNS（AAAA/单族失败/回退）、停止/异常恢复与双栈泄漏测试。不关闭用户 IPv6，不声称全流量/防泄漏；root schema 验证先于模板实现。
- 已批准边界、具体产品影响、技术门及通过证据分别记录；原型/fake 不替真机。真正技术门为完整客户端可信链、root 有限 schema/broker、准确 owner 与自有两族路由/DNS 恢复，不以旧“IPv6未批”挂起它们。

## Comments

历史记录（以下待决描述已由 ADR-0016 更新）：

2026-11-04：ADR-0014 已接受上述产品生命周期。Status 仅因正常启用偏好与参数未决定而保持 needs-info，已批准部分不再当作全局阻塞。


2026-11-04：正常重开关闭/先残留检查/手动开启已批准，不再等待该产品选择；本票仅剩网络范围/参数，最终实现与证据待 04/06/08 回填。

2026-11-04 后续决定：ADR-0017 已接受双栈固定模板、无高级 UI、参数可技术选定，取代以上历史“网络范围/参数待批准”的描述。本票保留 needs-info 仅为上述两组产品影响；04/06 仍并行推进技术门与隔离验证。
