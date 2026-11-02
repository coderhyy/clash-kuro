# Windows 注销/关机：同步试一次，RunOnce 下次登录兜底

状态：草案。前提“注销开始后任何新进程都起不来”还没完全确认（见 issue 08 Comments 的假设 2、3），确认前不定稿；是否放宽 ADR-0011 由维护者决定，本 ADR 不改 ADR-0011。

## 2026-11-02 评估更新（不构成正式架构决定）

- 用户已授权自主推进预启动用户级 helper 的实验、真实 WinINet 验证、draft PR 实现和 CI；并未接受最终架构。ADR-0011 不变，本 ADR 保持草案，issue Status 不变，不合并。真实注销/关机/重启只能由用户执行。
- run 41199791603 的两次注销均未在注销前清理成功；两次 RunOnce 成功，分别约在 Explorer 启动后 82/77 秒清理。停止剩余 5+5 重复测试，不把 RunOnce 成功计作注销清理已解决。
- 2A 的 Electron 消息感知等待被否决：受控假通知可以完成，但 PeekMessage 的窗口过滤不能阻止其他 sent messages 进入 Electron JS；注入 2100 ms JS/native handler 后突破软件预算。重入保护只拒绝递归等待和新 set，不能限制任意回调时长。这个假操作实验证明消息依赖/重入风险，**没有证明真实 WinINet 必然存在相同依赖**。不放宽等待门槛、不豁免失败测试。
- 2A-H 证明预启动 helper 能在 Electron 已退出或 JS 卡死时独立决定清理结果并停止准确的假 Core。9 个策略场景通过（区分正常退出、自行强制退出和强制停假 Core）；两个外部救援负对照仍记退出失败。非 detached Node child 曾被 libuv 父进程 Job 提前终止，改为 detached 后验证通过；外部测试 Job 仍包含整棵被测进程树。
- 新增价值是进程死亡后的存续和地址空间隔离；专用窗口线程 Node-API 也可能绕过 JS 卡死，因此不能把 JS 卡死独立性说成 helper 独有优势。当前尚未实现正式 resident 协议、原生会话窗口或正式 Core 句柄交接。RunOnce 代次竞争及更新/卸载路径仍是必须处理的边界。
- 已建立仓库外 LAN/RAS 备份、严格状态校验及旧 writer Job 确认退出后恢复的工具；只执行了只读快照和纯逻辑故障测试。检测到其他代理程序运行时拒绝真实写入。下一步须先完成安全的真实 WinINet/通知实验，再决定正式集成，不能从协调模型直接推导注销可靠性。

补充协调模型证据（仍非架构接受）：独立 helper 原型增加了隐藏原生窗口及共用原始截止时间的 query 等待；只通过私有测试消息触发。普通等待与模拟同步通知互等后超时，helper 原生线程的消息感知等待能完成假操作并拒绝递归等待。窗口过程永久卡死时，监督线程仍能先报告不确定、停止准确的假 Core，再自终止；没有使用外部救援。这与在 Electron 内泵入任意 JS 的被否决方案不同，但不证明真实 WinINet 有相同依赖，也不证明真实会话期间的存续。正式 resident/Core 集成、真实 WinINet 和人工会话验证仍未完成。

真实 API 的有限证据：CI `41390975216` 在 Windows Server 2025、单个 LAN 上通过共享 one-shot，以及原生普通/消息感知等待下的真实 clear、通知和恢复；操作后查询 flags 3→1，并确认原状态恢复及 RunOnce 不变。该桥接没有 Electron 载体、没有真实会话事件，也没有 RAS 连接；不能替代目标 Windows 10/11 的会话验收或接受正式架构。实际 API 本轮未复现模拟消息互等，不表示所有环境无此依赖。正式实现还需将 Core 交由可靠的原生所有权管理，关闭期间禁止新写入，并处理恢复代次竞争。

证据及复现命令：`.scratch/mvp/prototypes/electron-deadline/README.md`、`prestarted-helper-deadline/README.md`、`wininet-recovery/README.md`（后两者同属该 prototypes 目录）。以下是早期 one-shot 兜底草案，不代表当前方案已经获准或问题已解决。

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

- 注销时不用启动新进程，但直接同步 WinINet 调用没有可取消的硬超时保证，不能仅以通常耗时较短作为验收。预启动用户级 helper 也是候选，并非只有 Node-API 一条路线。
- 原生模块也不能覆盖崩溃、强杀和断电，不能据此删除恢复兜底。WinINet 提前加载和真实会话可靠性仍需实测。

放宽的代价：

- ADR-0011 的硬约束失效：`.node` 文件不能由 electron-vite 打包进产物，要 `asarUnpack`，electron-builder 要能收集它，`dependencies` 不再为空。
- 要按 Electron ABI 和 arch 预编译（N-API 能减轻但不能免除），CI 多一条原生构建链。bun isolated 安装和原生 postinstall 的兼容性要另外验证。
- 主进程里的原生代码一旦崩溃会带走整个 app，而 helper 崩溃只影响一次调用。
- 主进程要多加载 WinINet，并且 helper 和原生模块两份实现并存（macOS 不需要）。

不放宽、但不需要新进程的替代方案（都还没验证）：

- 假设 3 成立（失败只出在 helper 导入的 WinINet/RAS DLL 初始化）时：helper 改成延迟加载这些 DLL；注销时只用 advapi32 直接改 `DefaultConnectionSettings` 的 flags 字节。代价是绕过 WinINet、直接写注册表，这违背了 helper 现在“不直接写代理注册表”的规则，并且已经运行的程序收不到通知。
- 预先启动一个常驻 helper 待命：违反 ADR-0011 的“helper 不常驻”，已否决。
