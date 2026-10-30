# 集成

Status: resolved
Type: task
Blocked by: 02, 03, 04, 05, 06

把四路接起来：主进程装配 `Platform`、`Transport`、store，preload 暴露 Command 与状态快照订阅。

## 验收

全流程：
- 跑通：导入 Profile（远程 URL 与本地 YAML，原始内容只读保存）→ 生成 Runtime Config → 启动 Core → 选择 Proxy；可切换 Active Profile。
- 定时更新：先直连，失败再经 Core 代理重试一次；成功后自动生成 Runtime Config 并重载，`mihomo -t` 失败保留旧配置并提示（ADR-0003）。

Windows System Proxy：
- 已拆到 08。

外壳：
- 单实例锁，再次启动时聚焦已有窗口。
- 托盘：把线 B 的托盘菜单模型接到 Electron `Tray`/`Menu`。
- 关窗 `destroy()` 窗口进入 Tray Mode；Tray Mode 下无 WebSocket 订阅。
- 启动时查询 GitHub Releases，有新版提示手动下载（ADR-0010，仓库地址待定）。

验证：
- 记录 Tray Mode 内存占用（对照 Clash Party 约 143 MB，macOS 实测）。
- macOS 上 electron-builder 打包，安装后全流程可用。

## Answer

2026-10-30 在 macOS 27.2 arm64 上，用打包后的 `Clash Kuro.app`（unsigned，`bun run package`）配合独立 `--user-data-dir` 和本机测试订阅服务器实测。测试脚本在仓库外（`/tmp/kuro-e2e/`）。

全流程：
- 导入远程 Profile（带 `subscription-userinfo`、`profile-update-interval`）和本地 YAML；Subscription Info 与 Update Interval 正确显示；存储的原始内容与来源逐字节一致。
- 设为 Active Profile → 生成 Runtime Config → 启动 Core。Runtime Config 里订阅自带的 `external-controller`、`secret` 已删除，`geo-auto-update: false`，mixed-port 为应用设置值，Control Channel 为 unix socket（权限 600）。
- 选择 Proxy、切换 Mode 都生效；停启 Core 后节点选择保持（`profile.store-selected`）。
- 订阅里的 `GEOIP` / `GEOSITE` 规则用随包 Geo 数据通过校验，没有联网下载（ADR-0012）。

外壳：
- 第二个实例启动后立即退出（exit 0），焦点回到已有窗口。
- 关窗后窗口数为 0，进入 Tray Mode；主进程里两条 WebSocket（traffic、logs）随窗口销毁关闭，剩下的两条是 HTTP keep-alive 空闲连接。
- 强杀应用后 Core 成为孤儿；下次启动按 pid 文件和可执行路径核对后结束旧 Core，再启动新的。
- 经 `quit` Command（托盘同一路径）退出后 Core 停止、pid 文件删除。
- System Proxy：开启后 Wi-Fi 的 HTTP/HTTPS 代理指向 `127.0.0.1:17890`，经代理的请求到达 Core；开着代理强杀应用，下次启动会清掉；正常退出也会关闭。测完所有网络服务的代理都是关闭状态。
- 新版本提示：默认仓库 `coderhyy/clash-kuro`（`KURO_RELEASE_REPO` 可覆盖）。2026-10-30 发临时 Release `v0.0.2-update-check-test` 实测：dev 版（0.0.1）启动后显示“发现新版本 v0.0.2-update-check-test”和指向该 Release 的“手动下载”链接；当前版本设为 0.0.2 时不提示。测后已删除 Release 和 tag。

Tray Mode 内存（`footprint`，窗口销毁 10 秒后）：GUI 合计约 80 MB（main 51、GPU 22、utility 7，renderer 已退出），Core 另计约 50 MB。窗口打开时 GUI 约 174 MB。参考值 Clash Party 托盘模式 GUI 约 143 MB；两者测法未必一致（我们用 `footprint`，参考值来源未注明工具）。

未覆盖：休眠唤醒（`createResumeHandler` 只有单元测试，未实际合盖测试）；定时更新只测了调度逻辑，没有等满一个周期；macOS 非管理员账户下 `networksetup` 被拒时的手动提示；Windows 全部内容（见 08）。
