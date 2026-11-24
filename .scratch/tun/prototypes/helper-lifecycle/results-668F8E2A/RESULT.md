# 实验 A：已执行并清理

2026-11-04；macOS 27.2 (26B123)，arm64。用户明确授权仅本独立无网络实验。epoch `668F8E2A-414B-476C-A648-1DC49D24788B`。

## 结果

**本次 child 由 launchd 清理，未依赖停止标记或 300 秒自退出。**

- 初始与强杀前：supervisor 59565、child 59591 均匹配原启动身份；同一进程组 59565。强杀前会话耗时 281ms。
- 固定 job 的 `launchctl kill SIGKILL` 后，约 1s（会话耗时 1330ms）和 5s（5362ms）两次观察均为 supervisor/child absent；job 为 not running、runs=1、last terminating signal=9。
- 早期检查没有 stop marker 或 child-exit receipt，未到 300 秒期限；驱动输出 `GROUP-CLEANUP-PASS (this fixture only)`。
- 后续 cleanup 才写入停止标记，此时两个进程早已不存在；约 35s 再次核验两者 absent，bootout 精确 job，并删除本次清单文件。不存在 self-exit receipt。
- 最终独立只读检查：launchctl 返回 113 / Could not find service；binary、plist、实验数据目录均不存在。共享 `/Library/Application Support/Clash Kuro` 父目录和用户态 review/build 目录按约定保留。

## 保存证据

- `hashes.txt` / `target-preflight.json`：驱动和 payload 摘要、初始固定目标不存在。
- `01-install.log`：sudo 无缓存，未安装；`02-install-native-authorization.log`：用户在原生管理员窗口授权后安装成功。
- `03-run-and-kill.log`：完整 launchctl 输出与身份采样；`.txt` 为仅转换换行的可读副本。
- `04-cleanup.log`：删除前完整 approval/evidence、两次 absent 和精确清理成功；`.txt` 为可读副本。
- `approval.json` / `evidence.json`：从保存的原始日志提取，保留进程启动时间、文件 device/inode/hash 和 epoch。
- `05-final-readback.json`：最终 job/路径不存在；`host.txt`：系统版本与架构。

## 对生产设计的影响

`AbandonProcessGroup:false`、子进程不脱组、`KeepAlive:false` 的组合在本机此 fixture 上提供了 helper 强杀后清理进程组的实证。生产继续采用同一策略，并保留准确直接子进程监督、会话失联停止与启动前残留检查。不能只凭本实验去掉恢复门。

该 fixture 不运行 mihomo，不持有 utun、不写路由/DNS。尚未证明固定 Core 不脱组、无后代持有接口、Core 被清理后网络状态可恢复。下一项系统实验须先准备固定 Core 的最小接口实验与独立恢复措施，并另获授权；本次授权没有扩展到该实验。

客户端鉴权独立推进已批准的安装级有限授权；实际 Electron 运行时负例、App pin 安装接线、生产 Core/网络所有权恢复仍是具体阻塞。生产 start 拒绝门保持。
