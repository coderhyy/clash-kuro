# bun workspaces + Turborepo

用 bun workspaces（isolated 安装）和 Turborepo，换取安装和脚本速度。两个参考项目都用 pnpm，Turborepo 对 bun 的支持也还是 Beta，所以这条路的打包风险由下面的硬约束兜底。2026-10-30 实测 bun 1.4.4（lockfile v2）+ turbo 2.11.10 能识别 workspace；turbo 2.9.18 不认 lockfile v2，两者版本要一起升级。

## Consequences

- `apps/desktop` 的主进程和 preload 依赖全部由 electron-vite 打包进产物，`dependencies` 保持为空，一律放进 `devDependencies`，让 electron-builder 无依赖可收集。
- 不用 Node 原生模块。需要系统调用时用外部可执行文件（如 `networksetup`、小 helper exe）。
- 内部包用 `workspace:*` 引用，`exports` 直接指向 TS 源码，由 Vite 编译。
- 根 `package.json` 的 `packageManager` 和 `turbo` 版本固定，不跟随 latest 自动升级。
