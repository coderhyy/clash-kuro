# TUN 与特权 helper

Status: needs-info

2026-11-03 建立草案，2026-11-04 记录维护者批准的首版产品行为；已接受的产品与生命周期边界以 [ADR-0014](../../docs/adr/0014-macos-tun-lifecycle.md) 为准。安装路线以 [ADR-0015](../../docs/adr/0015-macos-traditional-privileged-helper.md) 为准。任务入口见 `issues/`；正常重开策略见 [ADR-0016](../../docs/adr/0016-macos-tun-manual-start.md)，双栈固定模板见 [ADR-0017](../../docs/adr/0017-macos-tun-dual-stack.md)；具体参数可技术选定并验证，人工系统操作须等维护者明确说“开始”。

## 目标与边界

为 Clash Kuro 增加应用可控制、可观测且能够停止和恢复的 TUN 能力。首版只交付 **macOS**，Windows TUN 后续再排，不因实现可并行而纳入首版。Linux、自动更新只记录依赖。首版已选择管理员授权安装传统 LaunchDaemon + 小型 helper，不依赖付费开发者会员；SMAppService、Developer ID 和公证延期，不作为本路线前置条件。具体受保护产物身份、调用者鉴别和权限安全仍必须实现验证。

已有领域语言沿用根 `CONTEXT.md`。TUN 与现有 **System Proxy** 互斥，确认旧模式已退出后才能启用新模式。用户 Profile 原文继续只读；订阅/Override 不能绕过应用的模式互斥和恢复门禁。正常重开 App 先检查/恢复自有残留，保持 TUN 关闭并由用户手动开启；双栈固定模板与无高级参数 UI 已批准，参数依据锁定版本作技术选择，真实覆盖仍须验证。

## 已核对的事实

| 来源 | 当前行为 | 对本期的影响 |
| --- | --- | --- |
| `packages/core/src/config.ts` | Profile → Override → App-managed Fields；普通 Core 路径现已强制已有 tun.enable=false | 必须在最终配置对 `tun.enable` 执行应用准入门禁，防止订阅/覆写绕过已批准的互斥；此要求不选定其余 TUN 参数默认值 |
| `packages/core/src/index.ts` | 本轮已有 `TunStatus` / `TunPlatform`；State、桌面客户端与 UI 正在同一最小接口接线 | 源码接线与可信 native 能力分开：blocked/unknown 不得假成功，最终组合验证由主会话回填 |
| `apps/desktop/src/main/platform/index.ts` | 普通路径由 Electron 启动 Core；Runtime Config 用打包 Core 的 `-t` 校验后原子替换 | 更换 Core 启动权限时，需要保留校验失败不替换旧配置、启动就绪和准确停止的契约 |
| `resident-session.ts`、`resident-startup.ts`、ADR-0013 | Windows 当前用户 helper 持有准确 Core Job，串行 WinINet，启动先恢复旧 journal；没有管理员服务 | TUN 提权不能新增竞争的 Core owner 或绕过既有代理写入门；现有 helper 不是已批准的特权 helper |
| ADR-0001 / 0002 / 0011 | 共享包不依赖平台；控制通道为 socket/pipe；不使用 Node addon/FFI | 新权限适配留在桌面端，现有私有控制通道边界须随权限变化复核 |
| ADR-0009 / 0010、`electron-builder.yml` | 特权 helper 留到 TUN；当前 macOS arm64 为 ad-hoc 签名、未公证；本轮已有原生服务与安装准备源码，完整可信安装/运行仍未验收 | 安装、调用者鉴别、升级、卸载及签名要求需先验证，不能默认当前包已满足系统准入 |
| `apps/desktop/core.lock.json` | mihomo 固定为 v1.19.33 | 技术研究和试验绑定此版本；不能依据最新版文档静默更换 Core |

2026-11-04，02 已完成 [一手资料研究](platform-feasibility.md)：固定 mihomo v1.19.33 / sing-tun v0.4.28 已有两平台 TUN，无需为能力存在性升级 Core；Windows amd64 内置 Wintun 与官方 0.14.1 DLL 逐字节相同。macOS 原生 utun 需要 root；SMAppService LaunchDaemon 的 Apple SDK 契约要求签名/公证，当前 ad-hoc 未公证包不能算已满足该路线。Electron 45 已提供 daemonService 注册接口；Windows 路由操作需要管理员/提升，LocalSystem 服务不能自动继承当前用户 WinINet 语义。具体来源、候选、跨权限 IPC 与未实验边界见报告。本研究不批准安装方式或真实网络实验。

## 已批准的产品决定

| ID | 2026-11-04 维护者决定 | 实现必须满足 |
| --- | --- | --- |
| D1 | macOS 首版 | Windows TUN 适配保持后续待排，既有 Windows 代理恢复验收独立保留 |
| D2 | 接受管理员授权安装持久 helper，必须可卸载 | 安装与代理运行分开；退出 App 停止 TUN/Core，清理本应用拥有的网络状态；保留安装组件不等于退出后继续代理 |
| D3 | TUN / System Proxy 互斥 | 切换必须确认旧模式已退出后再启动新模式；旧模式停止失败或状态未知时不启动目标模式；订阅/Override 不得绕过门禁 |
| D4 | 异常后不自动开启 TUN | 下次 App 启动先检查并恢复本应用残留；无法确认归属、恢复或旧 writer 已退出时提示处理并拒绝继续启用 |
| D5 | 人工系统操作等待“开始” | 方案、代码、fake 测试和只读准备可继续；真实授权安装、卸载、路由/代理修改及会话实验由主会话协调，维护者明确说“开始”后才执行 |
| D6 | 传统管理员安装 LaunchDaemon + 小型 helper；不依赖付费会员 | 09 路线决定已解决，技术安全设计和实现由 04 承接；SMAppService/Developer ID/公证延期；禁止 setuid Core 和任意 root 命令/路径接口，不要求关闭 SIP 或全局 Gatekeeper |
| D7 | 正常重开也关闭 TUN，先残留检查，再手动开启 | ADR-0016 已批准；未知时提示并关门，不能从旧偏好、Backup、唤醒或 helper 重连自动开启 |
| D8 | IPv4/IPv6 双栈固定模板，无高级参数 UI，具体参数可技术选定 | ADR-0017 已批准；以固定 Core 源码及实验证据选择，不再等待 IPv6 范围批准，不实现静默关闭用户 IPv6 |

**互斥的必要推论：** 应用必须决定 Runtime Config 中 `tun.enable` 此刻是否可以生效。Profile / Override 在此字段上的值不得越过已确认模式、关闭或恢复门禁。正常重开先残留检查、保持 TUN 关闭、仅用户手动开启已由 ADR-0016 批准，不实现自动恢复上次 TUN 偏好。该互斥推论本身不选择参数；D8 已另行允许技术选型。候选、技术门和产品影响如下，不把源码支持当作真机通过。

## 固定版本事实与技术候选

本轮只读核对 mihomo **v1.19.33 / `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`** 与其锁定 sing-tun **v0.4.28 / `a128d0c3c8001e041725fa67ff3b521502298f17`**。下表是源代码事实；没有执行 root、utun、路由或 DNS 实验，候选尚未写成 Runtime Config。

| 已证实事实（固定提交） | 对模板的约束与候选 |
| --- | --- |
| [mihomo 默认 `Stack: C.TunMips`](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L545-L555)，[字符串枚举](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/constant/tun.go#L8-L48)；[sing-tun 空值/`mips` 确实调用 `NewMipstack`](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/stack.go#L41-L61) | **首个实验候选显式 `stack: mips`**，依据为锁定版默认而非性能优胜证明。`system` / `gvisor` / `mixed` 都有独立实现；mixed 的 [TCP 使用 System、UDP 送 gVisor](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/stack_mixed.go#L220-L261)，是兼容问题时的备选，不为并行同时引入多套生产模板 |
| [顶层 IPv6 默认 true，但 DNS 默认关闭且 DNS IPv6=false](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L484-L529)；[顶层 IPv6=false 或能力检查失败会移除 TUN IPv6 地址](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L1680-L1707) | 候选显式管理 `ipv6: true`、`dns.enable: true`、`dns.ipv6: true` 及双族接口地址；订阅/Override 不能清掉双栈。能力不满足或读回缺失时拒绝开启/报告原因，不能静默降成 IPv4 并报双栈成功 |
| [RawTun 的 `inet4-address` 在 YAML 结构中被注释](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L273-L288)；[实际 IPv4 从 DNS fake-ip-range 派生并强制 /30](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L1687-L1707) | 首个地址候选为源默认派生的 `198.18.0.1/30` 与 `fdfe:dcba:9876::1/126`，相应内部 DNS 为 `.2` / `::2`；不能编写无效 `inet4-address` YAML。root schema 须连带约束 `dns.fake-ip-range`，预检与已有接口/路由重叠，冲突明确拒绝，不按任意订阅地址写 root 路由 |
| [macOS 默认生成两族若干子路由而非简单 0/0](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/tun_rules.go#L104-L192)，[Darwin 将其逐项 addRoute](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/tun_darwin.go#L330-L347)；[自动出站接口监视](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/server.go#L343-L394) | 首个路由候选 `auto-route: true`、`auto-detect-interface: true`、动态 utun 名、MTU 1500；MTU 是待实验的保守工程起点。先用该版本路由计算器形成有限两族清单，不手写声称等价的全流量路由。`strict-route` 不作为 kill switch；出站绑定、LAN/分域 DNS、VPN 冲突和接口变化仍须实验读回 |
| [macOS 空 dns-mode 默认 disabled](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/tun.go#L141-L190)；[native DNS 用临时 Dynamic Store catch-all，关闭 session 移除](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/internal/systemconfiguration/dns.go#L21-L43)，[catch-all 搜索优先级](https://github.com/MetaCubeX/sing-tun/blob/a128d0c3c8001e041725fa67ff3b521502298f17/internal/systemconfiguration/dns.go#L187-L258) | DNS 首个候选 `dns-mode: native`，把系统解析交给内部双族 DNS；用源支持的 [`redir-host`](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/constant/dns.go#L39-L47) 起步，避免首版额外引入双族 fake-IP 池行为。临时 session 清理是源码机制，不替代 forced-kill/残留读回验收，也不覆盖或抹除第三方永久 DNS |
| [TUN 自动加入双族内部 DNS 地址:53](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/server.go#L277-L307)；[hijack 精确地址或通配 port53，TCP/UDP 均处理](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/listener/sing_tun/dns.go#L21-L50) | 推荐先验证仅内部 DNS 端点：显式空额外 `dns-hijack` 列表，由 Core 添加内部地址；`any:53` 可作为扩大接管的比较项，不能默默吞掉 LAN DNS。DoH/DoT 是普通加密流量，不由 port53 劫持解密；mDNS、scoped resolver、已有更具体路由/第三方 VPN 不保证覆盖 |

**DNS 上游不照抄 Core 默认。** 上述默认包含具体公共明文 bootstrap 与第三方 DoH/DoT，源码有值不构成用户隐私选择。技术建议复用 Profile 已明确提供且通过 root 有限 schema 的上游/策略，完整枚举 nameserver、bootstrap、fallback 与 proxy-server-nameserver；缺失或不被支持时拒绝 TUN 请求并报错，不偷偷换供应商。最终 resolver/传输方案及分域行为须在下面的产品影响问题明确后落成一个模板；不开放高级 UI，也不将任意 Profile DNS/路径原样交给 root。

## 剩余产品影响与具体技术门

01 仅集中两组最少产品影响，**不再询问双栈、stack 或每一个参数是否批准**：

1. **LAN / 分域 DNS 与隐私：** 建议保持本地设备、现有 scoped/split DNS 可达，不添加新的公共 DNS 供应商；上游优先使用 Profile 中明确、安全可支持的配置，缺失拒绝启用。是否接受这组边界？把任意 port53 强制送新公共 resolver 会改变局域网与第三方域名披露范围，不作为默认假设。
2. **DIRECT / 故障边界：** 建议继续遵守 Profile 的显式 DIRECT 规则；发生启动/恢复故障不自动切 DIRECT 或重开另一代理模式。但这与独立 kill switch 不同：utun/路由消失后 OS 可能恢复直连。是否接受首版没有独立断网保障的边界？不据双栈称全流量接管/防泄漏；如必须保证断网，须先另作架构决定，不静默扩张本轮实现。

04/06 当前真正的技术阻塞为：**完整 Electron 资源/启动/注入可信链；root 对固定模板及 Profile 有限数据的严格 schema 验证与有限 broker；准确 Core owner、两族路由及 DNS 归属记录、停止读回与异常恢复。** 09 路线已解决，付费会员/Developer ID/公证不重设为前置。已有安全分析与威胁边界保留在本 spec 和 [安全方案](macos-helper-security.md)，不新增分析文档。

**先验 root schema，再实现模板。** 04 先验证允许的字段、地址/路由清单、DNS/provider/bootstrap、控制 socket 和文件能力；拒绝额外 root 配置、任意路径/命令或动态扩面。通过后 06 才生成候选并经固定 Core `-t` 校验，普通路径继续强制 TUN 关闭。`-t` 不能证明网络就绪、root 安全或清理成功。上述技术工作与 UI/调用链的 fake 矩阵并行，不被两组产品影响讨论整体挂起。

IPv6 必须覆盖：两族路由、Wi-Fi/有线/VPN 等接口变化、双栈 DNS（AAAA、单族失败/回退与 bootstrap 环路）、正常停止与异常恢复、双栈绕过/泄漏测试。保留系统 IPv6；没有可用外部 IPv6 的网络需区分“本机双栈接口/路由配置正确”和“外网 IPv6 可达”，不能伪造后者通过。

## 实现契约与并行边界

三张实施主票为 04 helper、06 生命周期、08 集成验收。03/10 并入 06，11/12 并入 04；旧票保留历史证据与回链，归并不是实现完成。共享契约、调用方和 fake 矩阵是 06 票内清单，[contract.md](contract.md) 为其设计与受测证据；新公共接口由主会话统一接受。04 安装事务与认证/broker 实验可并行，生产 pin 来源依赖受保护安装记录；06 机制无关契约/测试独立，生产适配再与 04 汇合。

普通 Core 配置禁止 `tun.enable` 绕过的切片已获批并有既有测试记录；它不代表特权 TUN 已实现。所有切换都需旧模式退出和网络归属确认，未知关闭新写入；退出停止准确 Core/TUN 并清理仅自有网络。正常重开先检查/恢复残留、TUN 关闭、仅手动开启已批准。双栈固定模板已批准，不阻塞这些门禁；root schema 未通过前不实现启用模板。源码由实施 agent 交付，最终证据写主票 Comments，不提前宣称完成。

| 票 | 负责范围与当前状态 | 阻塞与并行关系 |
| --- | --- | --- |
| [01](issues/01-scope-and-lifecycle-decisions.md) | 产品决定：D1–D8 已批准；仅两组具体产品影响待确认 | 参数可技术选择；04/06 的安全与隔离验证继续 |
| [02](issues/02-platform-feasibility.md) | 一手研究 resolved，历史事实保留 | 不等于真实安装/TUN 验收 |
| [04](issues/04-macos-privileged-adapter.md) | macOS helper；内含原11安装事务、12认证/broker及网络归属清理 | 与06并行；生产 pin依赖本票安装记录，接入须获批契约/安全设计；真实操作等“开始” |
| [06](issues/06-state-and-ui.md) | TUN生命周期；内含原03共享契约/配置、10调用方与测试矩阵 | 机制无关部分独立；主会话统一公共接口，生产联调等04；模板先等root schema与具体影响边界 |
| [08](issues/08-tun-integration-acceptance.md) | 04+06集成、精确产物与最终验收 | 等04/06技术门与具体影响边界；人工操作等“开始”，无需等Windows05/07 |
| [09](issues/09-macos-installation-choice.md) | 安装路线 resolved | 不重新制造路线/付费身份阻塞 |
| [03](issues/03-shared-contract-and-config.md)、[10](issues/10-mode-transition-contract.md) | 已归并06，保留配置与既有入口测试历史 | 仅票务归并，未实现完成；后续清单/证据见06 |
| [11](issues/11-protected-install-transaction.md)、[12](issues/12-peer-authentication-and-broker.md) | 已归并04，保留目录/身份原型历史 | 仅票务归并，未实现完成；安装与认证实验仍可并行 |
| [05](issues/05-windows-privileged-owner.md) | Windows TUN 暂不实施 | 首版范围外，另行排期 |
| [07](issues/07-deferred-windows-recovery-validation.md) | 旧Windows恢复验收独立保留 | 产物/范围与“开始”限制保留，不阻塞macOS |

## Windows 已延期的验收

继承 issue 08 和远端文档提交 `022df3d`、`62505cc`：原产物 `143a97f` 已有正式 App 普通退出、托盘注销和完整关机各一例及基线恢复记录；这些样本不覆盖以下三例：

1. 真实取消关机后，存活 App 是否显示停止/需重启、代理未知且拒绝重新写入。
2. 残留 journal 的下次 App 启动恢复，包含没有 Active Profile 时也在新写入前恢复。
3. 保留 helper 的显式恢复，作为独立分支验证。

07 沿用 `FORMAL-APP-RESULTS.md` 的最小提案与原票证据，不要求重做已完成三例。父进程 EOF 后 helper 自动清理成功不等于 journal 回放通过；没有可观察残留则恢复实验不成立。仍不把登录视作自动恢复，也不因此扩大到断电、服务或完整 RAS/多系统矩阵。Windows TUN 不在首版，07 独立保留而不串行阻塞 macOS。真实操作须主会话确认精确产物/范围并等待维护者说“开始”。

## 后续能力的依赖记录

- Linux：等待维护者确定目标发行版、桌面环境、包格式和权限机制；可复用最终共享契约，当前无 Linux 实现票。
- 正式签名/公证与 SMAppService：已明确延期，不阻塞传统管理员安装路线；后续若采用，另确认开发者身份、证书/凭据和发布范围。当前路线仍须完成独立身份鉴别、受保护安装和权限校验，不能作为安全捷径。
- 自动更新：沿用 ADR-0010，依赖正式签名及 helper/Core 升级兼容与回滚策略；本轮不接入 updater。

## 本轮完成标准

04/06/08 主票具备简明负责范围、Blocked by 与验收清单；03/10/11/12 保留历史和相互链接，明确归并不是实现完成。D1–D8 与候选参数/未验证边界分开；源码/自动检查/产物和真实验收证据等待实施 agent 在主票 Comments 回填，人工系统操作仍等待“开始”。

## 2026-11-04 本轮生产接线检查点

主会话已统一 `TunStatus { availability: unsupported | not-installed | ready | blocked; state: off | on | unknown; error? }`、`snapshot.tun` 与 `setTun({enabled})` / `recoverTun({})`。桌面 macOS socket 客户端、State 生命周期和双语 UI 已进入生产源码；unsupported 隐藏、未安装不伪造安装、blocked/unknown 显示真实错误与恢复入口，ready 且状态已知才允许切换，文案声明重开手动启用，不承诺全接管。原生服务当前明确拒绝尚未完成的 attestation、root 配置及未知清理，未形成可开启 TUN 的产品。

阶段自动证据：UI/i18n/dev-bridge 25/25 与 renderer typecheck 通过；主会话随后报告 State 151 通过、desktop 359 通过/17 skip、全量 typecheck 通过。计数仅对应各自当时源码；后续 native 修复、组合 build/CI、精确产物与真实网络验收由主会话最终回填，不能把本轮文档或客户端接线标为 04/06/08 全部完成。
