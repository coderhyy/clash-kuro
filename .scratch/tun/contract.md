# macOS TUN 转换契约草案

Status: proposed（06 票内契约/调用方/测试清单；整合票据不代表实现完成）
依据：ADR-0014 与 [ADR-0015：传统特权 helper](../../docs/adr/0015-macos-traditional-privileged-helper.md)；源码基线 `2617cf9`。macOS 安装路线已选择管理员安装的传统 LaunchDaemon；正常重开策略已由 [ADR-0016](../../docs/adr/0016-macos-tun-manual-start.md) 批准：先检查/恢复自有残留，TUN 保持关闭，仅手动开启；双栈固定模板、无高级 UI 和技术参数选定权限已由 [ADR-0017](../../docs/adr/0017-macos-tun-dual-stack.md) 批准，具体候选与证据见 [spec](spec.md#固定版本事实与技术候选)，不是实测通过。安装技术约束见 `platform-feasibility.md`。

## 1. 范围与 seam

首版平台是 macOS。已批准持久安装、可卸载的特权 helper；退出 App 必须停止 TUN/Core 并清理本应用创建的网络状态。TUN 与 System Proxy 互斥，旧模式退出经确认后才可启用新模式。异常后不自动重启 TUN；下次启动先检查并恢复本应用残留，无法确认则提示并阻止新的网络写入。真实安装、网络或会话试验等待维护者说“开始”。

沿用 `Platform` 注入 seam：共享包不读取 OS 状态、不执行特权命令；桌面 adapter 把权限、进程和实际网络证据合成结果。现有 `stopCore()` 已承诺清理 System Proxy 与准确停止 Core，不能另让 UI 调一个“关 TUN”再直接杀 Core。安装控制与运行转换是不同职责，安装成功不能被用作运行成功。

这里的“网络模式”只表示本应用当前拥有的接管方式，避免与既有 `Mode = rule | global | direct` 混淆。`none` 允许普通 Core 仍运行，也不声称第三方代理或路由不存在。外部设置不能被当成本应用残留删除；发生归属冲突时报告冲突，交主会话明确处理路径，不能通过清空全局设置完成切换。

## 2. 三类状态分别观察

本轮主会话已统一并接入下列最小公共接口，不再以本草案旧建议另造一套网络状态机：

```ts
interface TunStatus {
  availability: 'unsupported' | 'not-installed' | 'ready' | 'blocked'
  state: 'off' | 'on' | 'unknown'
  error?: string
}
// StateSnapshot.tun: TunStatus
// Commands: setTun({ enabled: boolean }), recoverTun({})
// TunPlatform: inspect(), recover(), start(), stop() -> Promise<TunStatus>
```

- `availability` 是能力/安装/门禁观察，`state` 是实际运行证据；`ready` 不等于 on，`blocked/off` 与 `blocked/unknown` 都有意义。`not-installed` 不能替代所有权与残留恢复证明，安装状态查询失败不能伪装成 off。
- `state: unknown` 不暗示实际已关闭；error 保留原因。忙碌沿用现有 Command 状态，关闭/异常门继续由 State 和 Platform 实施，不因为 UI 禁用或迟到 Promise 就认为 native writer 已停止。
- Core 继续用 `StateSnapshot.core`，进程停止不证明路由/DNS 已清理；TUN 与本应用 System Proxy 同时观察到生效时不得发布成功。
- 不持久化运行观察/安装事实；旧 Settings、Profile、Override、Backup 不宣告安装或运行成功，不恢复启用偏好。正常重开与登录启动先残留检查，保持 TUN 关闭，仅用户手动开启。
- UI 的可用条件为 ready 且 off/on；unsupported 隐藏或明确不支持，未安装不提供假安装成功，blocked/unknown 显示真实错误并提供恢复请求。双语提示重开需手动启用，不声称全流量/防泄漏。

## 3. 最小运行操作契约

先复用现有方法的含义，06 只为无法表达的 TUN 证据和请求选择最小新增接口；不要分别新增 UI、托盘、恢复、退出各自的模式切换器。

| 逻辑职责 | 现有入口与必须满足的含义 |
| --- | --- |
| 观察 | `getSystemProxy()` 的 `null` 只表示成功查询且无相应代理；throw 代表未知，不能 `.catch(() => null)` 后据此开启 TUN。TUN 的观察/归属证据由 06 定义并由 adapter 返回，不由共享包猜测 |
| 校验候选 Runtime Config | `buildRuntimeConfig`、`applyRuntimeConfig` 继续先校验再原子替换；Profile 原文保持只读。拒绝在普通 Core 路径中让 Profile/Override 暗中启用 TUN |
| 停止已拥有的运行 | `stopCore()` 成功需清理该运行拥有的网络并确认准确 Core 不再运行；失败或无法确认必须 reject。所有调用方应区分“已停止”与“尝试停止” |
| 请求转换 | 复用 Command 队列与 Platform 写入门，在一个操作内完成检查、旧模式退出、确认、新模式启动与读回。TUN 请求使用主会话已统一的 `setTun` / `recoverTun`，现有 `setSystemProxy(true)` 也必须经过同一互斥门禁 |
| 异常/关闭 | 既有 `notifyCoreStopped`、Platform `shutdown` 的关闭锁必须同步关门，不等普通队列排到该通知。原生/特权 writer 也须关门，忽略 JS 迟到结果不能替代停止实际 writer |
| 启动恢复 | 在自动 Core 启动、scheduler、resume 重启和任何网络写入入口之前执行；无 Active Profile 也要检查残留。只有有归属的恢复操作能在门禁关闭时执行，恢复成功后仍不自动重启异常前 TUN |

`stopCore()` 的 fulfilled Promise 是成功证据契约，不需要再加一个永远为真的 `ok` 包装。TUN adapter 若返回结构化报告，必须先验证报告完整性和归属，再转换成 fulfilled / rejected Promise；网络仍未知时不能仅因进程退出而 fulfil。

### 退出确认与转换顺序

1. 读取当前实际状态、归属与可用性；拿到操作门，排除并发转换。未知或存在未解决的旧 writer 时，只允许观察、已拥有运行的清理与恢复。
2. 检查目标的必要条件，能在不改变网络的情况下做的授权/配置校验先做。拒绝授权或配置错误不得先拆掉可用旧模式；若授权自身安装了 helper，安装状态可变化，但不能据此发布网络转换成功。
3. 退出旧网络模式，等待归属清理读回和会影响新 owner 的旧 writer 停止。切换涉及 Core owner/权限变化时必须确认旧 Core 退出；不允许两个 Core owner 竞跑。若同一 owner 可安全关闭 TUN 并保留普通 Core，应由 06/04 证明，不在本草案先定。
4. 旧模式退出没有确认，就不发出任何新模式网络写入。旧退出失败且 readback 证明仍是旧模式时，报告旧实际模式与错误；无法证明则 `unknown`，关闭新写入门。
5. 旧模式确认退出后才启动目标并读回。目标成功需证明实际接管和归属；Core Control Channel 成功、配置含 TUN 或 helper 回应安装成功都不充分。
6. 目标启动失败时，清理其已知副作用：可确认无遗留则发布 `known/none` 与失败；否则发布 `unknown/blocked`。不自动恢复失败前的 TUN，不把失败伪装成切换成功。
7. 异常、关闭或恢复一旦关闭操作门，迟到的校验、旧退出、目标启动回调不能再发布成功或继续写入。重复关闭共享首次截止时间，不续期；数值预算由 adapter 选型与验证明确，不能静默延长既有 Windows 预算。

`system-proxy -> none` 可复用既有 clear，不强迫普通 Core 退出；`tun -> none` 的 Core 保留策略尚未决定。可以在 fake 中先验证完整 `stopCore()` 路径的保守顺序，但不能据此宣告用户关闭 TUN 必须停止普通 Core。

### 启动、安装与卸载

- 启动门默认关闭，先观察/恢复旧所有权。确认无本应用残留后，才把网络状态发布为已知并允许后续明确请求；正常重开 App 保持 TUN 关闭，恢复完成后仍仅接受用户手动开启。异常后的冷启动恢复只清残留，不隐式重新启用 TUN。
- 安装、取消授权、审批未完成分别更新安装状态；不得顺带启动 TUN。卸载前需确认本应用网络清理和 Core/writer 停止，确认后移除安装组件并读回安装状态。
- 清理未知时不能把“卸载成功”作为断言无残留的手段；保留已存在的恢复能力及错误信息。卸载失败不得显示 `not-installed`。具体文件、签名、卸载命令与永久组件实现留给所选机制。
- 安装路线依 ADR-0015 使用管理员安装的传统 LaunchDaemon；具体 plist、KeepAlive、服务重启或自动启动策略仍须机制票明确。helper 持久安装不允许它因客户端异常、重连或 OS 拉起而自动重新开启 TUN。

## 4. 现有调用方必须接入的位置

这是按 ADR-0014 接入 TUN 时的改动清单；其中现有行为不因此被追认为已证实的 MVP bug。

| 文件 / 入口 | 现有行为 | TUN 接入要求 |
| --- | --- | --- |
| `packages/core/src/index.ts` / `Platform` | 原基线无 TUN；本轮已接入 TunStatus/TunPlatform；`stopCore` 要求代理清理和准确停止 | 06 固定上述证据语义；仅补无法用现有方法表达的请求/观察类型，保持平台无关 |
| `packages/core/src/config.ts` / `buildRuntimeConfig` | 原基线透传；已批准的普通配置切片现强制已有 tun.enable=false | 普通路径不能越过关闭/互斥门启用 TUN；06 明确应用管理字段及候选配置生成，不预先决定 DNS/路由参数 |
| `apps/desktop/src/main/app/profiles.ts` / `buildRuntimeConfig` | 把 Profile、Settings、Override 送进 Core 合成器 | 传递 06 最终选定的运行目标，原文保持只读；所有来源均走同一合成器 |
| `packages/state/src/store.ts` / hydrate 与 `getSystemProxy().catch(() => null)` | 探测失败不阻止 MVP 启动，错误被视为没有当前代理 | 可以显示 App，但 TUN 的启动恢复/互斥门不能按“已关闭”处理；无 Active Profile 也保留未知提示 |
| 同文件 / `setSystemProxy` | 独立开关，失败常显示 `manualRequired` | 开启须先通过 TUN 退出确认；部分写入未知与已知权限拒绝区分，未知时不建议用户继续手动叠加另一模式 |
| 同文件 / `stop`、`start`、`startCore` | 原基线 stop 的错误锁短路仍需区分；importBackup 现已在入口及 await stop 后 requireSession；startCore 按 Core 存活判断 | 给 Backup/转换使用的停止不能因错误锁就假定已清理；异常门关闭后 start/late success 不得重开 TUN；布尔 Core 存活不足以判断网络 |
| 同文件 / `reloadIfRunning` | stop/start 后按旧快照恢复 System Proxy | TUN 活跃时不能先走普通启动再恢复旧代理；需在同一转换门内保留经确认的运行目标。失败/异常不自动恢复 TUN |
| 同文件 / `updateProfile`、`setActiveProfile`、`updateSettings`、`setOverride` | 经 prepare/persist/reload 变更运行配置 | 校验失败不动旧运行；重载必须经过旧退出确认，取消/异常需阻止后续 restart；保存配置与实际激活失败分别报告 |
| 同文件 / `removeProfile`、`importBackup` | 移除 Active Profile 或写入前调用 stop；写入失败恢复数据 | 网络停止未知时不删除当前 Profile 或写入导入文件；允许已有 pre-import Backup 存在。数据回滚成功不表示网络清理成功，不触发 TUN 自启 |
| 同文件 / `notifyCoreStopped`、streams | 异常锁与 System Proxy unknown，关闭 stream | 推送 TUN/网络未知并拒绝迟到操作，保留准确的 Core 停止证据；不能把 Core stopped 当成网络 none |
| `apps/desktop/src/main/platform/index.ts` / `startCore`、`stopCore`、`applyRuntimeConfig`、`shutdown` | 普通 child 或 Windows resident，各自串行；退出绕过普通 Command 队列 | macOS 新 owner 在桌面 adapter 接入；单一所有权、共享关闭门/截止时间、无竞争 Core；TUN 网络清理结果纳入 stop 成功条件 |
| `apps/desktop/src/main/platform/system-proxy.ts` / macOS `clearSystemProxy` | 当前对所有枚举服务的 HTTP/HTTPS 直接 off；stale cleanup 仅按端点匹配 | 不能把该行为当成 ADR-0014“仅清自有网络”的证明；06/04 必须定义归属记录与冲突处理后再修改，当前不直接全局重构 |
| `apps/desktop/src/main/index.ts` / main、退出、backup IPC | 启动会自动 run(startCore)；退出调用 Platform.shutdown；备份导入后 relaunch | 启动恢复先于所有自动启动；quit 不被普通队列阻塞且关闭新写入；relaunch 不从 Backup 或旧配置隐式恢复异常前 TUN |
| 同文件 / resume 与 `platform/resume.ts` | main 仅在快照 Core 为 running 时响应；startCore 经 store 错误门。若异常尚未观察、快照仍 running 而进程已死，handler 可请求重启并 finally 重设代理 | 保留现有普通路径保护；新 TUN 必须覆盖该未观察异常分支，不能借唤醒自动恢复 TUN。已观察异常的 restartError 已会拦截，不能描述为当前所有异常都会自动重启 |
| `packages/state/src/index.ts`、`fake.ts`、`core/fake.ts`、`tray.ts` | 现有状态、fake、托盘只认识 Core/代理 | 06 集成最小观察语义；06 展示实际/未知/转换忙碌，互斥与拒绝必须在 Command/Platform 实施，禁用 UI 不构成保证 |
| renderer `app.tsx`、`dev-bridge.ts`、共享 i18n | 本轮 TUN 状态/开关/恢复与双语文案已接线，demo 不伪造 native 成功 | 使用同一状态与 Command，不另实现网络切换；安装完成与网络开启分别展示，中英文同步 |
| `packages/state/src/backup.ts` / `parseBackup` | 验证已有 Settings 与 Override，不含运行状态 | 06 决定的配置字段有兼容验证；安装事实、实际网络与恢复门不从 Backup 导入；不先定新字段默认值 |

`api` 的 Mode/节点选择接口、传输封装无需新增 TUN 安装职责。受未知门影响的网络写入（如 `setMode`、`selectProxy`）也应明确拒绝；单纯查询、导出 Backup、语言与窗口操作仍可用。`setLaunchAtLogin` 是独立系统能力，不借 TUN 门处理其偏好。

## 5. 可自动验证的失败矩阵

以下是场景与断言，不代表已执行或已通过。复用 `FakePlatform`、store 的 Command 队列、已有 mock Exec 与可控 Promise；不要为了测试另写一套会自行成功的状态机。

| 场景 | 必须观察到的结果 |
| --- | --- |
| helper ready、未启用 TUN | 安装 ready 与网络 none 可同时成立；UI 不显示正在代理 |
| helper 缺失但有残留证据 | 不发布网络 none，不因缺失安装跳过恢复；阻止新写入 |
| 开启前授权取消/审批中/候选配置错误 | 旧模式未被停止，无 TUN/代理网络写入；安装状态与网络状态分别可见 |
| System Proxy -> TUN 正常转换 | 事件顺序：检查/校验 → 旧 clear → 旧退出确认 → 新 start → 新读回；任何前缀均无两种模式同时拥有网络 |
| TUN -> System Proxy 正常转换 | TUN 清理及 owner 退出条件满足后才调用代理 set；不能仅根据 Core 控制通道不通推断退出 |
| 旧停止 reject，但读回仍是旧模式 | 返回失败并显示旧实际模式；新 start/set 调用数为 0 |
| 旧停止/查询 timeout 或归属冲突 | unknown/blocked；新 start/set 为 0；不清理他人状态 |
| 目标启动部分失败、其清理成功 | 返回失败，观察 known/none；不自动重启旧 TUN |
| 目标启动失败且清理不明 | unknown/blocked；后续启用、重载、resume 写入均拒绝 |
| 两次并发转换与 ordinary Command | 复用同一队列，前一退出未确认时后一不得写入；状态通知不被队列延后 |
| 停止等待时 quit/异常到达，旧 Promise 迟到 resolve | 立即关闭新写入门；迟到 start 不执行，迟到成功不覆盖 closing/blocked |
| quit 重复触发或网络步骤卡住 | 复用首次截止时间；主进程不会因普通命令队列卡死而完全不启动关闭；timeout 不报告成功 |
| Core 确认已死、网络读回失败 | Core 可显示 stopped，但网络 unknown；自动启动保持被阻止 |
| 配置校验失败 vs 重载停止失败 | 前者保留旧运行；后者不启动新 Core、不恢复代理/TUN；已保存的数据事实不被描述成实际运行成功 |
| importBackup 时停止未知 | pre-import 文件可以存在，但导入文件未替换、无 relaunch、无自动开启；网络锁不被数据回滚解除 |
| 无 Active Profile 冷启动、残留恢复失败 | 仍执行检查，App 显示错误并保持写入门关闭 |
| 异常后重连/唤醒/helper 被系统拉起 | 可以观察和清理，TUN start 次数保持 0，直到新的明确请求且恢复已确认 |
| 残留恢复成功 | 网络 known/none，不自动恢复异常前 TUN；正常重开也保持关闭，仅手动开启 |
| uninstall 时网络未知、卸载执行失败 | 不先删掉恢复能力，不显示安装 absent；错误与网络未知保留 |
| 不含新字段的旧 Settings/Backup | 仍能读取；不从旧文件推断安装状态或实际 TUN，也不绕过启动恢复 |

最小第一步不需要服务实现：在现有 store fixture 上把 `stopCore` 的 Promise 延迟/拒绝，验证 `setActiveProfile` / `setOverride` / `importBackup` 不越过 stop 继续 start/导入；在 `createSystemProxy({ os: 'darwin', exec })` 的 mock Exec 下记录当前第三方端点 clear 行为，作为“未满足 TUN 所有权要求”的基线而不是先修改 MVP。再以现有 `notifyCoreStopped`、resume fixture 注入已观察异常与迟到 resolve，定位现有门禁保证；另测快照仍 running 而底层 Core 已死的未观察异常，不把两个分支混为一谈。06 确认本文件后，才把尚无真实入口的 TUN 双向转换矩阵接入最终 fake adapter。

### 既有入口的实测边界（非 TUN 验收）

- 现有 `late %s completion cannot overwrite native-stop state or reopen Core/proxy` 已包含 `clear` / `stop`：重载在停止 Promise 等待时收到 `notifyCoreStopped`，迟到 resolve 后 `requireSession` 拒绝继续，`startCore` / `setSystemProxy` 为 0，异常快照不被覆盖；复用该测试，不新增等价场景。
- **历史缺口（2026-11-04，修复前）：** `importBackup` 在已观察的异常锁后具有不同现状：`stop()` 在 `restartError !== null` 时直接返回，因此仍保存 pre-import Backup 并替换导入文件；不会调用 stop/start/clear/set，Core 停止与代理 unknown 的快照保持不变。`current Backup import after native stop ...` 曾记录该基线行为；后续已由拒绝导入的回归替换，不能把旧结果当当前产品保证。
- **生产修复（2026-11-04，后续）：** importBackup 在入口及 `await stop()` 后增加 `requireSession()`；异常锁预先存在、备份过程中异常、停止挂起时异常且迟到 resolve 三种时机均拒绝导入目标替换，无新 Core/代理写入。网络未知时可能保留 pre-import Backup，但不提交目标。此修复关闭已观察异常锁缺口；完整 TUN 仍需 04 提供自有网络与准确 owner 的停止证据，不能从该检查推导真实清理成功。

历史实测（2026-11-04，Bun 1.4.4）：修复前既有迟到结果矩阵、异常锁命令保护、current Backup 现状回归及首轮停止拒绝回归共 **12 项通过**，其余 63 项按过滤跳过；State typecheck 通过。

后续修复证据（2026-11-04，主会话提供并已核对源码检查点）：三时机拒绝写入回归通过，State 全量 **127/127** 与 typecheck 通过。以上均非真实 TUN/安装/网络恢复验收；最终集成产物证据仍由主会话回填。

## 6. 交付门与未决项

- 本清单属于 [06](issues/06-state-and-ui.md)，原 [03](issues/03-shared-contract-and-config.md)/[10](issues/10-mode-transition-contract.md) 保留历史，不再独立阻塞；现有调用链的 fake 回归设计不依赖安装路线或 DNS/路由值。
- 实现真实 TUN 请求、安装控制或扩公共接口前，主会话先集成 06 的最小类型与配置归属规则。普通重载中显式请求仍活跃 TUN如何维持、关闭 TUN 后保留普通 Core与否，随该契约评审，不隐式扩大本轮行为。
- 管理员安装传统 LaunchDaemon 路线已由 ADR-0015 选定；具体安装/授权 API、helper caller 与产物鉴别、升级/卸载细节仍由 macOS 机制票明确，不阻塞已有 Command 顺序测试。
- 正常重开关闭/先残留检查/仅手动开启，以及双栈固定模板/无高级 UI/参数可技术选定均已批准。mips、双族 auto-route 与 native DNS 等首个候选见 spec；它们未通过网络实验，不能写成已验证默认。当前待决只剩 LAN/分域 DNS 与上游隐私、DIRECT/无独立 kill switch 的具体产品影响。
- 所有自动结果只证明受测的 fake 顺序与门禁，真实网络残留恢复、授权拒绝和卸载完成需要独立产物与人工验收证据。

## 7. IPv6 与模板验证清单（06/04/08 内，不新票）

IPv6 路由、接口变化、双栈 DNS（AAAA、单族失败/回退与 bootstrap 环路）、停止/异常恢复及双栈绕过/泄漏测试须有具体设计、隔离验证与精确产物结果。双栈固定模板已批准，技术参数不再逐项等用户选择；但 root schema 尚未通过前不实现可启用模板，随后固定 Core 校验与网络读回分别取证。不得静默关闭用户 IPv6；无法验证外网 IPv6 的场景明确记录，不能声称全流量/防泄漏。最终证据回填 06/04/08 Comments，历史 fake 通过计数保持原范围。

2026-11-04 后续接线证据：本轮生产 macOS 客户端、State 与 UI 使用第2节接口；UI相关25项及renderer typecheck通过，主会话报告State151通过、desktop359通过/17skip、全量typecheck通过。原生start仍拒绝未完成的root验证与完整调用方证明，组合native修复/build/CI/产物与真机结果待主会话最终回填。
