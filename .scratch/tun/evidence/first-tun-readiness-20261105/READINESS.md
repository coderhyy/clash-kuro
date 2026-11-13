# 首次TUN正常启停前置与正式交付边界

审计时源码快照：3728bc7e90c1f1ed8d0d7e6bfe7b5addd5809dc8。未运行App/Core/服务/网络；本文命令仅供主会话纳入另行批准的窗口。

## 最新冻结候选（49f7dd6）

源码：49f7dd6e610e18b2a4c59c85b92f2c29045b95d4。标准原生测试（含普通用户固定Core -t）、硬化App、fresh包构建与CI通过；独立包审查通过，未安装。

包绝对路径：`/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-49f7dd6e610e.pkg`

SHA256：`2f14fcde80dcfc3e8fe61cf403001ce5d655549cf7dd5514f207c23aecaa825a`。

本候选已加入真实安装绑定和origin-only检查点恢复；下方3728审计中的“尚未冻结/不开放origin-only”仅描述旧快照。崩溃卸载/升级停止证明仍未交付，正常持有会话启停可独立验证。现场冲突与授权仍未解除。

## 历史审计结论（3728快照）

root无TUN 69728e6窗口已经完成；不重跑。首次TUN正常启停与App退出可独立准备，不能要求先完成helper SIGKILL后的全部恢复。当前实际阻塞是现场split-default冲突、包含最新修复的同提交finite-session产物尚未冻结，以及首次网络窗口授权/现场证据；不是“生产start永远拒绝”。dist现存fresh包至d62675f，不能把源码3728的行为归给旧包。auth-only包不能翻flag使用。

主会话最新只读baseline：/private/tmp/kuro-tun-readonly-baseline-q_9r369g（0700/0600）。代理Enabled均0，IPv4default en0；但既存utun拆分覆盖固定IPv4池并含128.0/1，当前preflight会在Core和网络写入前拒绝。不能猜第三方App或擅自改其状态；IPv4-only本身已支持。baseline在任何窗口开始前需重读，不将历史快照当当前事实。

最小Profile：.scratch/tun/evidence/first-tun-readiness-20261105/profile.yaml，显式MATCH,DIRECT、双栈DNS、三resolver列表均沿用当前baseline；仅离线createTunSessionConfig通过，尚无真实解析/路由验证。它只供首次正常启停，不证明代理转发、外网IPv6或所有split DNS。原始DNS/域名保持本地受限。

## 实际启动门与证据

| 门 | 当前代码（apps/desktop/native/mac下除另注） | 窗口所需实际证据 |
| --- | --- | --- |
| 真App/有限安装身份 | kuro-tun-helper.m:243、315、340；tun-install.m:278–298 | 新同commitApp/helper/Core/pin/inventory/plist/manifest和receipt；finite activation明确true、无未完成事务；不是旧ProcessRequest:280的stub |
| 无自动普通模式副作用 | apps/desktop/src/main/index.ts:182、308、327 | 已安装finite正常入口，固定隔离数据；startup inspect/recover真实；不读取普通产品Profile |
| 互斥/配置 | packages/state/src/store.ts:357–378；desktop/src/main/platform/index.ts:179 | active Profile+Override准入；原普通Core停完；严格全协议SystemProxy off，不清第三方来换取通过 |
| 现场网络 | tun-production-network.m:170–217 | 无PROTO2或UP /1冲突；一个可信IPv4物理default；IPv6default可无、有则同接口；无固定池冲突；原LAN/scoped DNS和所有literal端点有保留路径 |
| 监督/启动 | tun-service.m:601–612、659–688 | 固定Core、实际launchd监督快照、protected work/owner/cache、CONT前durable revoke、真实/version、PID-start→utun绑定、固定双栈地址和本机A+AAAA |
| 写入与读回 | tun-production-network.m:262–274 | 原baseline不变；四条双族split先于临时DNS；实际readback和持续确认。无外网IPv6可仅记本机双栈，不声称外网通过 |

## 只读baseline应保存的准确字段

- `/usr/sbin/netstat -rn -f inet`、`/usr/sbin/netstat -rn -f inet6`：destination/prefix、gateway、flags含scope/PROTO2/reject、ifname/index，特别default与/1及固定池的更具体覆盖；`/sbin/route -n get default`与`/sbin/route -n get -inet6 default`退出码也保存。
- `/sbin/ifconfig -a`及`/usr/sbin/scutil --nwi`：接口index、flags、linktype、双族地址、default实际物理出口。生产还要完整route/backend快照，CLI输出不能替代其完整枚举。
- `/usr/sbin/scutil --dns`及DynamicStore/Setup DNS键的只读list/show：ServerAddresses、InterfaceIndex、SupplementalMatchDomains/Orders、SearchDomains/SearchOrder、Options、resolver scope。不可只摘一IP就宣称分域优先级无损。
- `/usr/sbin/networksetup -listallnetworkservices`，逐原service执行`-getwebproxy`、`-getsecurewebproxy`、`-getsocksfirewallproxy`、`-getproxybypassdomains`；保存Enabled/Server/Port/auth/bypass，禁止改设置。
- `/bin/launchctl print system/dev.kuro.tun`、`print-disabled system`；准确安装manifest/receipt/hash、owner/work/network.json/network-dns.json/stopped.json是否存在和保护属性；只读留证，不清未知项。

## 首次窗口的可执行停止与失败收尾

1. 前置通过并获准后才fresh安装新精确包。固定job命令为`sudo /bin/launchctl load -F /Library/LaunchDaemons/dev.kuro.tun.plist`→独立`/bin/launchctl print system/dev.kuro.tun`→准确identity匹配后`sudo /bin/launchctl kickstart -p system/dev.kuro.tun`；不用-w/enable/fallback或-k。此OS legacy路径尚需实证，不支持即停止。
2. 从固定受保护App正常入口手动开启。失败时先停止新流量/新模式写，仍持有会话优先App关闭TUN；native仅对本实例unreaped child发TERM/KILL并准确reap（tun-session.m:475–491），网络恢复不被日志保存失败短路（service:648–658）。
3. 若Core已reap但DNS/route/日志/work清理失败，不先bootout helper。使用同一准确App“检查并恢复TUN”按钮（renderer app.tsx:901 → store recoverTun:383 → macos-tun.ts:304）。已断开的旧V2会话由原worker保留；真实V1 recover邮箱回原pthread重试（service:308–359）。2秒App响应超时不证明cleanup失败/完成；停止新操作并独立读回，不能反复开启。
4. 部分network：生产held恢复（network:295–300）需原owner确认，DNS失败时当前短路暂不尝试route；修正故障后同worker可重试。Core已退出且utun消失时，只接受自有route已消失；现存route/变化项不获删除权。fresh恢复（network:301–312）会独立尝试精确journal DNS移除和route absence确认；任一失败仍unknown。DNS已清不等于Core/routes/work清完。
5. 独立读回status off、准确Core/utun、自有四route/临时DNS、owner/work/cache清退、baseline保持、stopped.json正确绑定且durable，才允许`sudo /bin/launchctl bootout system/dev.kuro.tun`。off+blocked checkpoint error只证明物理off，不能当运行后卸载授权（service:513–529）。不要以bootout帮助失败的held cleanup；它会丢原worker。
6. job/socket/准确进程absent且有效stopped证明后，固定`sudo /Library/PrivilegedHelperTools/dev.kuro.tun-uninstall --uninstall`；job退出/文件卸载分别独立核验。诊断目录保留，不递归清证据。`--recover-client-upgrade`只恢复安装升级事务，不恢复TUN网络。

现有入口限制：没有root“强制网络恢复”CLI，也没有可执行的一键首次窗口driver/结构化baseline比较器；不能用Node/socat冒充App鉴权。现有App按钮+准确readback可做正常/部分失败窗口；不必为此新增daemon/通用driver。若需要完全自动化收尾，则还缺专用有限窗口脚本；本候选不宣称已有。helper不在时要先按已批准固定job方式恢复服务；unknown对象不授权重新装/覆盖。

## 单独未正式交付：helper强杀后完整恢复

fresh recover依次做独立network再旧owner/work门（service:364–425）：精确DNS journal可移除；route只消费absence；旧Core/监督PID和记录组必须完全可观察且absent，空组只是必要条件、不证明脱组writers退出，不发旧PID/PGID信号。cache必须最终精确receipt；origin-only在此审计源码仍拒；本轮绑定/检查点增量集成后以其新证据为准。未知文件保留。没有可执行且安全的完整crash uninstall/upgrade消费者证明，因此helper-kill不放进首次正常窗口。root无TUN组观察不能代替这些生产证明。

上述04/06缺口不妨碍准备正常stop/App退出；一旦首次窗口真实失败超出现有持有恢复能力，则停止窗口并保留证据，不以卸载/flush/reset/关闭IPv6/第三方修改解除阻塞。

## 历史文字处理

08顶部A已完成697，旧表822 pending和旧root未执行仅标历史；B旧4abee/d626产物不能代表最新源码。最低Profile“共同双栈默认出口”改为上述v4required/v6optional；普通mac stale端口猜归属的旧说明标已被准确本实例归属修复覆盖。保留原历史证据与失败事实，不删除。
