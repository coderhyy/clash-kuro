# eb4 正常窗口：fresh 恢复路由解析失败，未开启 TUN

授权源码 eb4beec05283c60dd99715bf2b702a58c0fb9d44；安装包 SHA256 78cc71471ca1674e19caf4630798878330b452fb5b6ef2894fbdbda0fbc717d7。用户确认Clash Verge退出后开始。仅安装此包，未替换或重试。

只读基线：没有Clash Verge App或Core；两个第三方常驻helper保留(PID833 party.mihomo.helper、PID53771 clash-verge-service)，不据此推定活动TUN。IPv4/default/router DNS 192.168.0.1均en0，代理关闭；DNS/IPv4与上次批准基线相同。IPv6仅awdl0/llw0链路本地地址变化，原scoped utun路由保持；不修改第三方。包与router Profile摘要匹配，安装目标/job/receipt无冲突。

实际fresh安装成功。实际App seal/pin/inventory与冻结包匹配，helper/Core及安装记录验证通过；加载准确job并打开App。自动恢复后 UI blocked/off 原始错误 `routes: invalid route mask`。没有导入Profile、没有点击开启、没有启动Core/TUN。不得记为实际ready、接管、DNS恢复或停止证明成功。

按失败即停规则，正常Quit退出App；以neverStarted=true、owner/network/work缺席、App/Core进程缺席、安装身份精确匹配为条件，卸载准确job并运行受保护卸载器。全部指定安装路径、socket、身份记录缺席；job print113；本应用进程为空。本次Installer receipt保存并核验安装时间后精确forget，独立读回exit1不存在。未凭PID补杀。

最终代理、完整DNS与dynamic DNS、IPv4/IPv6路由原始输出逐字节等于本次安装前baseline。无本次安装或网络残留待恢复。保留受限证据目录 `/private/tmp/kuro-eb4-window-_0l2m8iw`（0700；受限JSON/原始路由0600），普通用户候选数据 `/Users/hyy/Library/Application Support/Clash Kuro TUN Candidate`、既存Client父目录与历史证据不删除。

只读普通UID NET_RT_DUMP采样11004字节/62packet，直接调用生产decoder重现错误；raw SHA256 31dc246df7bd48d66d3852f4356e192206339c53fdaee86b3c08fc05dbb7ed03。确认kernel compact mask byte1=0xff被误当地址family拒绝；还发现合法LOCAL|HOST目的IPv6 zone与lo0出口不同被误拒。离线修复及独立审查继续，不在本窗口换包。原始网络数据仅保留本机，不公开提交。

本窗口已结束。外网IPv6、代理节点转发、TUN接管与正常恢复均未验证；新候选网络实验仍需新窗口。
