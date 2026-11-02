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

2026-10-31 (用户真机 + agent，注销第 3 次 / 0xC0000142 / RunOnce 兜底):

- 用户实测：产物 run 41184918440，Tray Mode，主窗口已关，System Proxy 已打开，从开始菜单注销。`exit.log`：
  - `08:55:30.556Z query-session-end (logoff)`
  - `08:55:30.849Z sync clear FAILED: exit=3221225794 (0xC0000142 DLL init failed) timedOut=false 290 ms`
  - `08:55:30.851Z exit start (query-session-end)`
  - `08:55:30.926Z session-end (logoff)`
  - `08:55:31.085Z sync clear FAILED: exit=3221225794 (0xC0000142 DLL init failed) timedOut=false 157 ms`
  
  重新登录后 helper `get` 读到 LAN `flags=3`、`proxyServer=127.0.0.1:7891`，代理没清掉。
- 结论：同步清理的时机是对的，两个事件都收到了，处理函数也执行到了。但注销开始后，Windows 拒绝初始化新启动的 helper（STATUS_DLL_INIT_FAILED 0xC0000142），和 clash-verge-rev #5018 的现象一致。所以凡是在注销时才启动进程的方案都靠不住。常驻 helper 待命违反 ADR-0011，不做。
- 改动 1：helper 改为 GUI 子系统（`-mwindows`，PE subsystem=2），启动时不建控制台。本机实测：`execFileSync` 和 `execFile` 都能读到 JSON，用法错误时 `status=1`、`code=87`；没有任何标准句柄时（`Start-Process`，相当于登录时 Explorer 启动它）运行正常，exit 0。这一步只排除“控制台初始化失败”这一种可能，不保证 0xC0000142 不再出现。
- 改动 2：RunOnce 兜底，不依赖注销时启动进程。
  - set 只要有一个连接写成功，helper 就写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce` 的 `ClashKuroSysProxyCleanup`，值为 `"<helper 绝对路径>" clear --expected-server 127.0.0.1:<port>`。路径带引号（打包后路径里有空格 `Clash Kuro`），路径含引号或命令超过 260 字符时拒绝写入。
  - 端口变化时，下一次 set 覆盖这条，指向新端口。
  - clear 结果 `ok`（每个连接是 cleared、notOurs 或 unchanged）时删除这条；clear 失败则保留，下次登录重试。
  - 登录时 Windows 先删掉这个值再执行，端点检查沿用 `notOurs`：代理已经不是我们的就不动。
  - helper 的 JSON 带 `runOnce: "written" | "deleted"` 或 `runOnceError`。RunOnce 写失败不影响 set 本身成功，主进程只打 warning。同步清理的 `exit.log` 行会带 `runOnce=deleted` 或 `runOnce error <code>`。
  - 不调用 `preventDefault()`，同步清理和 `exit.log` 保留。没有原生模块，helper 不常驻。
- 本机实测 RunOnce（helper 复制到带空格的临时路径）：
  - set 7891 → 写入 `"...\Kuro RunOnce Test\kuro-sysproxy.exe" clear --expected-server 127.0.0.1:7891`。
  - set 7892 → 这条改为 7892。
  - 用 `cmd /c` 原样执行这条命令 → cleared，并 `runOnce: "deleted"`。
  - set 7891 后执行 clear 7892 → notOurs，代理保持开启，这条被删除。
  - 实测结束后 LAN 回到 `flags=1`，RunOnce 里没有残留。
- 测试：C 单测新增 RunOnce 命令行格式（引号、空路径、含引号路径、260 边界、超长路径）并通过；desktop typecheck 通过；desktop 测试 59 个通过，新增覆盖：日志带 RunOnce 状态，RunOnce 写失败时 set 仍成功。
- 风险 / 待验证：
  - 真机注销、关机各 5 次：看 `exit.log` 是 `sync clear ok` 还是 0xC0000142；重新登录后、启动 Kuro 之前，`get` 读到的 flags 2 位是否已被 RunOnce 清掉。
  - RunOnce 是常见的持久化位置，Defender/EDR 可能提示或拦截写入。拦截时 set 仍然成功，只是兜底失效，日志里能看到 `runOnceError`。
  - RunOnce 只在下一次登录时运行。注销到再次登录之间，以及关机后开机到登录之前，代理设置仍会指向已停止的端口。
  - 删除或移动 app 后，残留的 RunOnce 会执行失败一次，然后被 Windows 删掉，不影响其他设置。

2026-10-31 (用户真机 + agent，注销第 4 次，产物 run 41188296509，GUI 子系统 helper + RunOnce):

- `exit.log`：`09:50:26.938Z query-session-end (logoff)` → `27.111Z sync clear FAILED: exit=3221226091 (0xC000026B)` → `27.144Z session-end` → `27.276Z sync clear FAILED: exit=3221226091 (0xC000026B)`。
- 0xC000026B 是 STATUS_DLL_INIT_FAILED_LOGOFF（window station 正在关闭，DLL 初始化失败）。改成 GUI 子系统后错误码变了，但 helper 仍然启动不了。结论更确定：注销开始后，任何新启动的进程都不能指望。
- 重新登录后、Kuro 未启动时，`get` 读到 LAN `flags=1`，代理已关。但不是 RunOnce 关的：
  - 注册表键的最后写入时间：`Internet Settings` 是 17:50:27.253，`Connections` 是 17:50:27.277，都落在注销过程中（第二次同步清理失败的同一时刻）。
  - Shell-Core 日志：RunOnce 在 17:52:42 才执行 `kuro-sysproxy.exe clear --expected-server 127.0.0.1:7891`（PID 27224，事件 9707/9708）。之后 `Connections` 键没有再被写过，说明那时代理已经是关的，clear 没改任何设置。用户 17:52 的截图里 `get` 已经是 `flags=1`，RunOnce 条目还在，时间早于 RunOnce 执行，也对得上。
  - 所以注销时有别的进程改了代理设置，具体是谁目前不知道。Kuro 的 helper 两次都没能启动，不是它。候选是注销时退出、并会恢复代理设置的程序：Fiddler 测试前在运行，登录后没有运行，但没有证据。
- RunOnce 本身确认能工作：set 时写入，登录时 Explorer 按带引号的路径执行了它，执行后条目消失（Windows 执行前先删除）。但 helper 在 RunOnce 下运行时没有任何输出可看，所以这次没法证明它在“代理仍是我们的”时能清掉。
- 下一步：
  - 注销前先退出 Fiddler 等会改代理的程序，确认 `get` 是 `flags=3`、RunOnce 条目已写入，再注销。
  - 给 helper 加 `--log <file>`，RunOnce 命令带上它，把每次 clear 的 JSON 结果追加到 `%APPDATA%\Clash Kuro\data\runonce.log`。待用户确认后再做。

2026-10-31 (agent，注销第 4 次之后：假设、`--log`、HITL 脚本、ADR-0013 草案):

- 新发现：本机装着 clash-verge-rev 2.5.8，注销第 4 次时它也在运行。它的日志 `2026-10-31_18-37-50.log` 里，`17:50:27.232` 记录 "Starting bounded session-ending best-effort cleanup"，`17:50:27.353` 记录 core stopped 和 "Application exited"。`Internet Settings`（.253）和 `Connections`（.277）两个键的写入时间都落在这 121 ms 里。它的 `verge.yaml` 是 `enable_system_proxy: false`，可它的会话结束清理仍可能重置代理。目前只是时间吻合，还不能算证据。
- 假设（按可能性排序，先给用户看，确认后再测）：
  1. clash-verge 的 session-ending 清理关了我们的代理。如果成立：完全退出 clash-verge（托盘 > 退出）后再注销，登录后、RunOnce 执行前 `get` 仍是 `flags=3`；`Connections` 的写入时间等于 runonce.log 里 clear 那一行的时间；runonce.log 记录 `LAN=cleared`。反过来，让 clash-verge 运行着再注销，会重现 `flags=1`，且写入时间落在它的 cleanup 窗口里。
  2. 注销开始后，Windows 拒绝初始化当前会话里任何新启动的进程（0xC000026B 是 window station 关闭时的通用错误），跟 helper 导入了哪些 DLL 无关。如果成立：只依赖 kernel32 的探针进程（或者把 WinINet/RAS 改成延迟加载的 helper）在注销时也起不来，`exit.log` 仍是 0xC000026B，探针日志里没有 start 行。如果不成立，start 行会出现，失败只发生在 WinINet/RAS DLL 初始化。这一条决定 ADR-0013 能不能定稿。
  3. 失败只出在 helper 静态导入的 DLL 上（WININET/RASAPI32 及其带进来的 combase/RPCRT4 等）。和假设 2 互斥，用同一个探针区分：探针能写 start 行，完整 helper 不能。
  4. 注销时 Fiddler 恢复了它保存的代理设置（测试前它在运行，HookAllConnections=True）。如果成立：`proxyServer` 会变回 Fiddler 当初保存的值，而不是只去掉 PROXY 位、server 保留 `127.0.0.1:7891`。第 4 次注销后 server 没变，所以可能性较低。只运行 Fiddler 再注销可以确认。
  5. RunOnce 的 clear 在“代理仍是我们的”时没有清掉，比如登录时 WinINet 还没准备好、返回 error，或者因为格式不同判成 notOurs。如果成立：runonce.log 里是 `status:"error"` 或 `notOurs`，并且 `get` 仍是 `flags=3`。本机按 Explorer 的方式（无标准句柄、参数原样）执行已验证能 cleared，所以排最后。
- 实现 `--log <file>`（set 和 clear 都接受，get 不接受）：
  - helper 先追加一行 start（UTC 时间、pid、完整命令行），再追加 JSON 结果，stdout 不变。
  - 文件用 `FILE_APPEND_DATA` 打开，写失败不影响结果；超过 256 KB 时轮转成 `<file>.1`。
  - 路径必须是 `X:\` 开头的绝对路径，不能含引号或控制字符，长度不超过 255。
- set 写 RunOnce 时把 `--log` 一起带上：`"<helper>" clear --expected-server 127.0.0.1:<port> --log "<dataDir>\runonce.log"`，两段路径都加引号。命令超过 260 字符时退回不带 `--log` 的版本，JSON 里标 `runOnceLogOmitted:true`，主进程打 warning。本机打包路径下这条命令约 190 字符。主进程把 `%APPDATA%\Clash Kuro\data\runonce.log` 传给 set；clear 由 Kuro 自己读 stdout，不带 `--log`。
- 本机实测：helper 放在带空格的临时路径，日志放在带空格的目录。
  - set 7891：RunOnce 写入带 `--log` 的命令（185 字符）。
  - 按 Explorer 的方式执行这条命令：clear 返回 `cleared`，`runOnce:"deleted"`，日志里有 start 行和 JSON 两行。
  - 结束后 LAN 回到 `flags=1`，没有 RunOnce 残留。
  - 注意：PowerShell 直接 `& helper.exe` 不会等 GUI 子系统程序结束，脚本里要用重定向 stdout 再等待的方式调用。
- HITL 脚本 `apps/desktop/scripts/hitl-logoff-check.ps1`，只读，PowerShell 5.1 和 7 都能跑：
  - `-Phase before`：以下任何一项不满足，就打印 FAIL 和 "DO NOT LOG OFF"，并以 exit 1 退出。
    - Fiddler、clash-verge、verge-mihomo、v2rayN、nekoray 等会改代理的程序都已退出。
    - Kuro 在运行。
    - `get` 读到 LAN `flags=3`、`127.0.0.1:<port>`。
    - RunOnce 条目存在、指向同一端点、带 `--log`，helper 路径存在。
    
    检查通过时，把快照存到 `%TEMP%\kuro-hitl-logoff-before.json`。
  - `-Phase after`：在登录后、启动 Kuro 之前运行，收集以下内容。
    - `exit.log` 和 `runonce.log` 自快照以来的新行。
    - `get` 结果和 RunOnce 条目。
    - `Internet Settings`、`Connections` 两个键的最后写入时间（`RegQueryInfoKey`）。
    - `DefaultConnectionSettings` 的计数器和 flags 字节。
    - Explorer 启动时间。
    - Shell-Core 9705–9708 事件。
    - clash-verge 日志里的 session-ending 行。
  - 本机试跑：`before` 正确拦下（clash-verge 在运行、Kuro 未运行、`flags=1`、无 RunOnce），`after` 输出完整。
- 起草 `docs/adr/0013-windows-session-end-cleanup.md`（状态：草案，前提待假设 2 确认）：先同步试一次，失败就靠 RunOnce 在下次登录时清，再加上 Kuro 启动时的清理。是否放宽 ADR-0011（例如在主进程里直接调用 WinINet 的原生模块，clash-party 的 `sysproxy-rs` 就是这样）只列了取舍，由用户决定；ADR-0011 没改。在 spec 的“退出、关机、注销”一条下注明了 Windows 做不到的部分。
- 测试：C 单测新增带 `--log` 的命令格式（含空格路径、260 边界）和日志路径校验，并通过；desktop typecheck 通过；desktop 测试 64 个通过。新增覆盖：set 带 `--log`、clear 不带；`runOnceLogOmitted` 时 set 仍成功并 warning；helper 拒绝相对路径、含引号的路径，以及 `get --log`。
- 下一步（用户确认假设后）：完全退出 clash-verge 和 Fiddler，用新产物在 Tray Mode 下注销，前后各跑一次脚本。假设 2/3 的探针等这轮结果出来再决定做不做。

2026-10-31 (用户真机，run 41199791603，Tray Mode；固定产物重复验证：注销 1/5，关机 0/5):

- 本轮仅确认 RunOnce 下次登录兜底成功，不代表注销前清理问题解决，也不代表接受该方案。后续继续使用同一产物；累计完成注销 5 次、关机 5 次后再决定是否接受。每轮 before 输出交给 agent 确认后才注销/关机；登录后不启动 Kuro 或其他代理软件，先运行 after。暂不合并，不加探针，ADR-0013 保留草案，ADR-0011 不放宽。
- before（本地时间 20:31:19）：清单中的其他代理程序均未运行；clash_verge_service 仍为 Running，作为残余变量记录，不能把脚本“服务不会自行改代理”的说明当成已证实结论。Kuro 在运行，LAN flags=3、proxyServer=127.0.0.1:7891、counter=224；RunOnce 指向 run-41199791603 的 helper，端点正确，带加引号的 --log 路径。runonce.log 记录 set 成功和 runOnce=written。残留 PAC URL 未启用（flags=3）。
- exit.log（UTC）：12:33:05.208Z query-session-end (logoff)；05.454Z 同步清理失败，exit=3221226091 (0xC000026B)，timedOut=false，241 ms；05.455Z exit start；05.474Z session-end (logoff)；05.557Z 第二次同步清理失败，同一退出码，timedOut=false，79 ms。未观察到注销前清理成功。
- Winlogon 本地时间：20:33:11.585 logoff，20:33:43.136 logon；Explorer 于 20:33:43.962 启动。
- RunOnce 直接证据：20:35:05.780 helper 开始 clear，PID 30276，完整命令行包含预期端点及 runonce.log 路径；20:35:05.813 返回 {"command":"clear","connections":[{"name":null,"status":"cleared"}],"runOnce":"deleted","ok":true}。这是实际 cleared，不是 unchanged/notOurs。
- Internet Settings 与 Connections 最后写入时间均为 20:35:05.802，落在 helper clear 开始与结果之间。after（20:40:12）：LAN flags=1、counter=225、ProxyEnable=0；server、bypass、PAC URL 保留；RunOnce 条目不存在。用户未先启动 Kuro 或其他代理软件。
- Shell-Core：20:35:05.629 9705，05.632 9707，05.767 9708（PID 30276）及 9706；9707/9708 文本只显示 runonce.log 的尾部，不能单凭这段文本认定完整命令，需结合 PID、helper 日志及时间戳。没有本轮 clash-verge session-ending 日志。
- 限制：从 Explorer 启动到代理实际清除相隔 81.840 秒（约 82 秒），从 Winlogon logon 算约 82.666 秒。RunOnce 并非登录后立即执行；这段时间代理仍指向已停止的 Core，先启动的联网程序可能无法联网。
- 假设结论：退出 clash-verge 后未再观察到注销阶段提前清理，本轮支持上轮存在其他程序干扰的解释，但不足以认定上轮具体写入者；仍无法区分“所有新进程都无法初始化”与“仅此 helper 的 DLL 初始化失败”。RunOnce 清理本轮通过，关机及重复可靠性尚待验证。

2026-10-31 (用户真机，run 41199791603，Tray Mode，开始菜单注销；注销 2/5，关机 0/5):

- before（20:46:40）：LAN flags=3、127.0.0.1:7891、counter=226；Connections 最后写入 20:46:26.548。未检测到清单中的其他代理程序，clash_verge_service 仍运行；RunOnce 指向本轮固定产物且带 --log，set 返回 ok=true、runOnce=written。
- exit.log（UTC）：12:47:30.336Z query-session-end；30.496Z 同步清理失败，0xC000026B，149 ms；30.498Z exit start；30.524Z session-end；30.633Z 再次失败，0xC000026B，107 ms；两次 timedOut=false。注销前清理仍未成功。
- Winlogon 本地时间：20:47:32.564 logoff，20:47:52.962 logon；Explorer 于 20:47:53.696 启动。RunOnce helper 于 20:49:11.101 开始 clear，PID 13856，与 Shell-Core 9708 一致；11.138 返回 LAN status=cleared、runOnce=deleted、ok=true。
- Internet Settings 最后写入 20:49:11.124，Connections 为 20:49:11.125，均在 clear 开始与结果之间。after（20:49:21）：flags=1、counter=227、ProxyEnable=0，端点保留，RunOnce 条目消失；无本轮 clash-verge session-ending 日志。
- 登录后延迟：从 Explorer 启动到 Connections 写入为 77.429 秒；从 Winlogon logon 算为 78.163 秒。本轮 RunOnce 兜底成功，不代表注销前清理问题解决。固定产物累计：注销样本 2/5，RunOnce 清理成功 2/2，注销前同步清理成功 0/2；关机 0/5。用户尚未反馈本轮有无卡顿或错误弹窗。

2026-11-01 (用户决定 + agent，只读架构可行性评估；停止重复测试):

- 停止 run 41199791603 剩余注销、关机重复测试，不补齐 5+5；本条取代之前继续累计的计划。保留已完成的两次 Tray Mode 注销证据：注销前同步清理成功 0/2，RunOnce 实际清理成功 2/2，Explorer 启动后分别约 82 秒、77 秒才清除。关机没有样本；不能写成问题解决或方案已接受。
- 本轮只读代码和官方资料，并在本 Comments 记录评估；没有运行原生原型、代理写操作或新的会话结束实验。ADR-0011 不修改，ADR-0013 保留草案，Status 不改，不合并，不替换正式实现。后续原型及新实验都先提交具体计划，等待用户确认。
- 证据边界：0xC000026B 证明这些场景下当前 helper 初始化失败，不能推导所有新进程都无法启动；clash_verge_service 仍是残余变量。RunOnce 无即时执行保证，默认执行前删值，失败不能当作自动重试。

架构评估（候选，不是已批准决策）：

1. 优先验证小型 Node-API 模块，但排除主线程直接同步 WinINet 调用。InternetSetOption/InternetQueryOption/RAS 枚举没有已找到的通用、可强制取消且限定耗时的设置操作契约；网络连接/收发 timeout 不能代替。Promise.race 无法中断阻塞的主线程，napi_cancel_async_work 不能取消已开始的任务。[InternetSetOption](https://learn.microsoft.com/en-us/windows/win32/api/wininet/nf-wininet-internetsetoptionw)、[选项语义](https://learn.microsoft.com/en-us/windows/win32/wininet/option-flags)、[Node-API](https://nodejs.org/api/n-api.html#napi_cancel_async_work)。
2. 首选原型形态：正常启动时显式初始化模块、WinINet 依赖、专用原生工作线程、事件和请求存储；不在 DllMain 中调用 WinINet。工作线程串行执行当前用户 LAN/RAS 的 get/set/clear，沿用 Platform 外部接口及端点判断。会话事件只提交已准备好的清理请求并限时等原生完成事件；完成信号不依赖被等待阻塞的 JS 线程回调。这里同步的是有界等待，不是 WinINet 操作本身。不要默认用 libuv 共享线程池；排队、取消和退出收尾也必须受控。
3. 保证边界：超时只保证应用放弃等待，不保证清理成功或工作线程停止；禁止 TerminateThread，禁止超时后释放仍被线程使用的数据。模块/工作内存需保留至操作结束或进程终止，禁止无限 join/cleanup hook 等待。超时进入 closing/uncertain，禁止新 set；单写者保证迟到的旧 set 不会越过后续 clear。若需要卡死后安全继续正常使用，而非退出进程，进程内方案劣势明显。[TerminateThread 风险](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminatethread)。
4. 预算建议供原型确认：代理清理总预算 1500 ms，从首次 query-session-end 开始采用单调绝对截止时间；session-end 只能使用剩余预算，不重新获得 1500 ms。普通退出的 Core 收尾另明确总预算；不能把当前两次清理、shutdown 和日志等待简单叠加后仍声称固定 1500 ms。主线程不做磁盘日志写入、注册表操作、阻塞锁、动态 DLL 初始化或无界取消等待。Windows 不是实时系统，限时等待不是包含调度停顿/系统挂起在内的绝对墙钟保证；必须明确承诺是软件等待路径有界。GUI 线程还需验证通知广播与消息泵重入，不能直接用无限等待。[WaitForSingleObject](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject)。
5. 备选为正常启动时就运行的普通用户 helper：提前完成 DLL 初始化和 IPC 连接，单写者工作线程与隐藏普通顶层窗口分离；应用和 helper 都可请求同一幂等清理。不要用不接收广播的 message-only window。独立进程能隔离崩溃并允许请求终止，但 TerminateProcess 的完成仍可能等待 I/O，主进程不得无限等待它。helper 在会话结束时仍可能先于应用退出；关停优先级只改善顺序，不构成服务可用保证。生命周期需覆盖父进程崩溃、重复实例、孤儿退出和普通退出先清代理再停 Core，不引入服务、管理员权限或 TUN。[窗口](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)、[关停顺序](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessshutdownparameters)、[TerminateProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminateprocess)。
6. helper IPC 候选：预连接 named pipe、随机通道、显式 logon SID ACL（用户 SID 不等于会话隔离）、拒绝远程客户端、最小命令集和有界帧。overlapped I/O 共用截止时间；CancelIoEx 只是取消请求，不能随后无期限等待或立即复用缓冲区。Electron JS 异步 pipe 回调在同步会话处理函数等待时也不能运行：若坚持该处理函数等待 ACK，需要预初始化的原生 IPC 等待桥，或让 helper 自己处理会话消息而接受无法由主进程确认顺序的取舍，不能把纯 JS Promise 当作现成解决方案。[Pipe 安全](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)、[CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)。
7. 推荐顺序：先做 Node-API 专用线程的有界等待可行性原型；若隔离、超时后生命周期或消息泵无法满足验收，转预启动 helper。二者都需要用户批准约束调整后才能正式落地；本轮不放宽 ADR。直接同步 addon 不进入候选。两者仍需恢复兜底，不能承诺强制结束/断电时必定清理。

必须处理的兼容边界（只列设计条件，不开发）：

- 自启与旧 RunOnce：端点相同不足以证明同一实例。恢复记录需要代次/所有权；启动清旧状态、建立新所有权、set 与恢复 clear 必须在跨进程串行边界内完成，锁等待也有预算。检查代次到写代理之间不能留下竞态；旧 clear 不能删除新 RunOnce。只删除旧 RunOnce 不够，Windows 可能已取出命令/启动旧 helper。部署新协议时也要处理不理解代次的旧命令，不能只靠新 helper 的校验。
- 自动更新/卸载：恢复 helper 不能只放在会被删的版本目录；评估稳定的用户级恢复位置、签名与路径 ACL、待清理期间保留兼容旧记录的版本、更新回滚/中断，以及卸载前有界清理。清理失败时必须明确保留恢复组件或告知手动恢复，不能留下指向不存在文件的命令。移动便携目录、长路径/RunOnce 260 字符上限、策略拦截、文件被隔离同样需要处理。
- 外部软件和多会话：所有权记录不是 WinINet 注册表的事务锁；外部程序不遵守 Kuro 的互斥约定，仍须临写前重新判断端点、保留 notOurs/PAC/WPAD/混合协议语义，不能宣称绝对无竞争。多登录会话共享 HKCU 而 IPC 按 logon SID 隔离，需明确产品策略，防止不同会话互相清代理。
- 查询阶段可能取消注销；不 preventDefault，但一旦提前清理并开始退出，不应自动恢复旧 set 与新的恢复流程竞争，需明确取消后的状态。普通 WM_QUERYENDSESSION 文档建议尽快返回，把清理放在确认结束之后；当前提前清理属于保守产品策略，而非系统保证。[WM_QUERYENDSESSION](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-queryendsession)、[WM_ENDSESSION](https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-endsession)、[RunOnce](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys)。

待批准的最小原型和验收：

- 首阶段仅独立测试载体，不替换 app：Node-API 模块显式 init、专用线程、预分配请求、有界等待；先使用假操作，注入永不返回、迟到成功、正在 set、重复事件、日志阻塞，不更改真实代理、不注销。验收看全调用路径，不以 p95 代替保证：一个绝对截止时间，所有等待有限，无主线程 WinINet/磁盘 I/O/无限 join；超时返回 uncertain，不误报成功，无迟到任务访问已释放内存，无关闭后新 set。
- Windows 常规调度下记录 1500 ms 预算及返回偏差，超限逐项解释；测量不能证明实时保证。必须额外审查消息泵、重入、模块卸载与进程退出路径，卡死线程不得拖住 app 的退出流程。
- 第二阶段经另行确认才接真实 WinINet：提取 helper 中的代理操作和 endpoint 判断为共享 C 核心，exe/Node-API 仅适配，不复制业务规则；保留 get/set/clear 的外部 Platform 语义。先备份并验证 LAN/RAS、混合协议、notOurs、PAC/WPAD、失败回滚及通知；检查 Electron Node-API 版本、x64 打包、asar 外置、DLL 依赖、CI 加载，不把 Node-API ABI 稳定等同于无需打包测试。
- 只有前两阶段通过且用户另行批准才给出 Tray Mode 注销/关机实验安排，验证提前加载后是否仍能调用 WinINet，以及清理返回再停 Core的顺序；失败/超时明确留待恢复。RunOnce 同端口跨代竞态、helper 路径消失先用隔离存储/假操作模拟，不提前开发自启、更新、卸载。

2026-11-02 (agent，用户批准的第一阶段独立 Node-API 假操作原型):

- 位置：`.scratch/mvp/prototypes/node-api-deadline/`。源码、独立构建/外部看门狗测试脚本及 README 均不接入正式 app，无新增运行时依赖；构建只下载并校验当前 Node 版本的官方头文件和 import library。未读写真实代理、RunOnce，未进行注销/关机。ADR-0011 不改，ADR-0013 保持草案，Status 不改，不合并。
- 正常启动时 pin DLL、创建专用原生线程/固定内存/事件；首次 clear 共用一个 1500 ms 单调截止时间，重复事件不续期。完成由原生事件通知，不依赖 JS 回调。测试线程仍在执行时不释放状态或卸载 DLL，cleanup hook 不 join；这是进程生命周期资源保留，不是可热卸载模块，也不是安全取消卡住的调用。
- 本机 Windows x64 / Node v24.22.1 / Node-API v8 / LLVM-MinGW clang 23.1.4，最终 16 场景各跑 3 次：48/48 通过、看门狗强杀 0。覆盖正常完成、已排队/正在执行的 set、永不返回的 set/clear、迟到返回、工作线程锁/日志阻塞、初始化卡住、重复事件和剩余预算、显式退出、Node 环境自然销毁/terminate，以及环境销毁后的原生迟到返回。关闭后 set 均被拒绝，超时及迟到完成不误报成功。
- 实测挂起操作的完整调用为 1501.153--1514.448 ms；重复超时调用 0.007--0.100 ms；已消耗约 350 ms 后第二次事件只等待 1151.890--1154.284 ms。全部通过的子进程在最终报告后 8.700--32.563 ms 以 code 0 真正退出，不能只把函数返回视为退出通过。外部看门狗正常上限 8 秒；负对照故意保留 JS interval，约 2035 ms 被杀，明确记 FAIL，测试脚本退出码 1。
- 保留失败证据：修复前 45 次重复有 3 次失败（其中 1 次看门狗强杀）。Windows 等待返回 WAIT_TIMEOUT 时，下一次 QPC 读数偶尔仍略早于计算截止点，旧代码未锁存 timeout；环境测试断言失败后留下持有中的 Worker，导致看门狗强杀。已改为实际 WAIT_TIMEOUT 立即锁存失败，并新增确定性 early-timeout 注入；重新运行 48 次全部通过。旧结果保存在原型 `out/results-before-timeout-fix.json`，不算通过。
- 限制：验证的是软件有界等待策略，不是精确墙钟 1500 ms 的实时保证；调度、系统暂停、内核调用和 Node/GC 仍不可给出硬上界。原型返回诊断快照会分配 JS 对象，不能拿 nativeMs 冒充完整事件路径。启动阶段 DLL/线程/事件创建也无绝对 OS 耗时保证；假初始化就绪等待为 250 ms，未就绪明确失败。日志只用内存 trace/工作线程假阻塞，不证明真实磁盘日志耐久性。没有测试 Electron GUI 消息泵、WinINet 或正式打包，不能据此认定注销清理已解决。
- 建议：可以继续评估，但前提是接受“进程寿命 pin + 放弃等待而非取消操作”的取舍；若要求卡死后原地重启模块或隔离原生崩溃，倾向预启动独立 helper。真实 WinINet、Electron 独立载体及新会话实验均须另交计划、等用户确认，当前不继续执行。原型复现命令与逐项结果见其 README；JS syntax check、C warnings-as-errors 编译及 git diff --check 通过。

2026-11-02 (agent，自主 goal：转预启动用户级 helper 路线，进行中):

- run 41199791603 保留两次注销证据：注销前同步清理均失败，RunOnce 均成功，但登录后约 77–82 秒才清理。停止剩余注销/关机重复测试；不记作问题已解决。用户允许实验/draft PR 使用预启动用户级 helper，不代表接受正式架构；ADR-0011 不改，ADR-0013 保持草案，Status 不改、不合并。
- 已完成 2A 和 2A-H 原型证据归档，位置为 `.scratch/mvp/prototypes/`。2A 消息感知等待因任意 sent-message/JS 重入和 handler 超时被否决，不豁免、不放宽预算；这是假操作证据，不是真实 WinINet 消息依赖已经成立。2A-H 的 helper 在 Electron 退出/JS 卡死时能独立推进假清理和准确假 Core 停止；9 个策略场景通过，两个需要外部救援的负对照仍记退出失败，正常退出和强制退出分开记录。实际 OS 会话事件未验证。
- 正式 WinINet get/set/clear 共用现有操作及端点判断，供独立恢复实验复用；CLI 仍管理 RunOnce，实验调用关闭恢复登记，不改 RunOnce。修复每次操作的 JSON/RAS 枚举内存释放，并新增假 RAS/WinINet 回归测试：RAS 枚举失败不能返回 `ok:true`，不能因 LAN 已关闭就删除恢复项。测试先复现旧代码失败，再修复通过；无真实代理写入。
- `wininet-recovery` 新增仓库外 LAN/RAS 原样字段备份、Internet Settings 导出、只读 RunOnce 记录、全连接/逐项恢复前校验、严格 parser 和独占 writer 锁。旧 writer 的 Job 未确认清空时不恢复；日志缺失、锁遗留、外部变化均停止，不盲目 reg import。六个损坏快照及纯状态校验通过。最新只读备份 `C:\Users\DT-056\kuro-sysproxy-backups\wininet-1793590661881` 已验证，未执行 set/clear/restore 或通知调用。其他代理 GUI/Core 仍运行，因此暂不进行真实代理写入；服务本身与 GUI/Core 的写入竞争需区别判断。
- Windows 全套 desktop 测试夹具改用真实 named pipe、系统临时目录、无提权 junction；POSIX 权限仍在 POSIX 校验，SIGTERM 忽略分支在 Windows 用定向假信号测试，未跳过失败用例。bundled mihomo 集成测试使用锁定版本、独立目录和仅本地回环请求，覆盖 traffic/logs、重启后 pipe 轮换及同一 transport 重连。本机 typecheck 与 151/151 desktop 测试通过，无跳过。cat mask 测试单独通过，完整运行改用两个 worker 避免进程争用，没有调高测试或关闭超时。
- CI 改为 Windows 打包后执行全部 desktop 测试，不再只跑 helper 三文件；macOS 打包后强制跑 bundled Core 集成。CI 与产物核验结果另补。正式 resident 生命周期/IPC/Core 句柄交接、真实 WinINet 通知测试、恢复代次竞争，以及人工注销/关机仍未完成。goal 保持 active，不能提前标 complete。

2026-11-02 (agent，协调模型补充，非真实会话验证):

- 安全修复基线 `a92499b` 的 CI `41384542991` 已通过 Windows/macOS；下载产物 `C:\Users\DT-056\kuro-08-artifacts\run-41384542991`，确认 `resources/bin/kuro-sysproxy.exe` 为 x64 GUI，execFile/execFileSync 的 get 均能读 JSON，打包 Core 与锁定下载一致。这仍是 one-shot 基线，不是 resident 会话测试候选。
- 原型修复了按注入故障标记选择自终止的缺陷：1900 ms 有限迟到操作先复现 timeout 却普通退出，改按实际结果判定不确定并自终止。随后增加独立隐藏原生窗口、私有测试消息、共用截止时间的 query 等待和重复事件拒绝递归等待。
- 本机十四个策略场景符合预期：七个正常假清理、六个不确定后自终止、一个强制停假 Core；均无外部救援或 Job 遗留。普通等待与假同步通知互等后超时；原生 helper 消息感知等待完成假链路；窗口过程永久卡死仍由独立监督线程结束。两个外部救援负对照继续计为退出验收失败。清理 1500 ms、Core stop 至 2000 ms、确认至 2100 ms 均沿用原始绝对截止时间，不因事件续期；并非硬实时墙钟保证。
- Windows CI 新增原型与救援负对照。首次 run `41387138363` 在启动 Electron 前因包内缺少 `dist/electron.exe` 报 ENOENT，非超时失败；已保留诊断产物并补显式执行锁定版本 Electron 的安装脚本，等待重试结果，不跳过用例或放宽时限。
- 详细报告及命令在 `.scratch/mvp/prototypes/prestarted-helper-deadline/README.md`。未写代理、RunOnce，未投递真实会话消息或注销/关机；真实 WinINet 写入仍因其他代理程序运行而暂停。正式集成与人工验收未完成；ADR-0011、Status 不改，ADR-0013 仍为草案，不合并。

2026-11-02 (agent，隔离 CI 的真实 WinINet 线程桥接):

- 本机仍不做代理写入。改在独立 GitHub Windows Server 2025 runner 上使用仓库外备份和受控恢复，保留竞争进程检查、旧 writer Job 清空证明及恢复前状态核对，不改 RunOnce。恢复失败/拒绝时现在保留 writer 锁，不能仅因旧进程退出就继续写入。
- CI `41388311489` 先通过共享 one-shot set/clear/恢复。加强逐连接 set/clear 后查询后，`41389190950` 因监督器未显式传递 GUI 子进程 stdout 导致证据解析失败；只读 get 在本机先复现、修复后三个标准句柄精确继承的回归通过，不继承 Job 句柄，没有删断言。
- `3ea3673` 的 CI `41390975216` 全部通过：one-shot、原生普通等待、原生消息感知等待均查询到 flags 3→1、正确测试端点/bypass、保留 PAC，恢复原状态且 RunOnce 不变。每种只有一个 LAN，无实际 RAS。原生模式复用协调模型与共享 clear，假 Core 在 clear 决策后正常退出；没有外部救援。新增 API 返回失败用例记录 failed 而非 timeout，十五个假策略场景符合预期；两个救援负对照仍不通过退出验收。
- 下载结果到 `.scratch/mvp/prototypes/wininet-recovery/out/ci-41390975216/`。记录的 clear 0 tick-ms 只表示 GetTickCount64 未跨 tick，不是瞬时完成或硬实时保证。真实 API 在该 runner 本轮未复现假同步通知的互等，不能推广为所有 WinINet/Windows/Electron 场景均无依赖。
- 这是无 Electron 载体的真实 clear 线程桥接：正常设置后才启动协调阶段，使用私有 WM_APP 触发，非正式启动流程、非实际会话消息。正式 resident/Core 所有权接入、恢复代次竞争、本机通知行为及人工注销/关机仍待完成。详细范围、失败与复现见原型 README；goal 不得标 complete。

2026-11-02 (agent，正式退出入口的状态约束):

- Core 原生所有权基础 `72ef6bc` 的 CI `41392779316` 已通过；创建时原子加入私有 Job、暂停后交接准确句柄，已接入隔离协调载体，尚未切换正式 Platform 的 Core 启动。
- 普通退出此前仅关闭 Core 重启入口，仍允许新代理写入，且清理超时/失败被吞掉。现在首次 shutdown 同步关闭 Windows 写入入口，已排队但未开始写入的 set 也被拒绝；重复 shutdown 返回同一操作，不重置首次等待预算。代理尝试后仍请求停 Core，失败/超时不再冒充成功，并在 exit.log 记录 cleanup FAILED/state unknown。
- Windows mutating helper 超时后也永久关闭本实例 set 入口；允许清理重试，但清理成功不会重新开放 set。修复 remembered 为空时误跳过不确定清理的分支。
- 本地 typecheck 和 158 项桌面测试通过，覆盖不可验证的 helper 输出、重复退出、关闭后拒绝 set、队列中的 set、超时后的状态与清理重试。这里的 Promise 等待仅约束异步调用方，既不取消旧 native writer，也不是硬实时保证；旧 one-shot 会话路径尚未替换，不能据此安排或声称真实注销验收通过。resident IPC、原生终止证明和恢复代次仍需继续接入。

2026-11-02 (agent，实际原生 resident 入口的假后端验证):

- `6ce0909` 的 Windows CI `41396967795` 已通过。新增实验性 `serve` 分发入口，复用既有 get/set/clear 与端点校验；正式 Platform 尚不调用。原生 reader、串行 worker、监督线程与独立隐藏窗口分别处理请求、操作、预算和会话消息，不依赖 Electron JS 完成回调。
- 对实际入口替换全部代理后端进行四项测试：正常清理、在途 set 完成后 clear、set 卡死、clear 卡死。前两项正常退出，后两项明确超时并自身终止 42；四项无外部救援或残留进程。结果 `prestarted-helper-deadline/out/resident-1793600817166/results.json`。补上 Core 启动竞态及整个 Core Job 清空检查，不仅检查根进程；重复关闭不续期。
- 既有 18 项 Electron 协调回归通过。native 构建/单测、恢复安全检查、只读 probe、typecheck 通过；桌面测试首轮并行构建时 cat-mask 触发 5 秒超时，未改测试或预算，停止并行构建后完整重跑 167 项通过。这里是软件预算，不是硬实时保证。
- 仍需补原生最终结果验证、Core 启动诊断、恢复代次/稳定路径，再切换正式调用和验证实际新入口。旧 CI 的真实 API 线程桥接不等于该入口已完成真实 WinINet 验收；更不等于注销/关机成功。本机没有代理写入或会话实验；ADR-0011、ADR-0013 草案状态及 issue Status 保持不变，不合并。

2026-11-02 (agent，原生最终报告及 CI 观测修正):

- 客户端新增 `closed` 证据：进程退出且输出管道排空后，返回唯一且结构一致的 shutdown 报告；缺失、重复、截断、格式错误或 `ok=true` 与 timeout/Core 状态矛盾时都返回未知，不能只看 exit=0。晚到的普通响应不能重新开放写入。typecheck 与 172 项桌面测试通过；实际 resident 假后端也逐项比对管道报告和原生日志。
- `5c5adad` 的 CI `41400437372` 未通过：正常假 Core 生命周期短，定时 Job 快照未采到其 PID，准确归属断言失败。保留断言，增加创建前订阅 Job completion port 通知；不扩大等待预算、不按进程名称查杀。新增逐用例证据上传，避免失败时只留下旧矩阵聚合结果。
- 修正后本地 4 项 native、18 项 Electron 协调回归符合预期；两个外部看门狗救援负对照仍计为失败。Windows CI 待重新确认。该改动不是会话验证，也没有接入本机真实代理写入或切换正式 Platform。

2026-11-02 (agent，Core 诊断管道):

- 上述 `92ffe4f` 的 CI `41401279966` 已全部通过，下载核验了 Windows GUI helper 与两组原型证据；正式 app 尚未切换 resident。
- Core 输出不再丢到 NUL：通过独立原生 drain 线程转发到 helper stderr，客户端持续读取并仅保留末尾 16 KiB。关闭时只使用原有 2100 ms 截止时间的剩余量等待诊断，不因日志阻塞延长预算；必要时允许诊断截断。
- 新增第五项实际 native 假后端测试：Core 持续输出且接收端暂停读取，清理/Core stop 后仍退出，无外部救援、无残留。初版夹具把 set-start 标记也写入故意阻塞的管道，导致测试未触发 close 而被救援，该次明确失败；将标记限制到需要它的抢占用例后通过。输出洪泛淘汰旧 marker 的尾部断言也改为分别验证送达与 16 KiB 上限，没有放宽预算。
- typecheck 与完整 173 项桌面测试通过；本轮此前 `/logs` named-pipe 集成超时两次，新增回环请求/源站诊断后独立及全量重跑通过，但尚未确认间歇失败根因。不能把重跑成功当作已修复。没有本机代理写入、真实会话操作或 ADR/Status 变更。

2026-11-02 (agent，恢复登记安全审查):

- `3b37b84` 的 CI `41403356360` 已通过，下载协调证据。诊断输出新增场景没有放宽关闭预算。
- 审查并撤回未提交的“先登记单一 RunOnce 再 set”尝试：A 端点仍启用时，提前把恢复条目覆盖成 B，若 set B 失败/进程死亡，B 的 notOurs 会留下 A。不能用修复一个崩溃窗口的方式引入另一个。没有真实代理写入。
- 当前旧实现的先写后登记缺口仍未解决；正式 resident 路由继续保持未启用。后续必须组合持久化端点集合、同用户有界独占、旧代次恢复及稳定可执行文件路径，尤其不能假定删除旧 RunOnce 就能取消已启动的 legacy helper。具体反例、事务边界与测试门槛记录在 `prestarted-helper-deadline/RECOVERY-DESIGN.md`；这不是 ADR 修改或架构接受。

2026-11-02 (agent，恢复写入独占基础):

- 增加尚未接入正式路径的 recovery-lock 原语：稳定文件、无共享、不可继承、不重试等待；持有期间不能删除替换，只有关闭准确句柄或进程死亡释放。拒绝最终路径为目录/reparse point；调用方仍须选择可信的本地用户目录。文件系统调用本身不是硬实时保证。
- native 单测实际创建私有临时文件及准确测试子进程，验证跨进程争用失败、自终止后释放、不可继承和持有期间不可删除；不读写代理或注册表。已通过 helper warnings-as-errors 构建及既有 native 回归，纳入 Windows 构建测试。该基础尚未实现持久恢复记录/代次准入，不代表 RunOnce 竞争已修复。

2026-11-02 (agent，恢复端点追加日志):

- 在独占文件上增加最多 8 个不同端点的版本化追加记录，完整校验后 append+flush 才允许返回准入成功；B 不覆盖 A。重复准入也执行 flush，不能把前一次刷盘失败当作已经持久化。仅清理整个集合已验证成功后才允许 reset。
- 私有临时文件测试验证 A/B 关闭重开后均保留、去重、容量/非法端点拒绝、截断/损坏记录拒绝及 reset；无代理/注册表调用。helper 编译与 native 回归通过，构建脚本已纳入测试。
- 这仍未接入正式 resident。损坏记录必须保守拒绝而非自动抹掉；checksum 不是针对同用户恶意进程的认证，FlushFileBuffers 也不是所有硬件故障下的绝对保证。RunOnce 登记、legacy 迁移和稳定路径仍待接入，不能声明恢复竞争已解决。

2026-11-02 (agent，实验性 serve 接入恢复准入):

- `serve` 现要求绝对 `--recovery` 路径，独占句柄持续到进程退出，包含超时自终止；set 的已校验端点先追加/刷盘再进入代理操作。整个关闭清理成功后才 reset，reset 失败也判关闭失败。
- 实际 native 假后端五项回归通过：正常/late-set/诊断阻塞清理后日志为空，set/clear 卡死则保留 608 字节记录。超时后立即再启动同入口拒绝 readiness、退出 1、记录字节不变、未启动假 Core；没有外部救援或残留。证据 `prestarted-helper-deadline/out/resident-1793603730003/`。
- 未解决的旧记录目前保守拒绝启动，属于恢复执行器接入前的临时门槛，不能当最终恢复能力。正式 app 仍未切换，原 one-shot/RunOnce 并未因此获得独占保护；后续必须完成有界 replay、稳定登记及 legacy 迁移。无真实代理写入或人工会话实验。

2026-11-02 (agent，有界恢复入口):

- 增加 `recover --recovery <绝对路径> [--log ...]`，复用 native 窗口、worker、report/supervisor，不启动 Core、不开放 IPC/set。取得独占后读取端点集合，调用已有 clear/notOurs；成功 reset，超时保留。不会删除 legacy RunOnce，尚未登记到 RunOnce 或由 app 自动调用。
- 假后端实测活跃所有者拒绝恢复、超时所有者退出后恢复成功、恢复自身卡死则 timeout/退出 42 并保留完全相同记录；无外部救援/遗留，记录 `prestarted-helper-deadline/out/resident-1793604030489/`。native 构建与原有五项策略通过。
- 等待预算在参数/独占文件初始化后开始，不覆盖 OS 进程创建/文件系统调用的任意延迟，不是硬实时保证。真实 API replay、稳定部署登记、legacy 迁移和人工会话仍待完成；本机无代理写入，不改 ADR/Status，不合并。

2026-11-02 (agent，恢复 helper 稳定部署基础):

- 新增尚未由 app 调用的 `prepareRecoveryHelper`：在调用方选定的可信用户目录保留按内容散列命名的 helper，先完整写入并 sync，再以硬链接发布，不覆盖已有版本、不自动删除旧版本；已存在文件必须逐字节匹配，目录路径穿过链接则拒绝。硬链接不受支持时失败，不降级为不安全覆盖。
- 三项私有临时文件测试覆盖并发发布、应用源文件删除后保留恢复副本、更新保留旧版本、篡改拒绝及临时文件清理、相对路径和 junction/symlink 拒绝。使用惰性文本夹具，无 exe 启动、代理或注册表写入。typecheck 与此前完整 175 项测试通过，随后新增的链接目录拒绝专项也通过。
- 仍需将部署目录、native recover 和 RunOnce 登记接成同一生命周期；此工具不是针对同用户恶意并发篡改的安全边界，也不能据此声称更新/卸载恢复问题已全部解决。正式 app 未切换，ADR/Status 不变。

2026-11-02 (agent，新版恢复登记接入):

- 实验性 resident 的准入现按“端点集合刷盘 → 新 RunOnce 登记成功 → set”执行，所有 resident 请求不再管理 legacy 单端点条目；成功关闭/recover 在持有独占期间 reset 并删除新版独立值 `ClashKuroResidentCleanup`。登记/删除失败明确失败。
- 新命令为带引号的保留 exe 路径加 `recover`；从 exe 同目录推导 recovery.bin，拒绝登记到不同 journal，避免命令行重复长路径超过 RunOnce 限制。无参数 recover 自动写 `%APPDATA%\Clash Kuro\data\runonce.log`；显式 --recovery/--log 仍用于测试工具。不会把 legacy 值当成新版值删除。
- 假注册表单测覆盖命令引用、同目录限制、创建/写入/删除拒绝及不存在键；actual resident 假后端也替换登记调用，未写本机注册表或真实代理。共享 native 构建及五项 fake 回归通过。旧版已启动清理的迁移竞争尚未解决，正式 app 仍未切换，不能宣称最终验收完成。

2026-11-02 (agent，失败响应前关闭准入):

- 修复实验性 resident 的失败时序：原来先发布失败响应、再关闭写入口，快速客户端可能插入下一条 set；现在 native 在发布前关闭，TS 客户端收到 mutating ok=false 也在消费者继续前关闭。失败 get 不因此关闭写入口。
- 新单测验证收到失败 set 后立即重试被拒绝；typecheck、14 项客户端测试及五项 native 假后端回归通过。证据 `prestarted-helper-deadline/out/resident-1793604785900/`，无真实代理写入。稳定路径 fixture 的前次 CI 失败与 canonical 临时目录修正已保留，最新 CI 仍待确认；正式集成和人工验收未完成。

2026-11-02 (agent，恢复调用方准入边界):

- 新增 `recoverResident`，为正式启动接入准备：仅当准确子进程退出、stdout 排空、最终报告 ok 且无 timeout/Core 后才返回成功。调用方固定预算到期只请求终止该 child，并拒绝为未知状态，不能以 kill 请求成功作为写入许可，不重试/查 PID。
- 六项单测验证成功、缺失/矛盾/错误报告及预算超时；typecheck 通过。实际 native 假后端也加载正式 TS wrapper，验证恢复旧记录后为空，证据 `prestarted-helper-deadline/out/resident-1793605003668/`。无本机代理/注册表写入。该 wrapper 尚未由正式 Platform 调用，legacy 迁移和会话验收仍未完成。

2026-11-02 (agent，组合完整 resident 生命周期):

- `startResidentSession` 组合“保留 helper 发布 → 旧记录验证恢复 → serve 启动”，前一步不确定不返回可写 session。重复 close 共用同一 Promise/首次预算，立即关闭请求入口；必须准确退出与原生报告均成功才算完成，超时 kill 请求不能冒充清理成功。
- 实际 TS 组合已在 native 假后端跑通，包含复制到保留目录、recover、set、重复关闭、晚到 set 拒绝及清空 journal；typecheck 与五项 native 回归通过，无外部救援，证据 `prestarted-helper-deadline/out/resident-1793605150682/normal/session-result.json`。无真实代理/注册表操作。
- 正式 Platform 尚未调用，必须先补 legacy 迁移准入，并保留 API readiness/pipe 轮换，不把 helper 握手当成 Core API 已就绪。人工会话验收未完成，ADR/Status 不改。

2026-11-02 (agent，新 recover 的真实 API CI 实验准备):

- 增加 `wininet-recovery/replay.c`，使用实际 native recover 引擎、真实 WinINet clear 和 journal，替换登记调用以保证 RunOnce 不变；无 Core、无会话消息。沿用仓库外 LAN/RAS 备份、端点固定验证、旧 writer Job 清空证明、受保护恢复和恢复后逐项核对。
- 本机仅编译并通过恢复 guard/只读测试，不执行 --exercise。Windows CI 增加 `--exercise --resident=recover`，结果单独为 verified-recover.json；尚未取得 CI 结果，不能预报真实新入口已通过，更不能当作注销/关机证据。

2026-11-02 (agent，新 recover 真实 WinINet 证据):

- `078201b` 的 CI `41408156606` Windows/macOS 全部通过。下载 `wininet-recovery/out/ci-41408156606/verified-recover.json`，实际 native recover 引擎及 journal 对 1 个 LAN 查询到 flags 3→1，原设置恢复后验证成功；RunOnce 未变。
- 最终报告 ok=true、timedOut=false、coreGone=true、corePid=0。durationMs=0 是 GetTickCount64 未跨 tick，不能解释为即时完成或硬实时保证。该实验替换登记调用、无 Core、无真实会话消息；未覆盖 RAS，也不证明正式 app 全链路或注销前清理成功。
- 这是新恢复入口的真实 API 证据，区别于此前 plain/aware 桥接；正式 Platform/legacy 迁移与人工会话验收仍未完成。goal 保持 active，不改 ADR/Status，不合并。

2026-11-02 (agent，Platform resident 实验接线，应用启动入口尚未启用):

- `createDesktopPlatform.startResident` 接到真实 session 类型：命令走 owner，不允许 one-shot 写入回退；保留 Core API `/version` 就绪检查及重启 pipe 轮换。Core PID 文件不写 helper PID，也不通过 PID 猜测来停止 resident Core。
- 普通关闭、session hook 及重复关闭共享清理 Promise，关闭失败/超时不报告成功；session hook 不再生成新 helper，返回明确的“native completion 尚未验证”。意外 owner 退出永久拒绝该 Platform 寿命内的新写入。
- 每次 owner 关闭使旧代理适配器 generation 失效；重新启动建立新的适配器，旧排队操作不能跨代写到新 owner。启动过程新增 AbortSignal 检查：异步部署/恢复结束后若已关闭，不再生成新 serve；已生成的 owner 接到关闭请求。
- 本机 typecheck、桌面 190 项单测通过（新增 7 项 Platform 假 owner 测试）。actual native fake engine 回归覆盖挂起/迟到返回/日志阻塞及真实 session abort，强杀救援不计通过。无本机真实代理写入。
- 这不是正式应用整体验收：app 创建 Platform 的入口未传 startResident，legacy RunOnce 迁移门禁完成前不启用；尚需真实 Core/Platform 组合与人工会话验证。ADR-0011 不改，ADR-0013 保持草案，Status 不改。

2026-11-02 (agent，resident Platform + bundled Core 组合验证):

- 新增 `prestarted-helper-deadline/platform-test.mjs`，使用现有 Job watchdog 启动现有 mihomo 集成测试；真实 Platform/session/native resident 引擎与 bundled Core 组合，仅 WinINet/恢复登记替换为编译期假操作。本机 `out/resident-platform-1793606532880/result.json` 证明正常退出、watchdogKilled=false、lingeringChildren=false、remaining=0。
- 验证 config 校验、Core API 就绪、traffic/logs 两类流、停止后重启与 pipe 轮换、第二次写入、共享 shutdown Promise 和关闭后拒绝写入。未读写真实代理或 RunOnce，未投递真实会话事件。CI 新增同一入口。
- CI 41409572805 保留为失败：window-stall 时间断言发现 native startEpochMs=1793606305287、JS stall-start=1793606305288，相差 -1ms；报告实际完成、无救援/遗留。native 使用粗粒度 GetSystemTimeAsFileTime；改为 GetSystemTimePreciseAsFileTime，不删除断言、不放宽预算。源码先记录 stall-start 再发送触发，修复后本机完整 18 场景通过；墙钟受校时影响仍不是硬实时证明。
- 新 runner 首次因假定 vitest 位于 desktop/node_modules 失败，改为从 desktop package.json 解析已安装依赖；未新增依赖。actual native fake engine 5 场景回归通过。
- 本机桌面测试与忙等故障注入并行时 cat-glyph 发生 5s 超时（189/190）；不改无关测试或放宽超时，改为故障注入结束后独立重跑并如实记录结果。
- 独立重跑桌面测试 190/190 通过，typecheck 通过。此次不修改 ADR/Status，不启用正式 app resident 入口，不将组合测试计作真实 WinINet 或注销/关机验收。

2026-11-02 (agent，CI 41410619618 失败及测试路径诊断):

- 该 CI 的协调场景通过（包括上轮 window-stall）；真实 Core/Platform 组合测试启动阶段失败。原始错误被 finally 中的 stop 错误覆盖，只看到 cleanup unverified。保留该 CI 为失败，不算验收通过。
- 测试收尾改为保留原始错误及 stop 错误；停止未确认时保留目录而不删除，仍关闭测试自己的 HTTP origin。上传证据增加 test.log，避免后续只剩通用退出失败。
- 本机在原型 out 下建立私有 TEMP junction，重现相同的收尾失败，并暴露原始 `Recovery directory must not traverse links`。这是可重复的路径别名反馈环；远端原始错误被旧测试遮蔽，尚不能断言远端根因已经证实。
- 仅将集成测试 mkdtemp 创建的目录 realpath 后交给 Platform（与 recovery-helper 单测一致）；不修改生产目录安全校验。同一 TEMP junction 复测通过，Job 无救援/遗留。证据 `out/resident-platform-1793607168766/result.json`。
- 本机 typecheck 与全量桌面 190/190 再次通过；等待新 CI 验证远端。未修改本机代理/RunOnce、ADR 或 Status，未启用 app resident 路由或执行会话实验。

2026-11-02 (agent，绿色组合 CI 与先完成 native 清理的证据保留):

- CI 41411540319 (`fb64c96`) Windows/macOS 全部通过；已下载协调证据，真实 Core/Platform 测试 rootExitCode=0、watchdogKilled=false、lingeringChildren=false、remaining=0。路径修正后的远端组合通过，不把前两次失败覆盖为成功。
- 新回归发现 Platform 在 owner.exited 后丢弃 owner，导致 native 已成功清理时，后续 Electron shutdown 无法核验原 owner 的报告，误报 unverified。先在旧代码运行新增测试得到确定失败，再保留 owner 引用到 close 验证结束；退出后立即拒绝新 set，不根据 exit code 单独认定清理成功。
- 非零退出/缺失成功证据仍由原 session.close 拒绝；不允许重开该不确定 Platform。191 项桌面测试及 typecheck 通过。
- 真实 Core/假代理组合增加测试入口先调用 nativeOwner.close、待其实际退出后才调用 platform.shutdown，验证这一顺序仍能保留并核验成功证据。本机 `out/resident-platform-1793607558170/result.json` 通过，无救援/遗留。这是测试入口顺序，不是 OS 会话事件。

2026-11-02 (agent，迁移门禁只读探针与 native 诊断):

- `f637484` 的 CI 41412352668 Windows/macOS 均通过。已下载前一绿色 run 41411540319 的产物，核验 `C:\Users\DT-056\kuro-08-artifacts\run-41411540319\resources\bin\kuro-sysproxy.exe`：42496 bytes，SHA256 `EA5CD0587FD2331B3D44E4BFB45BB4BFDE7F0443337D50CE951F78E4F139B061`，PE x64/GUI subsystem。该 app 尚未启用 resident，不能作为新方案人工会话验收产物。
- 普通用户只读 Token/LSA 探针能够读取自身 AuthenticationId 与 LogonTime；合成未分配 LUID 返回 0xC000005F / 1312。证据 `out/logon-probe-1793608070020/result.json`。此结果只证明 API 在本机可用，不能证明旧 RunOnce 已取走的命令或旧进程不可能再执行；迁移门禁仍未解除。
- native 最终报告增加 UTC 时间、helper PID、触发位图、query/session-end 次数及 flags；事件入口仅更新原子计数，不增加同步文件日志。日志仍由独立报告线程写入，不能延长监督线程预算；报告缺失仍是不确定结果。
- 新报告回归首次暴露共享 `putf` 的 128-byte 静默截断，修为按所需长度完整格式化；不靠放宽测试避免错误。第二次暴露 fixture 将额外诊断字段与客户端刻意投影的可信协议字段整体比较，改为逐项核对全部协议字段并单独验证诊断字段，不扩大正式协议。
- native 五场景回归通过，含 clear/set 卡死自身退出42、日志背压；无外部救援或遗留。证据 `out/resident-1793608356053`。真实 Core/假 WinINet Platform 组合再次通过，证据 `out/resident-platform-1793608365812/result.json`。未执行本机真实代理写入、RunOnce 修改或会话实验。
- 本轮 typecheck 与桌面全量 191/191 通过；未放宽等待预算，未启用 app resident 路由。

2026-11-02 (agent，CI 41414184199 端口占用失败):

- Windows 全量桌面集成测试报 mixed-port 127.0.0.1:50280 EADDRINUSE；该 CI 记为失败，不算交付验收。现有栈只有 bind 回调，不能定位首次 start 或 restart。
- 待区分的解释：释放的随机端口被本 fixture origin/其他进程重占；重启时连接/端口生命周期尚未结束；旧 Core 未完全退出。当前证据不足以指定根因，也不将故障归咎于 native 日志改动。
- 仅补 fixture 阶段、mixed/origin 端口和 traffic 的错误上下文，保留原始 cause，并断言 origin 未重用 mixed-port。没有自动重试、端口轮换绕过或放宽等待门槛。

2026-11-02 (agent，实际 resident serve/WinINet 组合验证入口):

- CI 41414962583（9c64153）及 41414619865 均通过；41414184199 的端口占用失败仍保留，尚未凭后续通过认定根因已修复。
- 增加隔离 CI 的 `--resident=serve`：实际 resident engine、真实 IPC 和 WinINet set/clear，假 Core；注册代码使用独立 HKCU 测试键，核验带引号的 recovery 命令写入/删除，不写真实 RunOnce。
- 沿用仓库外 LAN/RAS 快照、注册表参考备份、状态保护与先确认 writer Job 清空再恢复的流程。重复 CLOSE、不复用外部救援为成功；明确不是 OS 会话事件或 RunOnce 调度验证。
- 本机仅编译新 fixture，运行原有纯恢复条件/损坏快照检查和只读 get；全部通过。真实写入等待新隔离 CI，不在本机执行。

2026-11-02 (agent，实际 serve/WinINet CI 通过及登录枚举边界):

- CI 41415780940（72920ac）Windows/macOS 全部通过。已下载 `out/ci-41415780940/verified-serve.json`：实际 resident IPC set/clear、单个 LAN flags 3→1、私有注册键命令写入/删除通过；helper PID 5928、假 Core PID 2876，清理报告 ok=true/timedOut=false/coreGone=true，观测 durationMs=16。备份恢复后逐项验证通过，真实 RunOnce 未改变。
- 该 runner 只有一个 LAN，无 RAS 样本；触发来自 IPC（triggerMask=2，queryEvents/endEvents=0）。此结果不证明 Windows 10/11 注销/关机可靠性，也不将 16ms 视作硬实时保证。成功结果依赖外部 Job 无救援且确认已空；恢复发生在此之后。
- 只读登录枚举探针追加仅数量统计：25 个 LSA session，14 个可读且属于当前用户，11 个无法分类；证据 `prestarted-helper-deadline/out/logon-probe-1793609544869/result.json`。不能把无法分类当作不存在，因此拒绝将“枚举全部旧登录并等待消失”直接用作自动迁移放行条件。不请求管理员权限解决此限制，继续收敛受控迁移边界。

2026-11-02 (agent，迁移决策边界):

- f86dfe7 的 CI 41416565226 全部通过，draft PR 仍 OPEN/draft。ADR-0013 补充最新实现与测试边界，保持草案；ADR-0011/issue Status 不变。
- 未把旧 RunOnce 安全迁移简化成“删值后等一会儿”或“当前登录不同”。普通用户完整登录枚举无法分类的记录，使这一自动放行路径证据不足；不继续堆叠相同快照探针。
- 请求确定是否接受一次性受控迁移窗口：旧版本及其写入者停止后备份、清理、退役旧条目，由用户手动重启，之后核验才启用新 owner。此前不要求用户现在重启、不触碰本机设置；若接受，再实现配套门禁、before/after 和失败恢复后集中交付。该取舍影响升级体验，不代表接受最终 helper 架构。

2026-11-02 (agent，用户已接受一次性受控迁移):

- 用户明确接受由其手动重启、重启后先核验再启用 resident；现在不重启、不提前启用。继续自动化实现，不再逐阶段请求确认。此前等待该取舍的阻塞已解除。
- 开始实现迁移准入策略：用户身份、重启证据、备份摘要、helper 摘要、端点集合以及旧注册/旧进程/独占所有权/恢复结果均须匹配。任何失败或未知拒绝准入。
- 当前策略单测仅验证规则，不是 OS boot collector、证据真实性或执行器测试；未接入 app，不能凭此文件或手填迁移标记启用。下一步必须让执行器在持有恢复所有权期间采集并核验真实证据，防止检查与启用之间释放锁。
- 本轮 typecheck 通过；全量 194/195，新迁移策略 4 项通过。真实 Core 集成失败在 first-streams，mixed-port 57785、origin 57786，traffic 持续 ECONNREFUSED、originHits=0，logs 超时。与此前 EADDRINUSE 不同，不能宣称同一根因或测试全通过；保留失败，未加重试/放宽超时。

2026-11-02 (agent，并行定位与迁移默认拒绝):

- 按用户授权拆分真实 Core、迁移、交付审查，真实 Core 由单一执行者持有，原生假操作使用独立目录；没有本机代理/RunOnce 写入、resident 激活、重启或会话实验。
- 已在原失败端口 57785 及自然复现端口 57798 定位：两者落入 Windows UDP 排除范围 57722–57821。fixture 只检查 TCP，但 mihomo mixed listener 也需要 UDP；API 可用并不证明代理监听成功。修正 fixture 同端口 TCP/UDP 预留后，直接 Core、假 resident 加真实 Core 均通过；当时工作区全量 199/199。正式启动路径的双协议检查和 listener readiness 仍在补齐，不能以 fixture 通过代替最终集成。完整失败证据见 `prototypes/prestarted-helper-deadline/CORE-FAILURE.md`；历史 CI 的 EADDRINUSE 不归为此根因。
- 增加只读启动事件采集候选：System 日志旧记录内容摘要与 record ID、Kernel-General 12、Kernel-Boot 27、CIM LastBootUpTime、当前 SID、旧 RunOnce 值及已知写入者名单。缺失/损坏/矛盾必须拒绝；进程名筛查不证明不存在改名或未知写入程序。该候选等待文档依据审查及真实重启后验证，不等于完整迁移执行器。
- 本机两次只读采集的 checkpoint 摘要匹配，仍是同一次启动、最近 BootType=2；同次启动拒绝测试通过。策略/采集共 10 项通过，包含 Windows 实际只读采集；没有伪造重启或更改系统时间。
- app 在创建 Platform、清旧代理、启动 Core 之前增加迁移阻断：任何 `data/proxy-migration.json`（包括空、损坏或目录）均禁止回到 legacy 写入路径；此阶段 `--experimental-resident` 也明确拒绝，不能用手填 verified 布尔值解锁。阻断测试 2/2。尚未实现可交付的 resident 正向准入，仍默认禁用。
- 审查发现 replay 失败后的 RunOnce 再调度语义和准入/恢复/owner 交接仍需收敛。操作清单仅为 HOLD 草案，不是现在可以执行的迁移指令。ADR-0011/ADR-0013 状态、issue Status 与不合并限制不变。

- 补充审查：未找到 class-90 BootIdentifier 每次重启唯一或等同 BCD 的一手保证，因此未保留这条采集实现，更不拿它放行。启动事件/CIM/旧记录摘要仅是人工受控 Restart 的旁证；BootType 语义、独立事件关联及时间容差不能提升为通用重启身份证明。候选 collector 当前不授予准入，研究见 `BOOT-EVIDENCE-RESEARCH.md`。
- RunOnce 文档警告被调用程序不要在执行期间修改该键，未添加失败后自我重新注册。明确保留限制：RunOnce 失败后，journal 留存并阻止新 resident，依靠后续 app/人工 replay，不保证下次登录会自动重试。新增假操作回归 7 个场景通过、无外部救援/遗留进程：失败 replay 保持 journal 字节并拒绝新 owner，注册卡死在原预算结束，重复 close 不续期。不是实际 RunOnce 调度验证。
- 三方向回收后，主执行者统一运行工作区 `turbo typecheck test`：8 个 task 成功（6 个未变更包任务命中缓存），桌面本次重新执行 210/210、无跳过、真实 Core 必需。正式 direct/resident 启动均检查 TCP/UDP，并要求 API 与 SOCKS5 greeting 同时就绪；未延长原启动预算。重建原生假 fixture 后 7/7、真实 Core 经假 resident 的 Platform 集成 1/1 通过，未使用外部救援。最终交付仍需迁移执行器及正向准入完成后再冻结提交、统一 CI 和人工验证；这些阶段结果不等于已完成交付。
- 70d6e8a / CI 41447368781 Windows **失败 1/210**（假 Core 重启 TCP EADDRINUSE 51399），macOS 通过。随后本机无缓存全量 **失败 39/210**：UDP 分配器选到了 TCP 排除范围内的 626xx。没有把前一轮绿色当成最终结果。测试专用分配器现避开 TCP/UDP 排除范围和动态客户端端口范围，实际预留双协议；仅在测试动作开始前进行有限、记录原因的地址分配，不重试 Core 启动/失败测试。正式 fixed-port 行为不变。假 SOCKS 对端主动中断的 ECONNRESET 也按精确错误类型处理，其他错误仍失败；具体 CI TCP 占用来源未被证明，历史失败保留。
- 增加 `prepareProxyMigration`（尚无用户执行入口、未真实运行）：先发布阻断 marker，持久备份全部 get LAN/RAS 原文、Internet Settings/Connections 导出、旧命令和两份 helper，再重复核验后执行当前 helper 的 endpoint-bounded clear；完整读回和旧注册退役核验后才发布 prepared 收据。任一异常留在阻断状态，不重试、不恢复、不启用。准备不等于准入，独占 owner 交接和人工重启后正向核验仍待完成。
- 准备执行器的 54 个假命令测试通过。另用唯一一次真实 Windows MoveFileEx 在私有临时目录发布阻断 marker，然后立即在采集前主动终止流程：共 55/55；未调用真实 helper/注册表/代理操作。这仅验证文件发布链路，不证明真实完整准备、断电耐久性或恢复。
- 修复后工作区无缓存 `turbo typecheck test --force` 的 8 个任务通过，桌面 266/266（当时尚未加入最后的单项文件发布测试）。待统一提交与新 CI；不据此提供人工重启指令，也不把 goal 标为完成。
- 21:33:40 再次在所有代码整合后无缓存运行同一完整命令：8/8 task、桌面 **267/267**、26 文件、Core 必需且无跳过，typecheck 通过。包含 55 项准备测试及真实但仅限私有目录的文件发布检查；本机仍未进行任何真实代理/RunOnce 写入。
- 后续 `8a6cc45` 的 CI `41454369038` **失败**：准备夹具使用 macOS `/tmp` 链接及 Windows `RUNNER~1` 短路径，被严格路径门禁拒绝；首个文件测试还包含 netsh 资源盘点，超过单测 5s。仅修正夹具 canonical root、把盘点放到 suite setup，并增加真实别名拒绝回归，不放松正式路径检查或退出预算。再跑本机全量时旧 86px 图标测试耗时 7402ms，结果为 **267 通过 / 1 失败**，不能记整合成功；失败原始输出和细节见 `CORE-FAILURE.md`。未启用 resident，未修改真实代理。
- 图标热循环只把数组解构改为索引读取，18/36/86px 两种状态的完整像素 SHA256 均保持一致，不缩小测试、不增大超时。迁移证据升级为 v2：原生 64 位 uptime 以十进制文本保存，严格下降才提供受控重启的 reset 证据；机器指纹、旧 checkpoint、新启动记录仍作绑定/旁证，取消用 BootType/10 秒时差作为 reset 判断。缺字段/旧版本/未来时间均拒绝；这不是所有权证明，也不代替用户手动 Restart 的确认。采集两种 RunOnce 条目和 hash 命名的保留 helper；初始迁移遇到原生恢复登记时先拒绝，不擅自删除。
- 增加准备回执的磁盘复核：manifest、备份清单、每个文件和当前 helper 都重新计算摘要；准备结束也复读，损坏/改动/别名/越界清单不通过。回执复核本身不授予 replay 或 resident 权限，app 仍然 fail-closed。
- 发现并实际复现原生监督线程延迟后的错误成功：clear 超过 1600ms，旧实现仍报 `ok=true/timedOut=false` 并清空日志。现在以完整 cleanup 的原生完成时间校验原来的 1500ms 截止时间，迟到不再 reset/unregister；故障用例报 exit42、`timedOut=true`，保留 608 字节 journal，不靠看门狗救援。1500/2100/2200ms 预算未变；阻塞中的 OS 调用仍不可取消，后续步骤检查不构成硬实时保证。
- 22:38:37 最终本地无缓存整合：8/8 task、桌面 **335/335**、26 文件、零跳过，包含实际只读 boot 采集与真实 Core。修复 Turbo 未透传测试开关的问题；之前 334/335 的只读 probe skip 不算该项验证通过。原生单测通过，重建后的假操作 resident **8/8**、真实 Core＋假 resident Platform **1/1**，均无救援/遗留进程；证据目录见 `CORE-FAILURE.md`。仍未完成正向 admission、同一原生所有权下的 replay→serve，以及人工会话验证；不交付重启指令，不改变 ADR/Status，不合并。

### 2026-11-02 - Migration entry and admission staging (not delivery)

- CI 41469260599 passed Windows/macOS for cf54ea512b619436ea9d255d90db93e2719c1e30. Intermediate artifact identity, helper x64 GUI PE, collector and Core hashes were independently checked; see ../prototypes/prestarted-helper-deadline/ARTIFACT-cf54ea5.md. This is not a Restart/session-test candidate.
- Explicit prepare/check command handling now precedes Platform creation; ordinary startup retains the marker blocker and resident remains disabled. Preparation backups must be outside installation/repository/data. Read-only check rehashes disk evidence again after collection; it never grants native ownership or enables resident.
- Separate replay-prerequisite policy avoids claiming successful recovery before attempting replay. Protocol-2 client fake-pipe tests require exact child identity, single-use reservation commitment and verified replay readiness; pending/late/failed authorization never admits requests or renews startup time.
- Native per-user ownership primitive was tested in private namespaces (contention, same-thread recursion, abandonment and failures); it is not yet integrated into shipping replay. Remaining native admission/provenance work is not declared complete.
- Local uncached integrated typecheck/tests: 8/8 tasks, desktop 424/424 with real Core and read-only boot probe, zero skips. Native unit tests and rebuilt protocol-1 fake resident 8/8 passed; real Core/fake resident Platform 1/1 passed with no external rescue/leftovers. These do not substitute for native protocol-2 integration, final CI or manual sessions.
- No local proxy/RunOnce mutations, resident activation, Restart, logoff or shutdown. ADR-0011 unchanged, ADR-0013 remains draft, Status unchanged, no merge. Continue toward one final verified delivery revision before user operations.

### 2026-11-03 - Native integration and migration exclusion hold

- Protocol-2 native reservation, durable initial endpoint seeding, provenance and app routing are integrated for testing. Fresh seeds must be persisted before a valid journal header; pending old endpoints cannot report successful pre-admission cancellation. Packaged helper/collector/app.asar identities are bound together; missing profile markers do not bypass retained per-user native state.
- Native unit build and protocol-2 fake resident plus real Core Platform passed locally (1/1, `out/resident-platform-1793639307088`). This is coordination/Core evidence only, not local real WinINet or session acceptance; final integrated tests/CI remain separate.
- Transactional exact old RunOnce retirement failed in a private HKCU fixture with error 6801 / ERROR_RM_NOT_ACTIVE. No actual RunOnce/proxy mutation occurred. The failed experiment stays outside shipping sources; no ordinary compare/delete fallback and no timeout increase.
- Preparation is restricted to capture when old registration is already absent. Absence plus process snapshots cannot rule out consumed-but-not-yet-launched RunOnce. Initial resident admission is explicitly blocked even with Restart confirmation until a stronger legacy launch boundary is established. Native fake admission is not permission to enable the app.
- Delivery remains HOLD. No new Restart, activation or session-test instructions are issued; existing artifacts remain intermediate. ADR-0011, ADR-0013 draft status and issue Status are unchanged; no merge.

- Final local integration at 02:02: all 8 workspace typecheck/test tasks passed, desktop 591/591 with zero skips, actual read-only boot evidence and real Core required. Native private admission 65/65 and legacy engine/v2-wrapper regression 8/8 passed without rescue/leftovers. Earlier 585/2 and 589/1 full-suite failures remain recorded, not relabeled as passing.
- The additional Core restart failure exposed two teardown gaps: readiness destroyed its probe before peer FIN, and stopCore used PID polling rather than waiting for its owned child close. Shared readiness now retains its original deadline through FIN/close; owned termination uses the ChildProcess handle and close event, with unchanged phase limits and no new writes after unverified teardown. This is separate from the original UDP-excluded first-stream failure. Windows CI and packaging still require the final integration revision.

### 2026-11-03 - Cross-platform fixture failures retained

- CI 41497752909 failed: macOS probe instrumentation observed destroy too late to identify the socket; Windows wrapper used JavaScript realpathSync spelling inconsistent with the production native-backed canonical-path guard. The test now observes connect and retains all EOF/close/rebind assertions; fixtures use promises realpath. Local uncached integration remains 8/8 tasks, desktop 591/591 with zero skips.
- CI 41499917232 passed macOS and Windows desktop/wrapper checks but failed native autonomous recovery. Its fixture runner was another raw-TEMP caller, launching the retained executable through a short alias. A private local 8.3 TEMP reproduced exit1 with no mutation/rescue/leftovers; canonicalizing that fixture base passed all 65 scenarios under the same condition. Both CI failures and red/green evidence remain in CORE-FAILURE.md; no failing scenario was skipped or relabeled.
- Initial app admission remains denied, not delivered. The stronger legacy-launch boundary is still unresolved; no actual proxy/RunOnce mutation, executable replacement, activation or Restart occurred. ADR and Status constraints remain unchanged.
