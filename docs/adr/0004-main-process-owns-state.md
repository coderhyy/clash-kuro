# 主进程是唯一状态源，关窗即销毁

关窗时 `destroy()` 窗口只留托盘，以省内存（参考：Clash Party 托盘模式 GUI 约 143 MB，macOS 实测）。因此主进程直接用 `packages/api` 与 Core 通信并持有状态，托盘读主进程。渲染进程的 `packages/state` 只是缓存，每次建窗时重新拉取，不能假设自己常驻。代价是重新打开窗口要冷启动渲染进程。

## Consequences

- `packages/state` 的核心是框架无关的 store（`zustand/vanilla`），运行在主进程；渲染进程只有一层薄 React hooks，经 IPC 订阅快照。
- 渲染进程不直接访问 Control Channel，只发有类型的 Command（`setMode`、`selectProxy`、`updateProfile` 等），由主进程执行。托盘与窗口走同一路径。
- 流量和日志是事件，不进状态快照。`StateBridge` 提供 `subscribeTraffic` 和 `subscribeLogs`，都返回取消订阅函数。主进程按订阅者计数：有订阅者且 Core 在运行时才连接 Core 的 `/traffic`、`/logs` WebSocket，最后一个订阅者取消后断开；Core 重启导致断流时自动重连。窗口销毁即取消订阅，所以 Tray Mode 下没有 WebSocket。
- 日志在主进程只保留最近 500 条（`LOG_BUFFER_SIZE`），新订阅者先收到这批再接收实时日志。
