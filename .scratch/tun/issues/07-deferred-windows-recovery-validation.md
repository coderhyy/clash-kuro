# 补齐已延期的 Windows 取消会话与恢复验收

Status: needs-info
Type: validation
Blocked by: 主会话确认精确 Windows 产物与原 issue 08 整合状态；维护者选择本轮实验范围和系统状态时段
Owner: Windows 验收 agent 准备；主会话协调用户执行

## 负责范围

沿用 `.scratch/mvp/issues/08-windows-system-proxy.md` 与 `.scratch/mvp/prototypes/wininet-recovery/FORMAL-APP-RESULTS.md` 的原始证据和最小提案；此处仅接续三项已明确延期的验收，不新建一套历史结果。结果回写既有报告应由主会话指定唯一编辑者。

## 验收标准

- 先完成保留 admitted journal、owner 排除的隔离 fake 故障验证，列出精确产物、备份/只读前后状态和恢复标准。
- 真实取消关机：有原生 query 及实际取消证据，精确 Core 已停，存活 App 显示需重启/代理未知，并拒绝 UI/托盘重写；无 query 或关机未取消记未成立，不盲目重试。
- 启动恢复：真实残留在恢复前有证据，旧 writer 确认退出，新 App 在任何新 set 前恢复；没有 Active Profile 时也覆盖契约。父 EOF 自动清理不算 journal 回放。
- 显式 retained-helper 恢复用独立受控案例；确认保留路径、结果、退出和原状恢复，不能一次案例同时抵两类恢复。
- 每例确认基线恢复；未知、失败与未成立保留原样。未采用 RunOnce，不扩大到物理断电、服务、全 RAS 或高负载矩阵。
- 同机器与自启/Backup/TUN 的代理、登录项、路由和会话操作串行。真实操作范围需要主会话与用户确认，准备资料本身可并行。

## Comments

2026-11-03：`62505cc` 明确这些是延后至 TUN 的未验证风险，未授予新实验或改变 issue 08 合并限制。本票尚未执行真实实验。
