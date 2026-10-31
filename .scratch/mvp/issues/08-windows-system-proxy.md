# Windows System Proxy

Status: ready-for-human
Type: task
Blocked by: 02, 07

需要 Windows 10/11 真机（普通用户账户）。macOS 上无法编译或验证，所以从 07 拆出。

## 背景（02 的结论）

- 随包分发一个以当前用户运行的小 Win32 helper exe（C，链接 WinINet + Rasapi32），主进程 spawn，不提权、不常驻、不是 Node 原生模块（ADR-0011）。
- 设置：`InternetSetOptionW(NULL, INTERNET_OPTION_PER_CONNECTION_OPTION=75, ...)` 写 `FLAGS / PROXY_SERVER / PROXY_BYPASS`，对 LAN（`pszConnection=NULL`）和 `RasEnumEntriesW` 枚举出的每个 RAS/VPN 连接分别设置；之后发 `INTERNET_OPTION_PROXY_SETTINGS_CHANGED=95` 和 `INTERNET_OPTION_REFRESH=37`，逐项检查返回值。
- 不用 PowerShell `Add-Type`（冷启动慢，受 AMSI、ConstrainedLanguage、执行策略影响），也不只写 HKCU 注册表（已打开的程序不会刷新，覆盖不到 RAS 连接）。
- “立即生效”的边界：遵循 WinINet 系统代理的程序在后续请求使用新设置；已有长连接、WinHTTP 服务、自带代理设置的程序不保证跟随。
- 清理只关闭能确认属于 Clash Kuro 的手动代理：helper 在同一次执行内重新读每个连接，`ProxyServer` 的所有端点都精确等于 `127.0.0.1:<上次写入的 mixed-port>` 才清除 `PROXY_TYPE_PROXY` 位，保留 PAC/WPAD、bypass 和别人的配置。
- 参考：`sysproxy-rs` 固定提交 `89ad876` 的 API 顺序（75 → 95 → 37，LAN + RAS）可借鉴；它的 unset 会一并关掉自动代理，不照搬。

详细论证和引用见 `02-windows-system-proxy-research.md` 的 `## Answer`。

## 内容

- helper：`resources/win/x64/kuro-sysproxy.exe`，命令 `get` / `set --host --port --bypass` / `clear --expected-server`，输出 JSON，逐连接返回结果。
- 主进程：在 `apps/desktop/src/main/platform/system-proxy.ts` 的 Windows 分支里 spawn helper（`shell:false`、`windowsHide:true`、超时、stdout 上限），把 `cleanupStaleSystemProxy`、`getSystemProxy`、`setSystemProxy`、`clearSystemProxy` 接上；替换现在的 `not implemented`。
- 打包：`electron-builder.yml` 的 `win.extraResources` 加入 helper；`.github/workflows/ci.yml` 的 Windows 任务编译 helper（MSVC 或 mingw）后再打包。
- 被策略或安全软件拒绝时，提示手动设置 `127.0.0.1:<mixed-port>`，不静默退回只写注册表。

## 待验证

- 已打开的 Edge/Chrome 等 WinINet 客户端在设置后、清理后的后续请求是否立即跟随；已有长连接的表现。
- LAN、已有和新建的 RAS/VPN 连接（含中文连接名）。
- 混合协议 `ProxyServer`、他人的端点、PAC/WPAD 开启时的 set/clear 行为。
- 端口变更后能清掉旧端口的代理。
- 企业策略锁定、Defender/EDR 对未签名 helper 的反应（MVP 不签名，ADR-0010）。
- 耗时：helper `get`/`set` 冷/热启动 p50/p95。
- 退出、注销、关机时的清理与超时。
- Windows named pipe Control Channel：随机 pipe 名、Core 重启后轮换（07 只在 macOS 实测过 unix socket）。

## Comments

2026-10-30 (agent, Windows 真机): helper 与主进程 Windows 分支已实现。

- helper 源码 `apps/desktop/native/win/`，`node scripts/build-sysproxy.mjs --test` 用 mingw-w64（本机 LLVM-MinGW clang 23）编译到 `resources/win/x64/kuro-sysproxy.exe`（25 KB，静态链接，只导入 WININET/RASAPI32/KERNEL32/UCRT），并跑端点解析 C 单测。
- 主进程：`system-proxy.ts` 的 Windows 分支调用 helper，串行执行；上次写入的端点记录在 `system-proxy.json`，clear 同时带上旧端点和当前端点，端口变更后也能清掉旧代理。
- `createAppStore` 启动时 `getSystemProxy` 失败不再阻止启动。
- 实测：`get` 一次约 114 ms（沙箱内单次，不是 p50/p95）。set/clear 尚未在真机上执行，见“待验证”。
- 已知：desktop 的 `platform.test.ts` / `transport.test.ts` 在 Windows 上仍因写死 `/tmp` 和 unix socket 失败（07 遗留），CI 继续跳过它们，只单独跑 System Proxy 测试。

2026-10-30 (agent, Windows 真机，helper 实测):

- 修复：store 默认 bypass 里的裸 `::1` 会让 WinINet 拒绝整个列表（错误 87，set 失败）；主进程现在写成 `[::1]`。
- `get` 耗时（Defender 实时保护开启）：冷启动（每次新文件，n=30）p50 170 ms / p95 366 ms；热启动（同一文件，n=100）p50 72 ms / p95 110 ms。
- LAN set/clear 实测（本机无 RAS 条目）：混合协议全为本端点 → cleared；混有他人端点 → notOurs 不动；他人单端点 → notOurs；PAC(flags 7)/自动检测(flags 11) + 本端点 → 只去掉 PROXY 位（变 5/9），PAC URL、server、bypass 保留；PAC-only → unchanged；`localhost:7890` 不等同 `127.0.0.1:7890`。set 会关闭 PAC/自动检测位（15 → 3），clear 后不恢复（与设计一致）。
- 发现：Windows 上 `powerMonitor` 的 `shutdown` 事件不触发（Electron 只在 Linux/macOS 发出），注销/关机清理尚未接上，待验证项中单列。

2026-10-31 (agent, Windows 真机，注销/关机清理):

- 实现：Windows 上启动时创建一个不显示的 `BaseWindow`（`show:false`、1×1、不进任务栏、不可聚焦），只用来接收 `query-session-end` / `session-end`。这两个是 BaseWindow 事件，不是 `app` 或 `powerMonitor` 的；挂在主窗口上，Tray Mode（主窗口已销毁）时会漏掉。逻辑在 `apps/desktop/src/main/app/session-end.ts`，接线在 `main/index.ts`。
- 时序：`query-session-end` 里就 `void exit()`，不调用 `preventDefault()`，不推迟、不阻止注销/关机；`session-end` 之后系统随时可能结束进程，所以那里再调一次兜底（`quitting` 标记保证只执行一次）。`exit()` 仍是先清 System Proxy（预算 1.5 s）再停 Core，总超时 3 s（`SHUTDOWN_TIMEOUT_MS`）。
- `exit()` 在 `finally` 里调用 `app.exit(0)`；清理进行中再收到 `before-quit` 也会被拦住，不会跳过清理直接退出。
- 诊断：每次退出往 `<userData>/data/exit.log` 追加时间戳行：`query-session-end (logoff)`、`exit start (...)`、`exit done in N ms`。注销/关机后重新登录时看这个文件和注册表的 `ProxyEnable`。
- 已验证：本机 Electron 45.1.0 能创建这个窗口，`isVisible()` 为 false，两个事件的监听都注册上了；`session-end.test.ts` 覆盖“两个阶段都触发清理、都不调用 preventDefault”。
- 待验证（真机，用新产物）：隐藏窗口在 Tray Mode 下能否收到 `query-session-end` / `session-end`（Electron 文档没写不可见窗口的情况，Win32 层面顶层窗口不论可见与否都会收到 `WM_QUERYENDSESSION`）；`exit.log` 里能否看到 `exit done`，还是进程在中途被结束；注销、关机各测 5 次，记录耗时和重新登录后的 `ProxyEnable`。

2026-10-31 (用户真机 + agent，注销清理第二版):

- 用户实测（产物 run 41156570110，注销 2 次）：隐藏 `BaseWindow` 两个事件都收到了（app/主窗口状态和注销方式在用户的反馈模板里没填）。`exit.log`：`06:37:18.933Z query-session-end (critical,logoff)` → `18.946 exit start` → `18.955 session-end`；`07:11:22.493Z query-session-end (logoff)` → `22.503 exit start` → `22.674 session-end`。两次都没有 `exit done`。重新登录后 `ProxyEnable=0x1`、`ProxyServer=127.0.0.1:7891`，代理没清掉。
- 原因：`exit()` 是异步的，事件处理函数一返回，`session-end` 后 9–171 ms 进程就被结束，异步的 helper 调用来不及跑完。
- 新方案：
  - `query-session-end` 处理函数里同步清 System Proxy：`clearSystemProxySync` 用 `execFileSync` 调 `kuro-sysproxy.exe clear`（`windowsHide`，硬超时 1.5 s，超时用 `TerminateProcess` 杀掉 helper），返回前完成；不调用 `preventDefault()`；清完再 `void exit()` 停 Core。
  - `session-end` 里如果还没清成功（失败、超时、退出码非 0，或当时有 set 正在执行），再同步清一次兜底。两次最多 3 s，在 Windows 给每个进程的 5 s 内。
  - 端点只用内存：上次写入的端点在 `createSystemProxy` 时预加载，每次 set/clear 后同步更新；当前端口来自 `mixedPort()`。事件处理函数里不读文件、不 await。内存里确认没有我们的代理时不启动 helper，关机时少起一个进程。
  - 同步清理之后拒绝新的 set，异步的 `clearSystemProxy` 也不再启动第二个 helper。
  - `exit.log` 记录同步清理的结果，例如 `sync clear ok: exit=0 timedOut=false 82 ms servers=127.0.0.1:7891 LAN=cleared`。NTSTATUS 退出码以 16 进制显示，`3221225794 (0xC0000142 DLL init failed)` 会单独标出。
  - 遵守 ADR-0011：没有 Node 原生模块，helper 每次运行完就退出，不常驻。
- 测试：desktop typecheck 通过；`session-end.test.ts`、`app.test.ts`、`system-proxy.test.ts`、`sysproxy-helper.integration.test.ts` 共 57 个通过；core 89、api 12、state 36 个通过。新增的单测覆盖：先同步清再 exit，两个事件都不调用 `preventDefault`；清成功后 session-end 不再清，失败或超时则重试；清理用内存端点，不调用 `memory.load`；没有待清端点时不启动 helper；超时、0xC0000142、exit 2 报告为失败；set 正在执行时报告为失败；set 卡在写记忆文件时遇到会话结束，不会再启动 helper；`execCommandSync` 真实超时会杀掉挂住的进程，并返回退出码和 stdout。
- 真机耗时：同步 clear（端点不匹配，不写设置，热启动）n=20，p50 82 / p95 89 / max 89 ms。
- 参考实现：
  - clash-party（`mihomo-party-org/clash-party@1d4ad19`，`src/main/lifecycle.ts`）：在 `browser-window-created` 时给每个 BrowserWindow 挂 `session-end`，在 `cleanupBeforeExit()` 里先用 `disableSysProxySync()` 同步关代理（`sysproxy-rs` Node 原生模块），再异步停 Core；`will-quit` 再同步关一次兜底。我们沿用“先同步关代理、再异步停 Core”的顺序。不同之处：没有 BrowserWindow 时（Tray Mode）会漏掉事件，所以我们用专用的隐藏 BaseWindow；ADR-0011 不允许原生模块，所以用 `execFileSync` + helper；我们在更早的 `query-session-end` 就开始清理。
  - clash-verge-rev #5018：后台运行时关机或重启，弹出 `sysproxy.exe` 无法正常启动（0xc0000142）；由 PR #5024 修复（关机时标记 exiting，停掉后台任务）。启示：关机时尽量少起新进程、尽早清理，日志里要能看出 0xC0000142。
  - clash-verge-rev #7725：Windows 关机/重启时，等待 Service IPC 停 Core 没有超时，app 挂起约 46 s。启示：每一步都要有硬超时，不等 Core，不 `preventDefault`。
- 已知取舍：`query-session-end` 之后如果别的程序取消了关机，Kuro 已经关掉代理并退出，不会恢复运行。代理不会悬空，但用户需要手动重开 Kuro。
- 观察：2026-10-31 16:2x 本机 `reg query` 显示 `ProxyEnable=0x0`，但同一时刻 `kuro-sysproxy.exe get` 读到 LAN `flags=3`、`proxyServer=127.0.0.1:7891`（`DefaultConnectionSettings` 的 flags 字节也是 3），Kuro 没有在运行。注册表的 `ProxyEnable` 和 WinINet 实际使用的值可能不一致，所以验证以 helper `get` 为准。
- 待验证（新产物，Tray Mode，注销、关机各 5 次）：`exit.log` 里每次都有 `sync clear ok`；重新登录后用 `kuro-sysproxy.exe get` 看 LAN `flags` 的 2 位已清除；注销/关机没有变慢，也没有出现 0xC0000142 弹窗。
