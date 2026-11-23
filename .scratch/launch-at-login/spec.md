# 开机自启（macOS）

Status: in-progress（待 02 真机验证）

第二期第一个功能。术语见 `CONTEXT.md` 的 **开机自启**。只做 macOS。08（Windows System Proxy）在 `codex/08-windows-sysproxy` 分支上等真机验证，本功能不动它。Windows 等 08 合并后再补（issue 03）。

## 决定（grill-with-docs，2026-10-31）

1. 术语 **开机自启**（Launch at Login）：用户登录系统时由系统启动 Clash Kuro。_Avoid_ 自启动、登录项（登录项留给 macOS 系统设置里的条目本身）。
2. 以系统登录项为准，不写 `settings.json`，也不进 `Settings`（`Settings` 里是进 Runtime Config 的 App-managed Field）。启动时、每次切换后、窗口获得焦点时重新读取。
3. 登录启动时不弹窗、隐藏 Dock，直接进 Tray Mode。有 Active Profile 就照常启动 Core。用 `app.getLoginItemSettings().wasOpenedAtLogin` 判断（Electron 45 没有 `openAsHidden`）。
4. 登录后不恢复 System Proxy，维持现有“启动只清理、不重开”的规则。后续项：记住上次 System Proxy 状态并在启动时恢复。这会碰到 08 改的 `system-proxy`/`store.ts`，等 08 合并后再议。
5. 入口只在设置面板放一个开关，托盘不加，默认关闭。系统返回 `requires-approval` 时显示提示和“打开登录项设置”按钮（`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`）。
6. 开发模式（`!app.isPackaged`）下开关禁用，提示“仅打包版可用”，避免把裸 Electron 注册成登录项。
7. ad-hoc 签名下 SMAppService 的实际行为没有验证过，单开 `ready-for-human` 真机验证（issue 02）。Windows 暂时返回不支持并隐藏开关。

## 形状

- `@kuro/core`：`LaunchAtLoginStatus = 'unsupported' | 'unpackaged' | 'disabled' | 'enabled' | 'requires-approval'`；`Platform` 增加 `getLaunchAtLogin()`、`setLaunchAtLogin(enabled)`。
- `@kuro/state`：快照字段 `launchAtLogin: LaunchAtLoginStatus`；Command `setLaunchAtLogin({ enabled })`；`AppStore.refreshLaunchAtLogin()` 供主进程在窗口获得焦点时调用。
- 桌面端：`platform/login-item.ts` 把 Electron 的 `getLoginItemSettings`/`setLoginItemSettings`（默认 `mainAppService`）映射成上述状态。

## 内容

- `packages/core/src/index.ts`、`packages/core/src/fake.ts`
- `packages/state/src/index.ts`、`store.ts`、`fake.ts`、`store.test.ts`
- `apps/desktop/src/main/platform/login-item.ts`（新）及测试，`platform/index.ts` 接入
- `apps/desktop/src/main/index.ts`：登录启动走 Tray Mode；窗口聚焦时刷新；提供打开登录项设置的 IPC
- `apps/desktop/src/preload/index.ts`、`renderer/src/env.d.ts`
- `apps/desktop/src/renderer/src/app.tsx`、`dev-bridge.ts`、`i18n/zh-CN.ts`、`styles.css`

## 不做

- 登录后恢复 System Proxy（见决定 4）。
- 托盘菜单项、Windows 实现（issue 03）、Linux。

## Comments

2026-11-04：原定 Windows 后续项 03 的依赖已满足（PR #1 合入 main `6ea3720`）。Windows 登录项和 `--hidden` 托盘启动已在集成分支实现，沿用系统状态为准、打包版限制、不恢复 System Proxy 的决定；不新增共享接口。macOS 02 与 Windows 03 的真实登录验收仍分别待办，见各自票中的产物和通过标准。以上“只做 macOS / Windows 暂不支持”记录描述最初交付范围，不再代表集成分支的代码状态。
