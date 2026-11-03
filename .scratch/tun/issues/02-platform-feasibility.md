# TUN 权限与固定版 Core 的平台可行性

Status: resolved
Type: research
Blocked by: 无（只读研究与无系统网络副作用的检查）
Owner: 技术研究 agent；主会话审阅

## 负责范围与交付物

写 `../platform-feasibility.md`，引用 Apple、Microsoft 和 mihomo 固定 v1.19.33 的一手资料或对应源码，注明访问日期。检查现有打包配置；不安装 helper、服务、驱动，不启动 TUN，也不写系统代理/路由/登录项。两平台资料可并行收集。

## 验收标准

- macOS：明确 TUN/Core 所需权限，当前 arm64/ad-hoc 包可用或不可用的安装/鉴别路径及证据；列出用户授权、更新、卸载和失败清理要求。
- Windows：明确固定版 Core 的 TUN 组件/产物、权限与分发要求；解释提权后怎样保留当前用户 WinINet 语义和唯一 Core owner，无法确认的地方单列。
- 两平台：核对私有 socket/pipe 的跨权限访问边界、用户可写可执行文件/Runtime Config 的风险、Core/路由退出与恢复语义；每项结论指向一手来源。
- 输出供 D2 选择的最小可行候选及实际签名阻塞，区分“资料证明”“本地检查”“仍需实验”；不把最新文档直接算作固定 Core 已验证。
- 若需实验，仅给出隔离 fake/只读检查方案和通过标准；真实权限/网络实验交主会话协调。

## 已完成的本地盘点

2026-11-03：`../spec.md` 已记录固定 Core、现有配置透传、普通 macOS spawn 与 Windows 当前用户 owner 边界。尚无本票官方平台结论；后续 agent 从此继续。

## Comments

2026-11-04：完成 [平台研究](../platform-feasibility.md)，依据固定 mihomo v1.19.33 / sing-tun v0.4.28、Electron v45.1.0、Apple 官方在线资料与本机 SDK27，以及 Microsoft 官方权限/服务/IPC 文档。

- 固定 Core 已含两平台 TUN；Windows 内置 Wintun 0.14.1 amd64 DLL 与官方 ZIP 逐字节相同，427552 bytes，SHA256 `e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce`。内置分发许可/notice 在最终产物中仍需落实。
- macOS 原生 utun 要求 root；SMAppService LaunchDaemon 的官方 SDK 契约含签名、公证与升级后重新注册，当前 ad-hoc 未公证包不满足该路线的已声明条件。Electron 45 已有 daemonService 注册 API；不因此引入 Node addon。
- Windows TUN 写路由需管理员/提升上下文；服务创建需 SCM 管理员权限，LocalSystem 不是交互用户，named pipe 须明确 DACL/会话边界。现有用户代理 owner 不能直接换账户继承全部语义。
- 报告列出候选、具体阻塞、跨权限信任边界和最小后续实验；没有选定服务安装方式、首批平台或 TUN/System Proxy 策略。01 仍为 needs-info，03 仍等待决定。
- 本票完成的是只读研究和字节检查，没有执行提权、安装、TUN、路由或真实会话实验，也没有把正常 Close 源码当作异常恢复通过。
