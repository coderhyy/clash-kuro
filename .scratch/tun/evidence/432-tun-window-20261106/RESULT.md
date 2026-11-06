# 432 真实正常窗口：启动就绪失败，恢复及准确卸载完成

源码 `432d134b8ecd244483126795be850b64782c2209`，包 SHA256 `14f42dfae56ed09faae2e22df1181981bf3044b10fb90999fa1d35ab6dc33ad9`；双平台 CI42152178401成功、包源码字节独审通过。用户持续正常窗口授权下执行；不包含helper强杀/开启时App退出/升级。

同版本真实生产只读preflight通过，fresh安装和实际Electron鉴权恢复ready成功。使用原批准router Profile，单次TUN开启真实启动固定root mihomo，日志utun6仅IPv4；原始错误 `fixed dual-stack utun addresses are not uniquely ready`，失败阶段 `process and network readback`。未通过双栈就绪，未取得流量接管验收证据，未做正常on→off验收。UI的2秒open超时掩盖该原始错误。

Core收到SIGTERM并exit0、wait/reap和日志EOF完整，networkRecovery restored=true。初次失败后的代理/DNS/双族路由快照与基线一致。后续App已鉴权恢复off，真实format1 held证明持久保存，childReaped/cleanupComplete/routesOff/dnsOff为严格true；独审复核manifest、inventory、installed、owner和session摘要绑定。

退出App后准确bootout；第一次即时print仍SIGTERMed，脚本停在原生卸载之前。随后独立print确认job缺席，重新验证当前证明/精确身份，原生卸载器started分支成功。独立核查安装路径、App/helper/Core进程、job/socket/身份记录缺席；仅forget安装时间1793933494的本轮dev.kuro.tun.disabled receipt，确认缺席。没有凭旧PID终止、删除未知文件或修改第三方网络。

清理前路由文本出现局域网动态邻居缓存等差异，逐字节baseline比较停止了第一次清理脚本，未执行bootout。保留原始差异，后续仅准确job和原生安装清理，不操作这些路由；不能将最终状态声称为与旧路由文本逐字节相等，下一轮需重新只读核对。

## 保留

- `/private/tmp/kuro-432-window-35jf6tax`：0700，基线、诊断、停止证明、安装/卸载和receipt/缺席记录；索引摘要见private-evidence-inventory.json。
- `/Library/Application Support/Clash Kuro/TunDiagnostics/A4C7FE6B-F5B4-401C-B5A6-77FD7C0FEA9D`：受限原始Core诊断和脱敏运行配置，保留用于定位。
- 普通用户 `Clash Kuro TUN Candidate` 用户目录：已批准测试Profile和候选状态，按既有策略不随安装卸载删除。

下一修复仅固定spawn环境兼容上游IPv6探测和客户端open预算。双栈utun、DNS接管、流量及正常停止仍待新候选真实验证；MATCH,DIRECT不能证明代理节点，外网IPv6未验证。

只读离线复核补充：IPv4原9条完整保留，新增37条H/L/W邻居clone；IPv6原53条destination/flags/interface保留，新增20条en0邻居clone。其中4条本机link-local UHLI/lo0的gateway从统一masked值变实际MAC，baseline ifconfig也显示masked值，但缺同权限cleanup ifconfig/raw，不能断言显示变化原因。所有default、原utun0–5、非缓存前缀未变，无utun6/固定池/split残留。独立比较器8项纯比较自检通过，路径 `/private/tmp/kuro-432-route-difference-review`；下轮统一采集权限并保留严格gateway差异，不通过过滤掩盖。
