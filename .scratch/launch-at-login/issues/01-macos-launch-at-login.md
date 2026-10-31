# macOS 开机自启

Status: resolved
Type: task
Blocked by:

按 `../spec.md` 实现。

## 验收

- 设置面板有开机自启开关，默认关闭；打开或关闭会调用系统登录项，快照随之更新。
- `requires-approval` 时开关保持打开，显示提示和“打开登录项设置”按钮；主进程只打开这一个固定 URL，不接受渲染端传 URL。
- 开发模式下开关禁用并提示“仅打包版可用”；Windows/Linux 不显示开关。
- `wasOpenedAtLogin` 为真时不建窗口、隐藏 Dock；其余启动行为不变。
- 窗口获得焦点时重新读取登录项状态。
- `bun run test`、`bun run typecheck` 通过；store 的 Command 和登录项状态映射有单测。

## Comments

2026-10-31 实现：`Platform.getLaunchAtLogin/setLaunchAtLogin`（`packages/core`），快照 `launchAtLogin` 与 Command `setLaunchAtLogin`、`AppStore.refreshLaunchAtLogin()`（`packages/state`，经命令队列串行），`apps/desktop/src/main/platform/login-item.ts` 映射 Electron 登录项状态。登录启动用 `wasOpenedAtLogin` 隐藏 Dock、不建窗口。打开登录项设置走固定 URL 的 IPC。`bun run test`、`bun run typecheck` 通过；设置面板在演示模式截图确认布局。登录启动和 ad-hoc 签名注册未实测，见 02。
