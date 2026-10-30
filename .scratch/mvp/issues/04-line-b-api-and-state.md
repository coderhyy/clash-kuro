# 线 B：通信与状态

Status: resolved
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

## Answer

- `@kuro/api` 新增 `createMihomoClient(transport): MihomoClient`；REST 字段映射、路径段编码、HTTP 错误 message 和三个流均用 FakeTransport 测试。
- `@kuro/state` 新增 `createAppStore(deps): Promise<AppStore>`、`buildTrayMenu(snapshot)`、`createSnapshotCache(bridge)`；新增类型 `AppStoreDeps`、`AppStore`、`TrayCommand`、`TrayMenuItem`。已有接口未修改。
- `@kuro/state/react` 导出 `useSnapshot(bridge): StateSnapshot | null`（初次加载前为 null，拉取失败进入 React error boundary）和 `useCommand(bridge, name)`。主入口不加载 React。快照订阅先于初次拉取注册，丢弃旧/重复 version，窗口重建重新拉取全量。

Deps 形状（Runtime Config / Profile 实现由集成层适配线 A，store 不依赖线 A 的新增实现）：

```ts
interface AppStoreDeps {
  platform: Platform
  client: MihomoClient
  buildRuntimeConfig(input: {
    profile: Profile
    settings: Settings
    controlChannel: ControlChannel
  }): string | Promise<string>
  refreshProfile(profile: Profile): Promise<Profile>
  hooks?: {
    onOpenWindow?(): void | Promise<void>
    onQuit?(): void | Promise<void>
  }
}
```

- `await createAppStore(deps)` 在返回前读取 `settings.json`，内容为 `{ settings, profiles, activeProfileId }`；不存在时使用默认设置，损坏时 reject，不覆盖原文件。返回值实现 StateBridge，并提供 `.store`（Zustand vanilla StoreApi）。命令串行执行，失败返回 `{ ok: false, error }`；setMode 先持久化再 PATCH，Core 停止时只持久化。
- `refreshProfile` 负责读取/拉取并保存 Profile 原始内容、返回完整 metadata（不得更改 ID；失败须保留旧内容）；`buildRuntimeConfig` 负责读取该原始内容并生成 YAML。校验和原子替换由 `platform.applyRuntimeConfig` 负责。删除 Profile 仅删除 metadata，不删除原始文件。
- 固定接口没有热重载方法，因此 Active Profile / Runtime Config 变更通过 Platform 停启 Core 生效；先验证配置，重启前关闭 System Proxy，成功后恢复。失败保留旧配置（校验失败时）或报告启动错误，避免遗留死代理。
- 托盘 label 为翻译 key，菜单项携带类型安全的 `{ name, input }`。宿主负责 IPC、窗口存在时的流生命周期、定时更新调度、启动清理/唤醒和关机超时；宿主回调异常也转为 CommandResult。
- React 为可选 peer，dev/peer 均使用 `react@19.3.1`。React 类型包有空 DOM 接口占位，边界自检改查真实 `document` 全局和 `Document.createElement` 方法，继续禁止 DOM 能力和 Node/Electron 依赖。
- 验证：worktree 根目录 `bunx turbo test typecheck --force`，8 个任务全部通过，45 个测试（api 12、state 31、core 2）；另通过 `git diff --check`。使用 Bun 1.4.4（PATH 的 Homebrew Bun 1.3.14 不支持仓库 lockfile v2）。未运行真实 mihomo / Electron E2E。
