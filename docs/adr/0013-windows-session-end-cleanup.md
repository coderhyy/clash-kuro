# Windows 注销/关机：同步试一次，RunOnce 下次登录兜底

状态：草案。前提“注销开始后任何新进程都起不来”还没完全确认（见 issue 08 Comments 的假设 2、3），确认前不定稿；是否放宽 ADR-0011 由维护者决定，本 ADR 不改 ADR-0011。

spec 要求退出、关机、注销时先关 System Proxy 再停 Core，带超时，不阻塞关机。Windows 上，注销和关机做不到“每次都在会话结束前关掉”：ADR-0011 不允许原生模块，关代理只能启动 `kuro-sysproxy.exe`，而注销开始后新启动的 helper 在 DLL 初始化阶段就被系统结束。实测 4 次注销都失败：GUI 子系统改动前是 0xC0000142（STATUS_DLL_INIT_FAILED），改动后是 0xC000026B（STATUS_DLL_INIT_FAILED_LOGOFF），clash-verge-rev #5018 在关机时也遇到 0xC0000142。

Windows 上的清理改为三层：

1. 会话结束时同步试一次。`query-session-end` 处理函数里用 `execFileSync` 跑 helper `clear`（硬超时 1.5 s，超时杀掉），只用内存里的端点，不读文件、不 await，不调用 `preventDefault()`；`session-end` 里没清成功就再试一次。结果写进 `exit.log`，包括退出码和 NTSTATUS。普通退出（托盘“退出”）走同一个 helper，不受注销限制。
2. 下次登录时由 RunOnce 清。set 成功后 helper 写入 `HKCU\...\RunOnce\ClashKuroSysProxyCleanup` = `"<helper>" clear --expected-server 127.0.0.1:<port> --log "<dataDir>\runonce.log"`，clear 成功后删除。登录时 Explorer 执行它，不需要打开 Kuro；端点不是我们的（`notOurs`）就不动。
3. Kuro 启动时清理指向本应用 mixed-port 的旧代理（spec 已有规则）。

## Consequences

- 注销到下次登录之间、关机到下次登录之间，当前用户的 WinINet 代理仍指向已停止的端口。代理是按用户设置的，不影响其他用户。登录后到 RunOnce 执行之前，先启动的程序可能用到失效的代理。实测第 4 次注销后，RunOnce 在 Explorer 启动约 80 s 后才执行，晚于 Run 下的自启动项。
- RunOnce 是常见的持久化位置，安全软件可能提示或拦截。拦截时 set 照常成功，只是兜底失效，helper 返回 `runOnceError`，主进程打 warning。
- 删除或移动 app 后，残留的 RunOnce 条目执行失败一次，然后被 Windows 删掉。
- 同步尝试保留：普通退出靠它；以后的 Windows 版本如果允许注销时启动进程，它会直接生效。

## 待决定：是否放宽 ADR-0011

放宽的做法是允许一个原生模块（N-API addon，或 koffi 这类 FFI），在 Electron 主进程里直接调用 WinINet。clash-party 就这样做：它的 `disableSysProxySync()` 用的是 `sysproxy-rs` 原生模块。

放宽的好处：

- 注销时不用启动新进程，在 `query-session-end` 里同步调用 `InternetSetOptionW`，耗时毫秒级，是唯一可能做到 spec 原意的路线。前提是 WinINet 在启动时已经加载，并且已运行的进程在注销时还能正常调用它；这一点也还没在本机验证。
- 可以去掉 RunOnce 兜底，也就没有持久化位置的误报问题。

放宽的代价：

- ADR-0011 的硬约束失效：`.node` 文件不能由 electron-vite 打包进产物，要 `asarUnpack`，electron-builder 要能收集它，`dependencies` 不再为空。
- 要按 Electron ABI 和 arch 预编译（N-API 能减轻但不能免除），CI 多一条原生构建链。bun isolated 安装和原生 postinstall 的兼容性要另外验证。
- 主进程里的原生代码一旦崩溃会带走整个 app，而 helper 崩溃只影响一次调用。
- 主进程要多加载 WinINet，并且 helper 和原生模块两份实现并存（macOS 不需要）。

不放宽、但不需要新进程的替代方案（都还没验证）：

- 假设 3 成立（失败只出在 helper 导入的 WinINet/RAS DLL 初始化）时：helper 改成延迟加载这些 DLL；注销时只用 advapi32 直接改 `DefaultConnectionSettings` 的 flags 字节。代价是绕过 WinINet、直接写注册表，这违背了 helper 现在“不直接写代理注册表”的规则，并且已经运行的程序收不到通知。
- 预先启动一个常驻 helper 待命：违反 ADR-0011 的“helper 不常驻”，已否决。
