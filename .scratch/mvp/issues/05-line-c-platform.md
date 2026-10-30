# 线 C：平台层

Status: resolved
Type: task
Blocked by: 01

只改 `apps/desktop/src/main/platform`。先用手写的 Runtime Config 启动 Core，不依赖线 A。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

Core：
- 实现 `Platform` 的启停 Core、文件读写。
- Runtime Config 经 `mihomo -t` 校验后原子写入（临时文件 + rename）。
- Control Channel：macOS socket 在 userData 下且权限 0600；Windows pipe 名每次启动带随机后缀（ADR-0002）。
- Node 的 unix socket / named pipe `Transport` 实现，供 `packages/api` 注入。
- pid 文件：对应进程的可执行路径与打包的 mihomo 一致才 kill，否则只删 pid 文件。
- 启动前检测 mixed-port，被占用时报错，不自动换端口。

System Proxy（macOS）：
- 用 `networksetup`，权限被拒时提示手动设置 127.0.0.1:mixed-port（ADR-0009）。
- 启动时只清理指向本应用 mixed-port 的 System Proxy。
- 退出、关机、注销：先关 System Proxy 再停 Core，带超时，不阻塞关机。

唤醒（ADR-0008）：
- Core 存活则 `DELETE /connections`，否则重启 Core；System Proxy 幂等重设。

Windows System Proxy 等 02 出结论，放到 07 实现。

## Answer

实现位于 `apps/desktop/src/main/platform/`，未改 Platform / Transport 等既有接口，未加依赖或引用参考项目源码。

### 导出 API

- `createDesktopPlatform(options): DesktopPlatform`：实现全部 Platform 方法，额外提供 `cleanupStaleSystemProxy(port)`、`shutdown({ timeoutMs })`。
- `createSocketTransport(channel | getChannel, { timeoutMs? }): Transport`：socketPath HTTP 与最小 WebSocket 客户端；默认请求/握手超时 5 秒，接收上限 8 MiB，支持文本分片、ping/pong、close、客户端掩码。
- `assertMixedPortAvailable(port)`：检查 127.0.0.1 上的端口，已在 startCore 内调用，也可由集成提前调用。
- `createSystemProxy({ os?, exec? })`、`SystemProxyPermissionError`：可单独使用的系统代理适配器和可识别的权限错误。
- `createResumeHandler({ platform, client? | closeAllConnections?, reapplySystemProxy })`：返回异步处理函数，合并重复唤醒事件；Core 存活时断开旧连接，否则重启。重启失败不会启用指向死 Core 的代理。
- 类型：`DesktopPlatformOptions`、`DesktopPlatform`、`Exec`。

### Options 与集成约定

```ts
{
  dataDir: string, // app.getPath('userData')
  corePath: string, // 非 setuid 的打包 Core 的绝对路径
  mixedPort: number | (() => number), // 建议 getter，跟随当前 Settings
  appProcessName?: string,
  userAgent?: string,
  powerMonitor?: { on('resume', listener): unknown; removeListener('resume', listener): unknown },
  exec?: Exec,
  spawn?: (file, args, options) => ChildProcess,
  fetchText?: Platform['fetchText'], // 可注入 Electron networking，默认纯 Node 实现
  os?: NodeJS.Platform,
  startTimeoutMs?: number, // 默认 10000，就绪等待
  stopTimeoutMs?: number, // 默认 2000，SIGTERM / SIGKILL 各阶段
}
```

- 文件名相对 dataDir，拒绝绝对路径、路径穿越、Windows ADS 和目录内 symlink；原子写入使用 0600 临时文件后 rename。内部文件是 `runtime.yaml`、`core.pid`。Runtime Config 先 `mihomo -t -d dataDir -f tmp`，失败保留旧文件并返回诊断。
- 首次生成 Runtime Config 前先取 `platform.controlChannel()`。Windows 每次 Core 重启会生成新 pipe、更新并重新校验 Runtime Config 的顶层 pipe 标量。Transport 建议始终使用 `createSocketTransport(() => platform.controlChannel())`，避免重启后客户端仍指向旧 pipe。
- macOS socket 优先为 dataDir/mihomo.sock，超过 103 字节时缩短为 dataDir/c；仍过长则报错，需集成选择较短 userData 路径，不退回公共临时目录。启动前 dataDir 权限设为 0700，socket 出现后设为 0600，GET /version 成功才完成启动。
- 启动流程应显式调用 `cleanupStaleSystemProxy(settings.mixedPort)`；只关闭启用且恰好指向 127.0.0.1:port 的 HTTP/HTTPS 项，不动其他代理。`getSystemProxy` 按网络服务顺序返回首个启用的 HTTP/HTTPS 配置。
- 退出、关机、注销的事件由 07 接线到 `shutdown({ timeoutMs })`；先尝试关系统代理，再停 Core，超时也 resolve，权限错误不阻断 Core 清理。shutdown 后不可再启动该实例。
- `onResume` 仅订阅/退订事件；调用异步 resume handler 时，事件监听器需自行捕获并展示拒绝错误。`reapplySystemProxy` 根据应用保存的开关状态幂等设置，不应无条件开启。权限错误需提示手动设置 127.0.0.1:mixed-port。
- 默认 fetchText 支持直连、HTTP 代理和 HTTPS CONNECT，经代理重试的策略仍归共享层；下载上限 32 MiB，单请求超时 30 秒，最多跟随 5 次重定向。

### 验证与未覆盖

- `bunx turbo test typecheck --force` 全部通过：8 个任务，平台 88 项测试，另有共享包 5 项测试；真实 mihomo 集成测试在本机实际执行，没有 skip。
- 开发用 mihomo 原文件为 root 所有且带 setuid/setgid（6755），普通用户无法 chmod 它创建的 socket。集成测试仅在临时目录复制并将副本设为 0700 后运行，随后删除；原文件未修改，二进制未入库。正式打包也必须使用非 setuid Core。
- networksetup 全部通过注入 exec 测试，未修改真实系统代理；未实测系统代理授权 UI、真实休眠/关机事件、Windows 真机。Windows System Proxy 按约定抛出 not implemented。
- Windows pipe 自动轮换针对生成器输出的顶层块映射标量（支持普通/单引号/双引号键）；未支持 flow-style 整份 YAML。该限制已在代码标记 shortcut，若线 A 改用 flow YAML 需同步调整。
