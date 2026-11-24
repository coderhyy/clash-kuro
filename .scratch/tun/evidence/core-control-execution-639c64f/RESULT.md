# 639c64f 无 TUN Core 实验实际结果

状态：**normal失败；EOF未执行；约定残留核对完成；本次授权结束。**

执行产物源码639c64fbfd3d371057dfd59d8b01b882c8aebbe3。执行前指定runner/inventory/Core SHA256匹配，SHA256SUMS六项OK，inspect prepared/normalPassed=false，两个阶段均无既有receipt。普通用户UID501。见preflight.json。

真实执行仅一次`core-experiment --normal`，runner退出2。真实mihomo直接子进程PID12122（group/worker12121）在私有控制接口就绪前自行退出1：termination request=none、observed=true、exitCode=1、signal=null。version unconfirmed，没有ready事件，mode/select读回和两次NoIP FD观察未完成；不能记接口或正常启动停止通过。worker报告ESRCH仅反映子进程已退出，不是最初退出的原因。Core stdout/stderr在该冻结实现中为/dev/null，确切退出原因未获取，不能推断配置错误。

未执行EOF，未重试Core/-t，未新增强杀/脱组实验，未安装服务或修改系统代理/路由/DNS/登录项。不能把本次未完成的FD观察记为无瞬时网络访问证明。

## 停止和残留

- guardian结果groupAbsent=true；主会话随后只读proc_pidinfo分别核对Core12122和worker12121，均count0/errno3 ESRCH。没有按记录PID发送任何额外信号。
- worker报告ownerAbsent/workAbsent，独立文件核对确认owner.json及session-work（含config/socket）不存在。
- `/private/tmp/kuro-core-0jowSi`仅保留本次固定mihomo副本：UID501、0755、56810034字节，SHA256 f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9。遵循失败保留策略，未扩大删除。
- 产物目录保留normal-attempt/result，未生成normal-success；没有任何EOF receipt。证据副本见本目录。最终核对见residual-readback.json。

## 对下一步的影响

证明该精确Core确实被普通UID监督链启动且早退被准确观察/回收；失败不会放行EOF，工作目录可以在此路径清退。没有证明真实Core控制接口可用、成功启动后的正常停止、EOF、Electron退出、root helper、utun/双栈网络或异常恢复。

最小修复应是为新候选保留受保护、大小受限的Core stderr/stdout，以及失败时配置摘要/安全诊断证据；成功清理和失败保留语义需同步。先离线验证日志机制，再冻结新产物请求新的有限Core授权，以获取实际退出原因。不能原包直接重试，不能凭fixture通过猜测真实Core错误。现有root TUN的运行后卸载/真实网络恢复门禁继续保留。
