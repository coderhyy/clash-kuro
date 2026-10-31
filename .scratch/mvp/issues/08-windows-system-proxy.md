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