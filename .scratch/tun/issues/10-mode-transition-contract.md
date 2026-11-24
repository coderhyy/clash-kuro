# macOS TUN 转换与既有生命周期的 fake 验证

Status: resolved（仅任务归并；不是实现完成）
Type: task
Blocked by: 无（本票停止独立跟踪；未完成项及技术依赖由主票承接）
Owner: [06 主票](06-state-and-ui.md) 的负责 agent；主会话协调

## 归并结果

本票已并入 [06 主票](06-state-and-ui.md)，不再独立排期或作为主票的外部阻塞。原范围、验证和未完成项保留如下作为历史；归并不是安装、认证、TUN 接入或真实验收完成。最新批准策略与执行状态以主票、spec 和 ADR-0016 为准。后续结果写回主票 Comments，等待最终源码与验证证据。

## 归并前记录（历史，未完成项已转主票）

## 负责范围

采用 ADR-0014 与 `../contract.md` 的状态区分、转换顺序、调用方清单和失败矩阵。主会话已批准本轮仅在 `packages/state/src/store.test.ts` 复用现有 `setup()` / `FakePlatform`、vi 与可控 Promise，验证 Profile 重载等待/拒绝和 Backup 停止拒绝两个既有入口回归切片；追加批准复用停止等待期间异常通知/迟到 resolve 的既有测试，并记录异常锁后 Backup 停止短路的真实现状，仅编辑本测试及 contract/本票，不修改 store 实现。其余切片（包括 `apps/desktop/src/main/platform/resume.test.ts` 与 `system-proxy.test.ts`）仍是待分配建议，不在本轮写权限内；TUN 公共接口与服务实现仍未批准。

不得把旧网络模式未退出时的新启动写成“允许重叠后补救”，也不得用一个纯 fake 自创状态机通过全部用例后宣称现有 Platform 已支持 TUN。特权安装、真实网络、其他平台实现不在本票；`system-proxy.ts` 的归属语义修改须由 03/04 统一，不能作为本票的顺手重构。

## 可立即启动的验证切片

1. 从现有 `setup()` / `FakePlatform` 构造运行 Core，以可控 Promise 卡住 `stopCore`：调用 `setActiveProfile` 或 `setOverride` 后，停止未确认前 `startCore` 调用为 0；reject 后仍为 0，并保留错误。分别记录校验失败与停止失败的数据/运行状态，不能混称回滚成功。
2. 在同一 fixture 对 `importBackup` 注入停止拒绝或未知；允许 pre-import 自动备份存在，断言 Profile/Override/settings 导入目标未替换、无新 Core 启动。再覆盖 `notifyCoreStopped` 已置错误锁的分支，记录当前 stop 短路与 TUN 要求差异；测试未绿前不改变既有已发布语义。
3. 在停止或配置 Promise 挂起时注入 `notifyCoreStopped`，随后 resolve 旧 Promise；断言新 start、setSystemProxy、成功快照不会越过已关闭门。复用现有异常测试，避免新增第二套 Command 队列。
4. 使用已有 resume fixture 验证普通路径；main 现有 running 快照检查和 store restartError 已保护已观察异常，不能记为无条件自动重启。TUN 新场景重点是快照仍 running、底层 Core 已死但异常尚未上报时的唤醒重启；等 03 的真实 TUN 请求入口接入，不预设 helper 安装方式。
5. 使用 `createSystemProxy({ os: 'darwin', exec })` 的纯 mock Exec 构造第三方代理端点，记录当前 clear 行为与 TUN“仅清自有网络”的差异。此切片是约束和基线，不据此改全局清理语义或写真实代理。

## 03 集成后的转换矩阵

以最终选定的 TUN Command / fake adapter 跑 `../contract.md` 第 5 节，至少覆盖双向互斥、旧停止失败/未知、新启动部分失败、并发转换、quit 截止时间、启动残留恢复、异常后不自启和卸载前清理。安装状态与实际网络状态分别断言，不从 helper installed 或 Core running 推导 TUN 已运行/已停止。

## 验收标准

- 主会话确认契约建议与所有调用方，记录需改的真实入口以及哪些仅为 TUN 新要求。
- 第一阶段用现有入口留下可运行的顺序/失败回归或精确差异记录；对暂不存在的 TUN 入口明确等待 03，不用模拟成功替代实现。
- stop 成功、停止已失败且旧模式仍在、状态未知分别可断言；未知时新模式写入为 0，迟到成功不能覆盖异常锁。
- Backup/reload/quit/resume 经过同一门禁，文档明确其现有保证与接入后的要求；数据恢复不等于网络恢复。
- 测试仅操作内存、临时文件与 mock；没有安装服务、改变登录项/代理/路由、注销或关机。
- 实施测试后记录实际命令与结果；fake 结果不计真实权限、TUN、卸载或残留恢复验收。

## Comments

2026-11-04：完成源码调用链盘点与契约草案。当前 `contract.md` 的矩阵是待执行验证设计；本票未修改公共 API 或产品源码，也没有宣称已通过 TUN 测试。安装路线、正常启动恢复偏好和 DNS/路由参数未决不妨碍第一阶段既有门禁验证，但新 TUN 公共类型及模式切换实现仍依赖 03 集成。


### 2026-11-04 — 第一阶段两个已批准切片完成

- 主会话已批准仅验证重载停止拒绝与 Backup 停止拒绝；本轮仅修改 `packages/state/src/store.test.ts`，未修改 store 或其他产品实现。
- 新增 `Profile reload waits for Platform stop and never restarts Core after stop is rejected`：复用 `setup()` / `FakePlatform`，用可控 Promise 卡住 `stopCore`；停止挂起时 `startCore` 为 0，拒绝后仍为 0，Command 返回可见的 `cleanup state unknown` 错误。保留旧 Core 运行事实，不宣称已清理网络。
- 复用并加强既有 `import does not stop Core or replace data if System Proxy cannot be cleared`，避免重复测试：导入目标改为另一 Profile、不同 Override 与 mixed-port；FakePlatform 的 `stopCore` 因清理失败 reject 后，原有 Profile/Override/settings 逐文件保持不变，新增文件仅为 pre-import 备份，`startCore` 为 0。
- 实际验证（项目 Bun 1.4.4）：`bun x vitest run --root packages/state packages/state/src/store.test.ts -t 'Profile reload waits|import does not stop Core or replace data'` 为 2/2 通过（其他 71 项因过滤跳过）；`bun run --cwd packages/state typecheck` 通过。
- 这两个结果证明既有入口的受测顺序与失败保留行为，不代表 TUN 双向互斥、异常锁下 Backup、真实网络读回、安装或残留恢复已实现/验收；本票其余切片与 03 依赖保留。没有系统操作或真实 TUN API 测试。

### 2026-11-04 — 主会话复审后的直接停止失败覆盖

- 主会话已审阅两项回归切片；本轮将既有 Backup 用例参数化为 `clearSystemProxy` 与 `stopCore` 两种直接拒绝，保留代理清理失败覆盖并补齐 Platform 停止直接拒绝。两种失败均断言原 Profile/Override/settings 文件未替换、仅增加 pre-import 备份、`startCore` 调用为 0，且拒绝原因可见。
- 最终定向验证（项目 Bun 1.4.4）：`bun x vitest run --root packages/state packages/state/src/store.test.ts -t 'Profile reload waits|import does not stop Core or replace data'` 为 **3/3 通过**（其余 71 项按过滤跳过，文件共 74 项）；`bun run --cwd packages/state typecheck` 通过。此结果补充上轮 2/2 结果。
- 本轮源码编辑仅限 `packages/state/src/store.test.ts`，并同步本票批准范围与记录；未修改 store、公共接口或其他票据，未操作 Git 或系统状态。其余建议切片及 TUN 新 API/服务实现仍未批准，fake 验证不构成真实 TUN/权限/卸载验收。

### 2026-11-04 — 异常通知、迟到停止与 Backup 现状验证

- 先检索既有测试，确认 `late %s completion cannot overwrite native-stop state or reopen Core/proxy` 已覆盖 `clear` / `stop` 停止等待中的通知与迟到 resolve：新 Core/代理写入为 0，Command 返回异常锁错误，快照保持不变。本轮运行原测试，不新增等价用例；已观察异常后的 resume-style Command 保护也复用现有测试。
- 新增 `current Backup import after native stop replaces files but preserves the session lock without Core/proxy operations`：模拟 Core 已退出并通知 store，之后导入仍成功替换 Profile/Override/settings 并创建 pre-import Backup；stop/start/set/clear 均未调用，原代理对象仍在，快照继续标记停止、必须重启与代理 unknown。名称中的 current 明确表示已发布路径现状，不把文件仍可替换固定为未来不可改的不变量。
- 源码原因：`store.ts` 的 `stop()` 在 restartError 非空时提前返回，`importBackup` 继续执行 `writeBackupFiles`。这记录 MVP 兼容行为与 TUN 新要求的差异；没有据此宣称迟到停止门禁存在 bug。TUN 接入前必须补 **stop-proof gate**，异常锁下的短路不能代替自有网络已清理的证据；未知时可保留 pre-import Backup，但不得提交导入目标。最小修复方向由 03/10 在现有 stop/导入提交点补停止证据门禁，不扩全局生命周期或本轮公共接口。
- `contract.md` 已引用 accepted ADR-0015：管理员安装传统 LaunchDaemon 路线已选；具体特权协议、身份校验/卸载实现及 03 公共类型依赖保留。
- 实际验证（Bun 1.4.4）：`bun x vitest run --root packages/state packages/state/src/store.test.ts -t 'Profile reload waits|import does not stop Core or replace data|late .* completion cannot overwrite|current Backup import after native stop|restart requirement survives'` 为 **12/12 通过**（其余 63 项按过滤跳过，文件共 75 项）；`bun run --cwd packages/state typecheck` 通过。
- 本轮仅修改 store.test.ts、contract.md 与本票；无产品源码、Git、公共 API 或系统状态修改。结果不构成 TUN/安装/网络/卸载人工验收。


2026-11-04：按维护者要求归并至 [06](06-state-and-ui.md)；本票历史证据不改写成新的通过结论。
