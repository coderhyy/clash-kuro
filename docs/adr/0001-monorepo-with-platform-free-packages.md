# Monorepo，共享包不依赖平台

为了以后用 React Native 复用逻辑，`packages/core`、`packages/api`、`packages/state` 不得依赖 fs、child_process、electron 和 DOM。系统能力通过 Platform 接口注入，`packages/api` 的传输方式也由调用方注入。`apps/desktop` 放 Electron 主进程和 React 界面。代价是多一层接口，桌面端单独做会更直接。

## Consequences

- UI 组件（shadcn/ui）是 DOM 组件，移动端要重写界面，只复用 `packages/state` 的 hooks。
