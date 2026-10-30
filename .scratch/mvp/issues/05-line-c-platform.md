# 线 C：平台层

Status: ready-for-agent
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
