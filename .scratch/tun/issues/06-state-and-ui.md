# TUN 命令、状态和界面

Status: needs-info
Type: task
Blocked by: 03
Owner: State/UI agent

## 负责范围

`packages/state/src/store.ts` 与测试、`apps/desktop/src/renderer/src/app.tsx`、demo bridge、共享中英文文案和必要 IPC 接线。03 的类型先由主会话集成；Platform/native helper 交 04/05。

## 验收标准

- 按 D3 的开关/共存/持久化决定操作，偏好与实际状态、授权失败和未知状态表达准确。
- 开启、关闭、配置重载、Core 停止、App 退出之间的顺序复用批准的生命周期契约；失败不显示虚假成功或自动重新启用。
- fake 测试覆盖拒绝权限、异步失败/owner 退出、旧 settings/Backup 和 TUN/System Proxy 行为；跨平台调用不引入平台依赖。
- 中英文、demo 与可访问的忙碌/禁用状态同步；类型检查、State 与界面相关测试通过。
- 可与 04/05 并行用 fake 实现验证；真实联调和完成交付等待 08，不能以 UI 可点击标记平台已完成。
