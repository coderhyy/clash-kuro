# 集成

Status: ready-for-agent
Type: task
Blocked by: 02, 03, 04, 05, 06

把四路接起来：主进程装配 `Platform`、`Transport`、store，preload 暴露 Command 与状态快照订阅。

## 验收

全流程：
- 跑通：导入 Profile（远程 URL 与本地 YAML，原始内容只读保存）→ 生成 Runtime Config → 启动 Core → 选择 Proxy；可切换 Active Profile。
- 定时更新：先直连，失败再经 Core 代理重试一次；成功后自动生成 Runtime Config 并重载，`mihomo -t` 失败保留旧配置并提示（ADR-0003）。

Windows System Proxy：
- 按 02 的结论实现，设置当前用户代理且已打开的程序立即生效，不引入 Node 原生模块；启动清理、退出清理与 macOS 规则一致。

外壳：
- 单实例锁，再次启动时聚焦已有窗口。
- 托盘：把线 B 的托盘菜单模型接到 Electron `Tray`/`Menu`。
- 关窗 `destroy()` 窗口进入 Tray Mode；Tray Mode 下无 WebSocket 订阅。
- 启动时查询 GitHub Releases，有新版提示手动下载（ADR-0010，仓库地址待定）。

验证：
- 记录 Tray Mode 内存占用（对照 Clash Party 约 143 MB，macOS 实测）。
- macOS 上 electron-builder 打包，安装后全流程可用。
