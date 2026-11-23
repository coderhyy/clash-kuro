# 统一 TUN 状态、配置与权限契约

Status: needs-info
Type: task
Blocked by: 01、02；涉及 ADR 变更时等待主会话记录批准决定
Owner: 主会话指定的共享契约 agent；主会话先集成

## 负责范围

`packages/core/src/index.ts`、`config.ts`、`fake.ts` 与对应测试；`packages/state/src/index.ts`、`fake.ts` 的公开类型/fixture；选定的桌面权限协议定义及必要调用方适配。03 统一类型，06 再实现 store/UI 行为；同文件修改由主会话分阶段分配。

## 验收标准

- 按 D3 定义偏好、实际状态、授权/失败/未知的可观测语义，沿用现有 Platform 注入边界。
- Profile → Override → App-managed Fields 顺序与 TUN 字段归属有测试；旧 settings 和 Backup 的兼容规则按批准决定覆盖；Profile 原文不变。
- 特权协议操作、调用者与产物身份、路径/参数验证、状态查询、停止/失败门禁明确；不接受任意 shell 命令或任意提权可执行路径。
- 共享包仍无平台/DOM 依赖；FakePlatform 能支撑无权限、拒绝、成功和状态不确定的单元测试。
- 类型检查及受影响 Core/State 测试通过，主会话集成公共契约后再启动 04/05/06 源码工作。

## Comments

2026-11-03：尚未选定任何新 API 名称或设置字段；当前 `tun` 透传不能用作应用 TUN 开关的完成证明。
