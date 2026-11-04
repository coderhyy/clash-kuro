# macOS 特权 helper

Status: ready-for-agent（实现与隔离验证；真实操作等“开始”）
Type: task
Blocked by: 生产接入须主会话接受安全设计与 06 最小契约；真实安装/网络验证等“开始”；09 路线已解决
Owner: macOS helper agent；主会话分配安装/认证文件范围并集成

## 负责范围

管理员安装传统 LaunchDaemon + 小型 helper：受保护安装、升级卸载、peer 认证与有限 broker、准确 Core owner、自有网络归属和清理。合并 [11 安装事务](11-protected-install-transaction.md) 与 [12 认证/broker](12-peer-authentication-and-broker.md)，保留其原型与证据；不改 State/UI。依据 [安全方案](../macos-helper-security.md)、ADR-0014/0015/0016 及 [0017](../../../docs/adr/0017-macos-tun-dual-stack.md)，不依赖付费会员，不使用 setuid Core、任意 root 命令/路径、关闭 SIP 或全局 Gatekeeper。

安装事务与认证/协议实验可并行；生产 pin 必须来自受保护安装记录，不能信请求方自报 PID/hash 或仅 UID。与 [06](06-state-and-ui.md) 的机制无关契约/测试并行，生产接入再汇合。

## 验收标准

- 安装事务：固定目标和精确产物，拒绝目录逃逸、symlink、可写祖先、setuid/setgid 与篡改；管理员批准字节绑定实际消费并在受保护 staging 复核。升级先确认旧 writer 停止；取消/部分失败可观察，只删清单确认的自有组件，未知时保留恢复能力。
- 认证与 broker：内核 peer 身份结合完整 Electron 资源/启动/注入边界与受保护 pin；有限操作逐项校验参数、大小、版本、会话和重放，拒绝未知/额外字段。root Core 控制 socket 保持私有，不开放通用 HTTP/configs/provider/升级绕过入口。
- 生命周期：单一准确 owner；安装不启动代理，App 退出/客户端消失有界停止 TUN/Core，仅恢复本应用网络。正常重开先检查残留，保持 TUN 关闭，用户手动开启；归属或清理未知则关门，异常不重启 TUN，卸载先清理再移组件。
- 网络工作清单：IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试；明确 IPv4/IPv6/DNS 归属和第三方冲突。双栈固定模板/无高级 UI/技术参数选定已批准，候选和版本证据见 [spec](../spec.md#固定版本事实与技术候选)；root 有限 schema 验证通过前不接入模板，候选不等于网络通过；不静默关闭 IPv6，不以 IPv4-only 宣称全流量/防泄漏。
- 隔离/负例、Core/平台回归、typecheck 与打包通过；原型通过不等于生产认证/真实 root/launchd/网络验收，后者交 [08](08-tun-integration-acceptance.md) 串行执行。

## Comments

2026-11-04：11/12 已归并，本票未实现完成。既有安装目录模型 16/16（setuid 为元数据模拟）、C 身份原语两分支是有限证据，原记录见历史票。源码由实施 agent 交付，最终命令、产物与验证证据待回填；没有真实系统授权。

2026-11-04 后续：离线产物准备器已接入 `bun run --cwd apps/desktop prepare-macos-helper darwin-arm64`。它从固定锁/缓存验压缩包，解压后与现有 Core 资源逐字节比较，另验 helper pin、Mach-O 头部/架构/权限及路径，生成禁用 plist 与 executable hash manifest；不安装、不执行 helper。新增20项（含arm64/x64）+fetch-core既有3项测试通过，独立复核通过。真实资源执行按预期exit1：原生 helper 与 helper.lock 尚缺，不生成可安装产物。头部检查不证明实际可加载性，临时构建目录检查不证明 root/ACL/同UID竞态安全；安装与运行入口仍等相应实现与验证。

2026-11-04 本轮检查点：原生 helper/socket 服务与桌面客户端已有生产源码，仍明确拒绝未完成的完整 Electron 启动/注入可信证明、root Core 配置验证及未知网络清理；上述“原生源码尚缺”是较早检查点，不是当前缺文件。具体剩余门为可信链、固定模板/root schema/有限 broker、准确 owner 与两族路由/DNS journal/readback/recovery。双栈已批准，参数可技术选型，不等09或IPv6批准；root schema先行，模板不在本轮文档中实现。主会话阶段State151/desktop359+17skip/typecheck绿不证明native安全或网络成功，后续native修复/build与最终证据待回填。

2026-11-04 原生切片集成：Objective-C helper、固定版本1 socket协议、audit-token/SecCode认证检查和完整可信链拒绝门已落生产源码；start仍硬拒绝，未开放root Core。build --test在普通用户隔离目录实际通过，并生成ad-hoc hardened helper及strict codesign校验。打包前只读native preflight验证固定目标祖先/root/ACL/symlink与service absence；固定--serve参数已对齐。卸载使用独立受保护恢复入口与hash绑定批准记录，测试覆盖主installer删除、部分payload缺失、State已清理、坏record拒绝、末尾仅恢复入口残留；未知文件保留。prepare20+package8+fetch3测试通过。独立review发现的参数、前置路径验证和恢复入口问题已修复并复核。

本切片不是04完成：包为fresh-only、disabled service候选，升级仍拒绝未知或已有安装；完整Electron启动/注入可信链、受限Core配置/broker、准确owner/客户端消失lease、双栈网络journal与恢复尚未实现。真实Installer/root/launchd未验证。禁用包安装后没有服务socket，App保守显示unknown并禁止普通网络写入；因此不提供给用户作为当前TUN可用验收包，也不与Backup/登录项验收混装。
