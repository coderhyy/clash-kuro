# macOS TUN 首版采用管理员安装的传统 LaunchDaemon

Status: accepted（安装路线；安全实现与真实验收仍须完成）

2026-11-04 维护者选择管理员授权安装传统 LaunchDaemon 与小型特权 helper，使 macOS TUN 首版不依赖付费 Apple Developer 会员。SMAppService、Developer ID 正式签名和公证延期，不作为本路线的前置条件；接受自管安装、身份校验、升级和卸载成本，不要求关闭 SIP 或全局关闭 Gatekeeper，不给整个 mihomo Core 设置 setuid。

helper 只接受有限、经验证的操作，不开放任意 root 命令、可执行路径或可绕过配置限制的控制接口。管理员安装确认绑定精确产物；受保护安装位置、调用者鉴权、Core/配置校验及失败恢复必须独立验证，ad-hoc 签名或文件摘要本身不证明发布者身份。ADR-0011 的外部可执行文件边界保留，不引入 Node addon/FFI；Windows 用户级 helper 不因本决定而提权。

ADR-0014 的可卸载、退出停止 TUN/Core、仅清理自有网络、模式互斥及异常恢复边界全部保留。正常退出后再次启动是否恢复 TUN、DNS/路由范围仍未决定；机制无关契约、测试和安装准备可继续。本决定不是人工验收的“开始”授权，真实安装、卸载、网络、登录项与注销操作仍等待明确开始；Backup 验收及恢复先于登录项。
