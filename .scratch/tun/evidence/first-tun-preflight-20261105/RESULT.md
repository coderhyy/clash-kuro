# 首次TUN窗口：安装前停止

用户已确认关闭第三方隧道。包SHA256仍为2f14fcde80dcfc3e8fe61cf403001ce5d655549cf7dd5514f207c23aecaa825a。

只读基线原始证据：`/private/tmp/kuro-tun49-window-xl173x6z/baseline`，0700目录/0600文件。最初沙箱查询不可用，保留但不作为有效基线；有效基线在沙箱外只读取得。

IPv4固定池和split-default冲突已消失，物理默认出口en0，系统代理关闭。仍有scoped IPv6 utun defaults；无物理unscoped IPv6默认出口实证，不删除或修改这些接口。

实际DNS变为192.168.0.1，而冻结Profile为114.114.114.114。按已批准窗口的DNS不匹配停止条件，在安装/服务/网络操作前停止。未运行App、helper、Core，未安装或修改网络。

准备profile-router.yaml仅将三组DNS地址改为当前路由器，其余MATCH,DIRECT/双栈不变。SHA256：8e219e0a9098cbe6c617862e07e19951a225aaf606478ff46b6b3f167874b00a。真实createTunSessionConfig离线准入通过，不运行Core或-t。此替换待用户确认，不静默消费。

恢复措施：本轮未写系统状态，无需网络恢复或卸载；保留本地基线和原Profile。恢复窗口前仍重新核验基线、全部准确安装路径和receipts。
