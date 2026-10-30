# 线 B：通信与状态

Status: ready-for-agent
Type: task
Blocked by: 01

只改 `packages/api` 和 `packages/state`，用假 Transport 测试。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

api：
- 传输方式由调用方注入，包内不依赖 Node 或 DOM。
- 覆盖：`/configs`（读与 PATCH mode）、`/proxies`（列表与选择）、`DELETE /connections`、`/traffic`、`/logs`、`/connections` 流。
- 用假 Transport 写单测。

state：
- 用 `zustand/vanilla`，设计为运行在主进程（ADR-0004）。
- 实现 Command 清单的执行逻辑；托盘与窗口共用同一套 Command。
- Mode 切换先写应用设置再 PATCH 到 Core。
- 渲染端 hooks 订阅状态快照；窗口重建后能完整重新拉取。
- 托盘菜单模型：由状态快照生成菜单项（Mode、System Proxy、打开窗口、退出），点击映射到 Command。纯函数，有单测。
