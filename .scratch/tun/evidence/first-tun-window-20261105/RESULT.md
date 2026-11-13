# 49f7dd6 首次TUN窗口：实际App启动门失败，未启动Core/TUN

授权包SHA256 `2f14fcde80dcfc3e8fe61cf403001ce5d655549cf7dd5514f207c23aecaa825a`；经用户另行批准的router Profile SHA256 `8e219e0a9098cbe6c617862e07e19951a225aaf606478ff46b6b3f167874b00a`。源49f7dd6，未修改或重试本包。

完整受限证据：`/private/tmp/kuro-tun49-window-xl173x6z`。baseline与recheck网络一致；192.168.0.1 DNS走en0，更具体LAN/host路由优于新/1，未实际启动TUN验证。物理IPv6默认出口不可用。

实际fresh安装成功；实际安装App的seal/runtime/fuses/ASAR/pin/完整inventory与冻结包一致，helper/Core字节匹配。准确job load -F成功并独立readback；kickstart后helper运行。实际App启动、UI可用，但TUN状态blocked/off：`root Core configuration and client attestation are not enabled`。尚未导入Profile，未点击TUN；Core/TUN/DNS服务/代理监听未运行。本次不能记为动态会话鉴权、接管、DNS、停止或网络恢复通过。

根因：KuroTunService init直接取legacy Status无条件blocked；store startup在off时跳过recover，adapter explicit recover又在off时短路；start要求ready，形成无ready入口。旧错误不是本次实际鉴权失败证据。未绕过门禁。

正常Quit菜单退出实际App。按准确neverStarted=true、无owner/network/work和App/Core进程缺席条件，bootout准确job，再受保护卸载器--uninstall成功。独立确认八个安装/身份/socket/App目标均不存在（包括symlink）；job print113；本应用App/helper/Core进程不存在。唯一Installer receipt dev.kuro.tun.disabled与本次安装时间匹配，安装前无该receipt，留存后精确forget并独立确认不存在。

final/proxy,dns,routes4,routes6原始输出逐字节等于关闭第三方隧道后baseline。没有修改第三方设置；是否重新开启第三方隧道由用户决定。

保留：上述0700证据目录；普通用户`/Users/hyy/Library/Application Support/Clash Kuro TUN Candidate`（隔离UI数据，未导入私人Profile）；预先存在的空Client父目录；历史root697/858证据未动。证据用于修复回归，未递归删除。无本次安装或网络残留需要恢复。

窗口结束。下一步最小源码修复+真实生产dispatch/adapter/store回归，独立审查，冻结新候选；不在本窗口替换产物或再次系统实验。
