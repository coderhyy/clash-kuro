# macOS TUN 保留本地网络与 DNS，明确直连边界

Status: accepted

2026-11-04 维护者批准：首版双栈固定模板保持 LAN 与现有 split/scoped DNS 可达，不添加 DNS 供应商，复用 Profile 明确提供且通过有限 schema 的 DNS；缺失或不支持的 DNS 必须说明具体原因并拒绝启用，不静默替换上游或丢弃配置。Profile 的显式 DIRECT 行为继续生效，失败不自动切 DIRECT 或重新开启另一种代理模式。

首版没有独立 kill switch；TUN/路由消失后系统可能恢复直连，这一边界已接受，开启说明和故障状态都须明确提示，不宣称全流量接管或防泄漏。正常重开和登录启动仍依 [ADR-0016](0016-macos-tun-manual-start.md) 保持 TUN 关闭；[ADR-0017](0017-macos-tun-dual-stack.md) 的双栈固定模板/无高级 UI 不变。产品边界已明确，root schema、完整客户端可信链和自有网络恢复的验证仍须完成；本决定不授权真实系统操作。
