# macOS TUN 首版使用双栈固定模板

Status: accepted

2026-11-04 维护者批准：macOS TUN 首版使用统一的 IPv4/IPv6 双栈固定模板，不提供高级参数 UI；stack、路由和 DNS 等具体参数允许依据固定 Core 版本及验证结果作技术选择，不再把双栈范围当作待批准事项。正常重开与登录启动仍依 [ADR-0016](0016-macos-tun-manual-start.md) 保持 TUN 关闭，先检查/恢复自有残留，再由用户手动开启。

此决定批准覆盖范围与配置方式，不代表候选参数已经通过真机验证，也不选择新的 DNS 供应商、批准破坏 LAN/分域 DNS 或承诺全流量/防泄漏。固定版本证据、技术候选和最少产品影响问题集中在 [TUN spec](../../.scratch/tun/spec.md)；root schema 验证、完整调用方可信链和自有网络恢复证据通过前，不接入可启用的特权模板。真实系统操作仍须等待维护者明确说“开始”。

## 2026-11-06：固定 Core 执行自动路由

维护者批准将首版路由增删交给固定 mihomo v1.19.33 / sing-tun v0.4.28；移除 helper 的 PF_ROUTE writer，不保留 fallback。受限模板启用 auto-route，固定 route-address 为 IPv4/IPv6 各两个 /1；上游额外请求自身 IPv4 /30；五个 ADD 请求不等于已确认五条实际路由，启动仍需独立读回。该列表由 root 模板生成，不接受调用方任意路由参数。

helper 保留鉴权、固定 Core/配置校验、准确进程监督、互斥及重开关闭。DNS 暂维持现有 helper 实现（Core dns-mode disabled）。helper 在 Core resume 前持久记录基线和会话/固定 Core 绑定，随后只读核验 held utun 与实际合法路由；停止后独立核验接口及路由缺席、DNS/基线恢复。新观测记录不授权删除路由，旧手工账本仅允许证实缺席后的退役，未知对象保留。

理由：没有固定版本证据证明已批准产品边界必须使用 helper 自写路由；Core 已具备固定范围自动路由能力。Core 写入先于内部 DNS 就绪，失败必须停止准确 Core 并恢复。此决定不证明实机启停通过，也不改变无 kill switch、LAN/分域 DNS、DIRECT 或验收授权范围。源码依据及实际验收见现有 TUN spec 和 04/06/08。
