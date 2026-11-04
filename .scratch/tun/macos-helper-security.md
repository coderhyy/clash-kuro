# macOS 传统 helper：安装与权限边界

2026-11-04。依据 [ADR-0015](../../docs/adr/0015-macos-traditional-privileged-helper.md)。这是实现方案与证据；原生禁用服务切片已有源码，**不代表完整安全能力或真实安装/TUN验收通过**。路线是管理员安装小型 LaunchDaemon，不依赖付费 Developer ID/公证，不设置整个 Core setuid，不关闭 SIP/Gatekeeper。目前没有真实系统操作授权。

安装、调用者与broker由 [04](issues/04-macos-privileged-adapter.md) 跟踪，原 [11](issues/11-protected-install-transaction.md)/[12](issues/12-peer-authentication-and-broker.md) 保留历史。纯测试可并行；生产身份清单依赖受保护安装记录。配置白名单、完整客户端身份或网络归属证据未完成时，不得接受启动 TUN。

## 威胁与参考证据

同 UID 恶意进程可能修改用户数据/临时文件/用户安装 App，抢先连接 socket，传入恶意 Profile/Override，替换路径，伪造 PID/hash。UID、socket mode、同 UID 可读 secret、请求者自报 hash 均不足以授权。ad-hoc 签名与 SHA256 不证明发布者身份；初次安装仍须管理员信任精确取得的产物。本设计不抵抗已取得 root 的攻击者。

本轮经 agent-reach 的 GitHub/gh 路径只读参考固定版本，只借鉴机制，没有复制代码或审计整个第三方项目：

- Nyanpasu [control.rs](https://github.com/libnyanpasu/clash-nyanpasu/blob/a3357300ecbae4a669ca1bcdb33d35aff32c0fc6/backend/nyanpasu-core/src/service/control.rs#L123) 使用独立 service 与安装参数；[sudo.rs](https://github.com/libnyanpasu/clash-nyanpasu/blob/a3357300ecbae4a669ca1bcdb33d35aff32c0fc6/backend/nyanpasu-core/src/utils/sudo.rs#L8) 将用户临时 shell 脚本交给 osascript 管理员执行。本方案不复制这个用户可写脚本/路径边界。
- Verge Rev [安装入口](https://github.com/clash-verge-rev/clash-verge-rev/blob/14abc4c4ee82deb48e13d054a2f336c9d7888cc5/src-tauri/src/core/service.rs#L743) 委托独立 installer；[安装位置](https://github.com/clash-verge-rev/clash-verge-rev/blob/14abc4c4ee82deb48e13d054a2f336c9d7888cc5/src-tauri/src/core/service.rs#L250) 使用 LaunchDaemons/PrivilegedHelperTools；[stage_approved_core](https://github.com/clash-verge-rev/clash-verge-rev/blob/14abc4c4ee82deb48e13d054a2f336c9d7888cc5/src-tauri/src/core/service.rs#L789) 只运行管理员批准目录内 Core，并用摘要检测批准后的替换。其 IPC 依赖固定 v2.7.7；本文未将依赖内部认证视为已核验。
- 本机 SDK 的 LOCAL_PEERTOKEN、kSecGuestAttributeAudit/SecCode 可用。[普通用户 C 实验](prototypes/peer-identity/README.md) 已接受固定 ad-hoc 原生 code、拒绝同 UID 不同 code，不证明 Electron 完整身份。
- [安装原型](prototypes/helper-install/README.md) 本轮实际 **16/16** 通过；只使用临时目录、当前 UID 和标准库，无安装、服务或网络。真实 root/ACL/安装器尚未验证。

## 固定安装布局

以下路径是实现约定，生产 label 须与固定 bundle ID 统一，禁止请求者选择路径/label。

| 路径 | 所有者与权限 | 用途 |
| --- | --- | --- |
| `/Library/PrivilegedHelperTools/dev.kuro.tun/versions/<release-id>/helper` | root:wheel 0755，无 setuid/setgid | 小型原生 helper |
| 同一版本目录的 `mihomo` | root:wheel 0755，无 setuid/setgid | 精确批准的 Core |
| 同一版本目录的 `manifest.json` | root:wheel 0644 | 协议/架构/版本、可执行文件及客户端完整资源身份 |
| `/Library/LaunchDaemons/dev.kuro.tun.plist` | root:wheel 0644 | 固定绝对 ProgramArguments |
| `/Library/Application Support/Clash Kuro/Privileged` | root:wheel 0700 | 事务、会话、受控 Runtime Config/Core 工作目录 |
| `/var/run/dev.kuro.tun` | root:wheel 0755 | helper 入口；socket 连接权不等于操作授权 |
| 受保护会话目录下 Core Control Channel | 目录0700/socket0600，root:wheel | 只允许 helper broker，普通 App 不直连 |

自有祖先逐组件核对 root owner、无 group/other 写、无普通用户写 ACL、无 symlink；既有非预期对象停止，不接管。版本标识是构建端受限值，不是路径。执行不通过可变 current symlink，不用 PATH/shell，不继承请求方环境。LaunchDaemon 重启只能 idle/recovery，不能自动恢复 TUN。

客户端采用管理员安装的固定 `/Applications/Clash Kuro.app` 副本，须保护整棵 bundle：主执行、Frameworks、app.asar 及所有可加载资源。普通 DMG 拖入形成的 owner/ACL 不自动满足条件；不得为通过认证而宽泛 chmod/chown 用户目录。具体迁移及封装校验由安装事务实现并验证。

## 管理员授权、安装与失败恢复

首版选择**固定离线 `.pkg` 经 macOS Installer 的管理员授权入口**，不从 Electron 拼接 osascript/sudo 命令，不执行用户临时脚本。安装包携带固定 payload 和受限安装逻辑，操作目标写死；安装记录保存精确 pkg/payload 摘要、协议及 release。未签名 pkg 不能声称 Apple 认可或发布者已认证；先在用户态呈现独立可信渠道取得的 SHA256 和安装范围，由管理员选择该精确包。Gatekeeper/Installer 拒绝时停止，不指导全局关闭防护。

这一入口是待实现约定，不是本轮验证完成。**未签名包在用户可写位置被替换后仍弹出授权，不能由包内自校验解决**：生产必须验证系统 Installer 实际消费的稳定 package 与管理员批准字节绑定，检查暂存/资源替换窗口；无法证实时安装 fail closed，不能回退为提权执行用户可写 installer。当前不声称已解决该 bootstrap TOCTOU。

安装事务必须：

1. 无活动网络 writer 时，在受保护、随机命名、0700 的 staging 内复制固定 payload；由 root 对复制后的文件重新做逐组件 owner/ACL/权限/类型/硬链接检查，从打开 FD 读取/摘要，拒绝链接、目录逃逸、额外清单字段和重复键。manifest 的信任来自本次批准，不允许它给被篡改文件自行重新签 hash。
2. 分别 pin 解压后 Core/helper 的 SHA256、架构、版本、协议和客户端完整身份。`core.lock.json` 是压缩档摘要，**不能充当解压后 executable 摘要**。客户端自报字段只作候选，不可写允许清单。
3. 全部校验后原子发布不可变版本，写入持久事务记录和固定 plist。启动后读取实际 helper 身份、manifest/protocol 的 readiness；仅命令 exit=0 不算安装成功。最终执行只能来自已保护版本；不得检查用户路径后再按该路径重开执行。
4. 取消授权/部分复制/摘要失败：不注册，清理仅本次已记录 staging；注册/readiness 失败：停止本次已确认进程，保留错误记录、恢复旧 plist/版本。归属或停止未知时保留恢复材料、拒绝再启，不宣称回滚成功。

升级先拒绝新会话、停止旧 Core 并确认旧 writer 退出，才切换 helper/plist；旧 helper 未停不得起第二 writer。新版本失败按记录回退，旧版本仅在归属和兼容均可证明时恢复到 idle，不自动恢复 TUN。安装/升级只接受固定版本 payload，普通 RPC 无更新身份/替换 Core 能力。

卸载仍走同一明确管理员入口：停止会话、只恢复自有且当前值仍匹配的网络变更、确认子 Core/helper 已退出，再移除精确 launchd label 与 manifest 列出的固定文件。清理失败或网络归属未知须显示部分卸载，保留恢复所需 helper/记录；不执行任意 rm -rf，不删用户 Profile/Backup/其他代理组件。

## 无付费身份的运行时鉴别

helper 从 Unix 连接的内核 audit token 取得动态 SecCode，检查进程仍存活、允许登录会话、固定 ad-hoc CDHash/指定身份、受保护安装路径和完整资源 seal。允许清单由管理员安装写入，不能接受客户端 PID/hash 或仅以 same UID 放行。连接身份需绑定后续 session/lease，断连后不能凭旧 PID 恢复授权。native shim 单独 pin 也不够：同 UID 可直接运行它转发请求；不得将它做通用转发器。

**当前生产阻塞**：`electron-builder.yml` 的 hardenedRuntime=false，Electron 主执行 CDHash 不必覆盖外置 app.asar；CDHash+路径不足抵抗脚本/调试注入。需要实验证明完整受保护 bundle/资源检查、运行时有效性、无 get-task-allow、受限启动环境与可加载代码边界，以及禁用 runAsNode/NODE_OPTIONS/inspect 等入口的构建设置。ad-hoc hardening/fuses 是否足够必须对实际包做负例，不能凭选项名认定通过；DYLD/调试/same UID 可信程序恶意调用/消息转发仍需测试。失败拒绝会话，不降级为 UID 或共享 secret。C 实验仅证明系统原语。

## 有限 RPC 与 Core 配置

采用固定版本、小消息、严格字段、超时、单 owner/session、递增请求号及有界队列。只暴露 start(结构化受限配置)、stop、status 和下列 typed broker 操作；start 不接受 shell/路径/raw YAML/任意 argv。旧 session、额外字段、未知枚举、大小超限、未认证及并发 writer 均拒绝。

| 当前 App 需要 | broker 允许操作 | 约束 |
| --- | --- | --- |
| GET configs/proxies | 读取经筛选状态、Proxy Group | 返回字段受控，避免泄露秘密 |
| PATCH configs `{mode}` | setMode | 仅 rule/global/direct，拒绝额外字段 |
| PUT proxies/name `{name}` | selectProxy(group, proxy) | 长度/字符/存在性核对，正确编码，不拼路径 |
| DELETE connections | closeConnections | 不接受其他 HTTP 方法/路径 |
| traffic/logs/connections 流 | 有界订阅 | 速率、大小、断连取消、秘密脱敏 |

**禁止通用 HTTP transport 连接 root Core**，禁止 PUT /configs、provider 更新、升级、文件路径、任意 URL/HTTP 路径。Core 私有 socket 仅 root；否则绕过 start 配置验证即可让 root 读写任意路径。上述是契约草案，需要 12 的协议负例；本轮没有 broker 实现。

root Core 不接受普通 buildRuntimeConfig 产出的任意 YAML：Profile/Override 是不可信输入。`mihomo -t` 只检语法，不证明权限安全。必须针对固定 Core 版本用 default-deny schema 生成 Runtime Config，拒绝未知字段和所有未明确定义的文件/URL副作用；controller、external-ui、provider/cache、证书路径、geodata下载/更新、日志、工作目录等不能由请求者决定。需要 provider 时另做受控物化与可用范围设计，不能静默丢字段并声称兼容全部 Profile。helper 从受保护快照生成配置，只交固定 root 工作目录/文件；不在验证后重开用户路径。不以正则路径检查或 mihomo 的配置兼容性代替此门。

## 进程与网络归属

helper 只监督自己 spawn 的固定 Core，记录进程句柄/PID+启动时间及会话，不按名称 killall，不仅凭 pid 文件恢复。写入网络前持久记录计划、基线和 owner/session；记录自身 utun 的内核接口标识、每条 route/DNS 的修改前后值。停止时逐项核对当前值仍是本会话所有再恢复；第三方修改/接口复用/记录不完整时停止自动清理并报需要恢复，不能全局清空代理、路由或 DNS。

App lease 到期/断连、Core crash、取消关机后恢复、helper 重启均进入有界 stop/reconcile；证据不足保持禁用，不再启第二 writer。真实恢复依赖 [06生命周期](issues/06-state-and-ui.md)/[08验收](issues/08-tun-integration-acceptance.md)，原10已归并；临时目录测试不证明这些结果。[ADR-0016](../../docs/adr/0016-macos-tun-manual-start.md) 已批准正常重开/登录启动先恢复残留、关闭TUN且仅手动开启；[0017](../../docs/adr/0017-macos-tun-dual-stack.md) 已批准双栈固定模板/无高级UI；[0018](../../docs/adr/0018-macos-tun-network-boundaries.md) 已批准保持LAN/split DNS、不新增DNS供应商、缺失或不支持DNS具体拒绝、显式DIRECT与无kill switch。故障不自动切模式，但路由消失后OS可能直连，UI开启/故障说明不得称全流量/防泄漏。这些产品边界不再阻塞技术验证；root schema/可信链/归属清理门保持。

## 本轮通过与后续门槛

已通过：安装模型16项（包含元数据模拟）；普通用户 native peer identity 两分支。本轮没有 sudo/launchctl、挂载/安装/启动真实 App、网络或用户基线读取。

未通过/尚未执行：未签名 pkg 的精确批准与消费绑定、root/ACL/真实安装事务、完整 Electron 资源及注入负例、受限配置 schema/broker 实现、进程和网络归属/异常恢复、真机权限与卸载。它们分别阻塞对应生产入口，不阻塞04继续隔离验证，06继续调用方/门禁工作。没有把文档或原型当作生产安全完成。

## 2026-11-04 ad-hoc Electron 鉴权实验证据

实际本机构建已经验证：禁用RunAsNode/NODE_OPTIONS/Node CLI inspect、启用OnlyLoadAppFromAsar及EmbeddedAsarIntegrityValidation后，包的完整seal/fuse/签名内ASAR元数据可离线核验；生产包新增afterSign检查。packaged App也不再读取ELECTRON_RENDERER_URL来载入开发页面。这些是减少注入入口，不等于完整调用者认证。

可复现脚本为`apps/desktop/scripts/check-adhoc-library-validation.mjs`。另用普通用户临时C loader与dylib（均ad-hoc签名，loader加runtime，仅dlopen与返回42，不启动App或改网络）复现：系统拒绝加载，错误为mapping process and mapped file have different Team IDs。electron-builder对ad-hoc+hardenedRuntime也提示disable-library-validation兼容条件。因此没有把hardenedRuntime=true候选发作可用包；保留原有false，native授权门继续关闭，不通过放宽entitlement检查解决。

下一条技术候选是受保护安装、仅链接系统framework的独立native授权broker；它必须自己确认用户意图并展示有限请求，不是给任何同UID进程静默转发的shim。需要具体验证其UI意图绑定、pin、peer身份、lease归属与Electron退出联动，当前尚未实现或宣称通过。无需改变“不付费会员、不setuid Core、不关闭SIP/Gatekeeper”的产品边界。
