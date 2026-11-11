# macOS TUN 保留本地网络与 DNS，明确直连边界

Status: accepted

2026-11-04 维护者批准：首版双栈固定模板保持 LAN 与现有 split/scoped DNS 可达，不添加 DNS 供应商，复用 Profile 明确提供且通过有限 schema 的 DNS；缺失或不支持的 DNS 必须说明具体原因并拒绝启用，不静默替换上游或丢弃配置。Profile 的显式 DIRECT 行为继续生效，失败不自动切 DIRECT 或重新开启另一种代理模式。

首版没有独立 kill switch；TUN/路由消失后系统可能恢复直连，这一边界已接受，开启说明和故障状态都须明确提示，不宣称全流量接管或防泄漏。正常重开和登录启动仍依 [ADR-0016](0016-macos-tun-manual-start.md) 保持 TUN 关闭；[ADR-0017](0017-macos-tun-dual-stack.md) 的双栈固定模板/无高级 UI 不变。产品边界已明确，root schema、完整客户端可信链和自有网络恢复的验证仍须完成；本决定不授权真实系统操作。

## 运行期路由变化的有限判定（2026-11-11）

CONT 前仍比较完整已批准基线。运行期的网络身份不定义为全部旧路由永远不变：在 held Core／utun 和固定五条路由已准确观察后，仅可容忍独立接口快照证明的本机 IPv4 地址轮换、IPv4 link-local、IPv6 link-local 和三种 scoped multicast 形状。原项删除须有保存的原接口证据，新项须有当前证据；名称／索引、Ethernet 类型、UP／RUNNING、link 网关及精确 flags／prefix 均需匹配，不能以 /32 或 HOST 猜测归属，也不能遮蔽已准入 literal 端点或系统 DNS 地址。

默认出口及网关、原物理接口索引、LAN／端点与 scoped DNS 路径、地址池／接管范围冲突、固定自有路由、held 进程身份、双族探针和 DNS 所有权条件保持。未知变化仍停止；对照被该门提前中断时记为 inconclusive，不推断 IPv4 出站成败。此变更不赋予任何新写入／清理权，不承诺任意 USB 或第三方路由变化均兼容。隔离真实 service 链回归不代替实机正常启停和流量证明，IPv4 ENETUNREACH 根因仍未确认。
