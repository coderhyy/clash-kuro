# 骨架与接口约定

Status: resolved
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

## Answer

- 打包验证：electron-builder 26.18.0 在 macOS arm64 产出 `Tern.app`，asar 内无 `node_modules`，`TERN_SMOKE=1` 启动输出 `TERN_SMOKE_OK`。用 `bun run package`（`apps/desktop`）复现。
- 版本：bun 1.4.4、turbo 2.11.10、TypeScript 7.0.2、Vitest 5.0.5、Electron 45.1.0、electron-vite 6.0.0、Vite 8.3.5、React 19.3.1。
- 平台边界：共享包用 `tsconfig.shared.json`（无 DOM lib、无 @types），每个包的 `src/boundary.check.ts` 用 `@ts-expect-error` 保证 fs/child_process/electron/DOM 不可解析；共享包可用的全局只有 `shared-globals.d.ts` 中列出的。
- 接口：`Platform`（`packages/core/src/index.ts`）、`Transport` 与 `MihomoClient`（`packages/api/src/index.ts`）、`Commands`、`StateSnapshot`、`StateBridge`（`packages/state/src/index.ts`）。
- 假实现：`@tern/core/fake` 的 `FakePlatform`、`@tern/api/fake` 的 `FakeTransport`、`@tern/state/fake` 的 `FakeBridge` 与 `fakeSnapshot()`。
