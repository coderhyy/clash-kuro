# TUN 平台可行性研究

Status: resolved（资料研究完成；产品与架构选择仍在 01）
研究日期：2026-11-04（Asia/Singapore）

## 结论

当前固定的 mihomo **v1.19.33 已包含 macOS / Windows TUN 实现**，无需先升级 Core。可行性瓶颈是权限、安装组件、跨权限控制通道及网络状态恢复，不是缺少 TUN 引擎。现有 Windows System Proxy helper 只具备当前用户权限，不能直接承担系统 TUN 权限，也不能把其整个生命周期改成 LocalSystem 后沿用当前用户代理语义。

macOS 若选择现代 **SMAppService LaunchDaemon** 路线，Apple SDK 明确要求应用代码签名，包含 LaunchDaemon 的应用须公证；当前 ad-hoc、未公证产物不满足该文档契约。该条件只阻塞所选 LaunchDaemon 路线，不能据此宣布所有 TUN 方案均需先完成正式签名。Windows 可以研究每次授权的提升进程或经管理员安装的服务；二者均需新的权限和生命周期设计，尚未选定。

本文的“源码证实”表示对应固定源码存在该行为；不代表打包产物已经在目标系统创建过 TUN、完成授权或正确恢复了路由。没有执行真实提权、服务安装、TUN、System Proxy、登录项或会话操作。

## 1. 固定 Core 与 TUN 产物

| 项目 | 一手证据与结果 | 实验边界 |
| --- | --- | --- |
| 固定 Core | 本地 `apps/desktop/core.lock.json` 为 v1.19.33；官方 tag 解析为 `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`；`go.mod` 固定 `sing-tun v0.4.28` [M1][M2] | 未重建 Core，也未证明发布二进制可复现构建；当前安装包仍以 lock 的归档 SHA256 约束 |
| 可用配置 | 固定版有 `enable`、`stack`、`device`、`auto-route`、`auto-detect-interface`、`strict-route`、DNS hijack 和路由范围等字段 [M3]；listener 创建真实 TUN、network monitor、stack，并有 `Close()` [M4] | 字段存在不等于首版全部开放；默认值和 UI 仍由 01 决定，最新官网示例不能替代固定版源码 |
| macOS | 固定依赖走 `AF_SYSTEM` / `com.apple.net.utun_control`，支持创建 utun 或接受已有 `FileDescriptor` [T1]；Apple XNU 对该控制接口设置 `CTL_FLAG_PRIVILEGED`，源码注释为 `Require root` [A1] | 这是 Core 原生 utun 路线，不是 Network Extension 实现证明。FD 入口存在也不证明“仅创建 FD 后降权”足以承担后续路由、DNS、网络变化处理 |
| Windows | 固定依赖创建/打开 Wintun adapter，设 IP/DNS、按选项添加路由与 WFP 过滤器；Windows `New` 拒绝非零 `FileDescriptor` [T2] | macOS 的 FD 候选不能照搬到 Windows |
| Wintun 分发 | 固定依赖为内置 Wintun 0.14.1，amd64 DLL 用 `go:embed`，经内存装载 [T3]；无需因开 TUN 再随意下载一个新版外置 DLL | 实际受支持 Windows、安全软件、驱动初始化与签名接受仍需目标机验证 |

只读字节检查：从 Wintun 官方 `wintun-0.14.1.zip` [W1] 读取 `wintun/bin/amd64/wintun.dll`，与固定依赖 `internal/wintun/amd64/wintun.dll` 比较，均 **427552 bytes**，SHA256 均为：

`e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce`

两者逐字节相同。第一次 `gh api` 原始二进制输出被工具截为 2 bytes，仅 `MZ`；该次比较无效，没有计作产物差异。改读 GitHub JSON 的 base64 内容并确认解码长度等于 API `size` 后才得到上述结果。此处没有执行 DLL，也未在 Windows 调用签名验证 API。

Wintun 官方说明只支持分发其预编译签名 DLL，并附专用二进制许可 [W2]。本次读到 ZIP `LICENSE.txt` 的分发例外要求软件仅经 Permitted API 使用 DLL，并保留相关限制；固定依赖使用内存装载及函数查找的事实不能自动当作整个产品的许可审核完成。当前 `fetch-core.mjs` 只明确复制 mihomo LICENSE，TUN 交付前应核对 Wintun notice/许可在最终资源中的覆盖，处理方式由实现/打包票审阅，勿自行改 DLL。

## 2. macOS 授权、签名和安装生命周期

**官方已说明：**

- SMAppService 在 macOS 13+ 提供 main app / LoginItem / LaunchAgent / LaunchDaemon 的注册、注销和状态 API [A2]。LaunchAgent 与普通登录项不能被当作 root 网络权限来源。
- LaunchDaemon 的 plist 位于调用 App 的 `Contents/Library/LaunchDaemons` [A3]；注册后须管理员在系统设置批准，批准后系统在后续 boot bootstrap [A4]。是否立即执行业务、是否每次开机运行或按需运行，仍取决于所选 plist 与产品生命周期，不能把注册成功当成 TUN 已就绪。
- 本机 Apple **MacOSX27.0 SDK** 的 `SMAppService.h` 明确写有 `Apps that use SMAppService APIs must be code signed.`、`Apps that contain LaunchDaemons must be notarized.`，并规定更新 plist 或可执行文件后重新注册，建议可执行文件更新前先 unregister [A5]。注册还可能返回 `kSMErrorInvalidSignature`。
- 官方升级文档要求读取授权状态、让用户在系统设置改变授权；LaunchDaemon 授权不能静默跳过 [A6]。注销 API 让系统不再启动该服务 [A2]；已运行的 Core、TUN 网络状态及授权记录怎样退出/清理须单独设计和验证。
- 固定 **Electron v45.1.0** 的 `app.getLoginItemSettings` / `app.setLoginItemSettings` 已支持 `type: 'daemonService'` 与 `serviceName`，并支持非默认服务状态 [E1]。因此“必须添加 Node addon 才能调用注册 API”并不成立；现有外部 native helper / Electron API 约束可继续研究。

**对当前产物的具体判断：** `electron-builder.yml` 为 `identity: '-'`、`hardenedRuntime: false`，ADR-0010 明确未公证。它不能被宣称已符合 A5 的现代 LaunchDaemon 分发契约。尚未用当前产物试注册，也不建议把某系统版本上偶然注册成功提升为受支持发布方案。正式签名/公证只在选定此机制后成为具体交付依赖。

**可供维护者选型的候选，尚未批准：**

| 候选 | 已有依据 | 仍需决定/证明 |
| --- | --- | --- |
| SMAppService 内嵌 LaunchDaemon | 官方登记、审批、状态与升级规则；Electron 已有注册入口 | 是否接受系统级组件和公证前置；最小特权协议、客户身份、按需退出与清理；最低系统版本 |
| 管理员安装传统 LaunchDaemon | Apple 仍描述 `/Library/LaunchDaemons` 系统级机制，SDK说明旧方式受文件权限保护 [A5][A7] | 需要管理员安装与权限/升级/卸载策略；不能用传统路径绕过调用者鉴别，也不能默认当前 ADR 已批准服务 |
| 本次运行授权的短生命周期 helper / FD 准备 | 固定 macOS TUN 接受 FD；现有项目允许外部可执行文件 | 具体受支持授权 API、持续 route/DNS 权限、父退出与 helper 失败、FD 传递及 ACL 均未验证；不能把 sudo 或完整 GUI 提权当作既定体验 |

## 3. Windows 管理员、服务和当前用户边界

- 固定 TUN 写入路由，Microsoft `CreateIpForwardEntry2` 明确要求管理员及提升上下文；普通管理员组成员受 UAC 约束仍可得到 `ERROR_ACCESS_DENIED` [S1]。当前用户 WinINet 成功不能证明 TUN 会成功。
- Microsoft `runas` verb 启动提升进程，并由 UAC 要求同意或管理员凭据 [S2]。这证明可研究一次运行授权候选，**不证明普通 Electron spawn 能透明提升后保留 stdin/stdout、父身份和 Job 所有权**；跨提升 IPC 和监督需新设计。
- 创建服务需要 `SC_MANAGER_CREATE_SERVICE`，官方权限表说明只有管理员进程能获得用于 `CreateService` 的 SCM handle [S3]。服务运行账户可配置，不是 TUN 必须永远采用 LocalSystem [S4]。
- LocalSystem 不关联任何已登录用户；其 HKCU 不是交互用户 HKCU，权限显著扩大 [S5]。因此现有 per-user WinINet owner 不能简单整体切到 LocalSystem。需保留当前用户身份明确的代理操作，并明确唯一 Core owner 和准确跨权限句柄；用户态代理 worker 与特权 Core owner 若拆分也必须有一套统一 shutdown 所有权，而非双 owner。
- Windows named pipe 的默认 ACL 给 LocalSystem、管理员和 creator owner 完全权限，并给 Everyone/anonymous 读权限；Microsoft 要求用明确 DACL / logon SID 限制会话访问 [S6]。随机 pipe 名和当前进程继承规则不能自动充当新管理员服务的鉴权。
- Windows 用户态服务 EXE 的产品签名与内核驱动签名是不同事项。官方内核驱动签名策略约束驱动 [S7]；本版本使用官方现成签名 Wintun 字节，无需因此自行开发/签一个驱动。是否要求产品 EXE 签名、受保护安装位置和安全软件准入，仍是分发决策和实测项。

候选为“每次授权的应用生命周期特权 owner”或“管理员安装的窄权限服务 + 明确的当前用户接口”。SCM 的 demand-start 服务可以研究，但退出 App 后是否仍运行、能否自动重启、服务账户与多用户范围都须 D2 决定；本次不将服务、KeepAlive 或提升整套 GUI 设为默认。

## 4. 共同的信任与恢复约束

以下为一手事实对本仓库产生的设计要求，尚不是新公共 API：

1. **产物与配置边界。** 当前 App 数据、Runtime Config 与用户 Profile 位于用户可写目录；现有 Core 归档 SHA 校验属于下载校验，并不自动保护已安装路径免遭普通用户替换。任何 root/admin helper 读取此类 Core 路径/配置或接受写路径，都须定义允许范围、拒绝符号链接/替换竞争及调用者身份。不能提供任意命令、任意执行路径的特权 RPC。
2. **控制通道。** ADR-0002 的 Unix socket 0600 / 随机 named pipe 在同用户模型下定义；Core 跨权限启动后必须重审 socket 所有者、父目录和 Windows 明确 DACL。不能为了可访问而放开 TCP 控制器或全员访问。
3. **停止成功。** 固定 listener `Close()` 会关闭 TUN、stack 与 monitors [M4]；Windows 关闭 session/adapter/WFP handle，macOS 关闭 utun/DNS registration [T1][T2]。这些是正常清理代码，不构成崩溃/强杀/断电后路由或 DNS 均恢复的证明；现有准确 Core stop 也不能替代网络状态读回。
4. **现有 Windows 恢复。** 既有普通退出、注销、关机样本和新 TUN 路由是不同证据。07 的取消关机、残留 journal 启动回放和显式 retained-helper 回放仍单列；父 EOF 自动清理不算回放通过。原 owner 的软件预算不因 TUN 研究被静默延长。
5. **源码引用边界。** 研究只读取 mihomo/sing-tun 的行为，不复制其实现到 MIT helper；继续遵守 ADR-0006 的参考/独立进程分发边界。最终许可证、notice 及源码获取方式须按实际产物核对。

## 5. 可以继续的工作与实验门

**现在可继续：** 01 可用本报告完成 D1/D2/D3；公共契约设计可据此列候选，但源码实现仍等选定行为与必要 ADR 决定。Windows issue 08 已由主会话核实合入 `origin/main 6ea3720`、PR #1 MERGED，05 的该主线整合依赖已满足；最终集成 CI 由主会话核验，本文不将其标为 TUN 平台已验收。

**无需真实网络的下阶段检查：** 审阅 privilege RPC 的非法操作/路径/身份测试；fake helper 的授权拒绝、失联、重复启动、准确 Core 归属与 deadline 测试；配置与旧 Backup 兼容测试。主会话先固定 03 接口再分派，避免现有平台和 State/UI 同时编辑公共入口。

**选型后才有意义的真实实验：** 当前精确签名包的注册/批准/拒绝/升级/注销；Windows 提升及服务账户/pipe ACL 检查；各平台真实 TUN、DNS/路由前后读回与停止失败恢复。每例须主会话安排同机器独占时段、基线备份及恢复证据。未运行这些实验；不提出断电或宽化测试矩阵。

## 资料索引

全部为一手来源，2026-11-04 获取。GitHub 使用 agent-reach 的 gh 路由；Apple / Microsoft / Wintun 页面通过其网页阅读路由读取。临时原文和下载仅保存在 `/tmp`，研究结论按任务授权写入仓库。

- [M1] [mihomo v1.19.33 tag API](https://api.github.com/repos/MetaCubeX/mihomo/git/ref/tags/v1.19.33)
- [M2] [固定 Core 的 go.mod](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/go.mod)
- [M3] [固定 Core 的 TUN 配置](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/config/tun.go)
- [M4] [固定 Core TUN listener / Close](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/server.go)
- [T1] [sing-tun v0.4.28 macOS 源码](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/tun_darwin.go)
- [T2] [同版 Windows 源码](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/tun_windows.go)
- [T3] [内置 DLL go:embed](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/internal/wintun/dll_windows_amd64.go)、[内存装载](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/internal/wintun/dll_windows.go)、[内置版本声明](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/internal/wintun/README.md)
- [A1] [Apple XNU utun 特权标记](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/if_utun.c)（该 XNU 发布源码说明系统接口，不是本机运行内核逐字节验证）
- [A2] [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice.md)
- [A3] [daemon(plistName:)](https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:).md)
- [A4] [register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register().md)
- [A5] Apple 官方本机 SDK27.0：[SMAppService.h](/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ServiceManagement.framework/Headers/SMAppService.h:49)（签名、公证及重新注册的 API 契约；在线 A2 概览未重复全部 header 条件，故保留明确本地来源）
- [A6] [Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos.md)
- [A7] [Apple launchd jobs 指南](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)（归档文档，仅用于传统机制，不能代替现代批准要求）
- [E1] [Electron v45.1.0 app API](https://github.com/electron/electron/blob/v45.1.0/docs/api/app.md)
- [S1] [Microsoft CreateIpForwardEntry2](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-createipforwardentry2)
- [S2] [Microsoft Launch / runas](https://learn.microsoft.com/en-us/windows/win32/shell/launch)
- [S3] [Service Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights)
- [S4] [Service User Accounts](https://learn.microsoft.com/en-us/windows/win32/services/service-user-accounts)
- [S5] [LocalSystem Account](https://learn.microsoft.com/en-us/windows/win32/services/localsystem-account)
- [S6] [Named Pipe Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [S7] [Kernel-mode Code Signing Policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-)
- [W1] [Wintun 0.14.1 官方 ZIP（含 LICENSE.txt）](https://www.wintun.net/builds/wintun-0.14.1.zip)
- [W2] [Wintun 官方分发与签名说明](https://www.wintun.net/)
