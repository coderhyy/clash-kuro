# macOS 首版 TUN 的权限与退出边界

Status: accepted（产品与生命周期边界；安装路线后续由 ADR-0015 确定）

2026-11-04 维护者选择先交付 macOS TUN，接受管理员授权安装持久特权 helper，但必须提供卸载方式；退出 App 时停止 TUN 和 Core、清理仅由本应用创建的网络设置，helper 仍安装不代表继续代理。TUN 与 System Proxy 首版互斥，切换必须确认旧模式退出；异常后不自动重新开启 TUN，下次启动先检查并恢复本应用残留，无法确认时提示处理并阻止未经确认的新模式启动，以避免未知旧状态与新网络写入并存。

这进入 ADR-0009 延后的 TUN 权限工作；ADR-0011 的 Windows 当前用户 helper 边界保持不变，不能据此将 Windows owner 提权或引入 Windows 管理员服务。具体 macOS 安装/授权 API、身份鉴别、签名公证、升级卸载与恢复记录仍需技术选型，持久安装不等于批准自动重启代理或常驻转发。正常退出后的下次启动是否记忆启用偏好、首版 DNS/路由参数另在 TUN 规格中列为待决项；本决定不授权真实网络、安装或注销实验，维护者要求等其明确说“开始”后逐步验收。

后续决定：[ADR-0015](0015-macos-traditional-privileged-helper.md) 已选管理员安装传统 LaunchDaemon、小型 helper 路线；正式签名、公证与 SMAppService 延期。上述生命周期约束不变。
