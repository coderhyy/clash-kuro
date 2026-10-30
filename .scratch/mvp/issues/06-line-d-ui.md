# 线 D：界面

Status: resolved
Type: task
Blocked by: 01

只改 `apps/desktop/src/renderer`，用假状态快照开发。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

- shadcn/ui（Base UI + Tailwind v4，ADR-0007），文案全部走 i18n，提供 zh-CN。
- 页面：Profile 列表与导入、Proxy Group 选择、Mode 切换、System Proxy 开关、设置（mixed-port、Update Interval）、Subscription Info 展示、更新失败标记。
- 所有操作只发 Command，不直接访问 Core。
- 流量与日志的 WebSocket 只在窗口存在时订阅。

## Answer

- 已完成中文界面：Profile 列表、远程 URL / 本地路径导入、启用/更新/移除、Subscription Info、更新失败标记、Proxy Group / 延迟、Mode、System Proxy / manualRequired 提示、Core 状态与错误、mixed-port、单个远程 Profile 的 Update Interval、新版本手动下载提示。
- 界面操作仅通过 `StateBridge.run`；展示 `ok: false` 和 Promise 异常，不修改既有共享接口。所有固定文案位于 renderer 的 `i18n/zh-CN.ts`。
- 本地 `useSnapshot` 使用 `useSyncExternalStore`，先订阅再读取，丢弃较小 version，并处理初始读取竞态及取消订阅；集成时替换为线 B 的 `@kuro/state/react` hooks。
- 未暴露 `window.kuro` 时回退至 renderer 内的 `DevBridge extends FakeBridge`；演示模式可交互，但不读文件、不下载、不解析 Profile、不持久化，也不模拟真实 Core I/O。
- Base UI 使用当前包名 `@base-ui/react`。shadcn CLI 的 add 不识别 electron-vite 的 `tsconfig.web.json`，因此通过官方 CLI view 取得 base-nova 的 Button / Switch / Input / Badge 源码，仅调整本地 cn 导入与格式，配合 Tailwind v4 和本地主题使用。
- renderer 以外只改必要配置与此 issue：`apps/desktop/package.json`（仅 devDependencies）、`electron.vite.config.ts`（Tailwind 插件、@ 别名）、`tsconfig.web.json`（@ 类型路径）、`components.json`、根 `bun.lock`（保持 v2）。使用 Bun 1.4.4；系统 PATH 默认的 1.3.14 不支持本仓库锁文件。
- 校验：`bunx turbo test typecheck --force`、`cd apps/desktop && bun run build`；renderer 有 10 个 Vitest 单测。Playwright 检查了主要命令流程、Core 错误、更新失败、manualRequired、新版本提示及命令失败；自查 960×640 桌面截图和 390px 窄屏截图，无横向溢出。
- 待集成：需要扩展 StateBridge（流量与日志）；未创建任何流量/日志 WebSocket。另需主进程提供本地文件选择，并由主进程的窗口打开策略将新版本 HTTPS 下载链接交给系统浏览器（不在 renderer 引入 Electron API）。
- 未验证真实 preload / Core / 系统代理权限、Windows 真机或安装包；未 push、未合并。
