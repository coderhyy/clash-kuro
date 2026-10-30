# 骨架与接口约定

Status: ready-for-agent
Type: task

串行，越短越好。合进主干后 03–06 才能开工。

## 内容

按 ADR-0001、ADR-0011 搭建：`packages/core`、`packages/api`、`packages/state`、`apps/desktop`（electron-vite + React），Turborepo task `build`/`typecheck`/`test`，Vitest。

接口只写类型和必要的空实现，不写逻辑：

- `Platform`（`packages/core`）：启停 Core、System Proxy、文件读写。
- `Transport`（`packages/api`）：REST 请求与 WebSocket 流，由调用方注入。
- Command 清单（`packages/state`）：`setMode`、`selectProxy`、`updateProfile` 等，含参数与返回类型。
- 状态快照（`packages/state`）：主进程推给渲染端的完整状态。
- 各接口各给一个假实现（fake），供 03–06 测试和开发用。

## 验收

- `bun install && bunx turbo test typecheck` 通过。
- 三个共享包引用 fs、child_process、electron 或 DOM 类型时 typecheck/lint 失败。
- `apps/desktop` 的 `dependencies` 为空，electron-builder 能在 macOS 产出可启动的空壳应用（验证 ADR-0011 的打包假设）。
- 上述接口类型和 fake 已合进主干。
