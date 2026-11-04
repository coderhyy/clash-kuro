# 固定候选：无 Core 的动态鉴权实验

源码提交 `1ad5f06ad17495fd4e45cc1f94e54979bddf4842`。App 封印 sourceCommit/auth-only 标记与 native build report 均对应此干净实现提交；本目录是随后保存的证据，不是另一份实现快照。完整机器路径、摘要、参数、客户端负例和脚本 pin 见 [产物清单](../../auth-observation-artifact.json)。

**准备完成，等待本次实验授权；实际安装客户端鉴权尚未执行，不能称已通过。** 合法活进程签名夹具通过同一生产鉴权路径；不是“全部拒绝”。安装后的实际 Electron 正例必须独立成功。生产启动 gate 仍关闭，观察成功不授予 Core/network 能力。

- App 隔离矩阵 14 项通过：真实 Electron UI/preload IPC、内存 Backup 往返及约定调试/环境入口；未运行真实 Core 管理。
- desktop 446 通过 / 16 跳过，typecheck 通过；native 全套通过，显式跳过 mihomo -t。
- 修复 Installer /private/tmp 空 ACL 误拒绝，回归先失败后通过；有限外部客户端负例拒绝协议错误冒充身份失败。
- 解包 seal/pin、完整 App inventory、helper/sidecar 摘要相符；9 个固定 bundle、1255 条 BOM UID0、disabled plist 已核对。BOM 是预期安装元数据，不是实际 root 安装证据。
- 只读准备基线中目标路径、receipt 和 job 均不存在；正式开始前须再次检查，已有任何冲突立即停止。

实验按 [步骤](../../auth-observation-experiment.md) 预计 8–12 分钟：复核→fresh 安装→前台 auth-only observer→实际 App 正例/身份负例→等待退出→精确卸载及 receipt 清理。无 LaunchDaemon bootstrap；不运行 Core/-t、utun、代理、路由、DNS或登录项。固定 protected App 不替换 /Applications 副本，不使用其数据或登录项。

06 已接通生产 preflight/physical绑定/固定本地双栈探针/ready/apply/周期verify/同会话recover及network-only残留清退。仍缺真正跨 helper 重启的旧 Core 退出证明、owner.json及受保护工作目录安全清退实现；当前保留 unknown，不采信旧 PID。真实 mihomo/utun、LAN和分域DNS、路由读回、正常停止/断线/强杀恢复仍须另行授权的实机证据；本包不用于该实验。

完整升级仍是04交付要求；fresh-only不是完整升级已交付。未运行远端CI、未安装本候选、未运行真实网络实验。
