# 统一 TUN 状态、配置与权限契约

Status: resolved（仅任务归并；不是实现完成）
Type: task
Blocked by: 无（本票停止独立跟踪；未完成项及技术依赖由主票承接）
Owner: [06 主票](06-state-and-ui.md) 的负责 agent；主会话协调

## 归并结果

本票已并入 [06 主票](06-state-and-ui.md)，不再独立排期或作为主票的外部阻塞。原范围、验证和未完成项保留如下作为历史；归并不是安装、认证、TUN 接入或真实验收完成。最新批准策略与执行状态以主票、spec 和 ADR-0016 为准。后续结果写回主票 Comments，等待最终源码与验证证据。

## 归并前记录（历史，未完成项已转主票）

## 负责范围

Core index/config/fake 与测试，State index/fake 公开类型/fixtures；03 实现获批契约，06 实现 store/UI，同文件由主会话分阶段分配。

## 与 10 的关系及可立即并行工作

ADR-0014/0015 和 02 已足够推进 10 的设计、调用方盘点与 fake 验证矩阵。10 是本票前置设计；主会话批准其最小契约后才开始本票源码，不能因“设计无阻塞”立即生成不确定公共 API。

- 区分 helper 已安装、TUN/Core 已运行、网络已清理与恢复未知；先不发明持久化字段/安装 API。
- 最终 Runtime Config 的 `tun.enable` 服从显式准入，Profile/Override 不得绕过互斥。无显式准入关闭是实施基线，不选其他 TUN/DNS/路由默认值。
- fake 矩阵覆盖确认旧模式退出再启目标、旧模式失败/未知则目标零启动、启动先恢复本应用残留、归属/恢复未知关门。
- 此设计可与 04 安全设计并行，无须 root 或真实网络；正式 fixtures/源码仍遵守契约批准门。

## 分阶段实现与验收标准

- 获批最小契约后，可先实现纯配置门禁/状态/fake；生产身份/路径/IPC 协议等 04 安全设计获批，参数/正常启动行为等 01。阶段完成不自动关闭整票。
- Profile → Override → App-managed Fields 的最终 enable 门禁有对抗测试，旧 settings/Backup 不意外启用，Profile 原文不变。
- 共享包无平台/DOM 依赖，复用 Platform；生产协议不接受任意 root 命令/路径接口，不采用 setuid Core；传统 LaunchDaemon + 小型 helper 路线已定，不依赖付费身份。
- 类型检查及相关 Core/State 测试通过；主会话先集成契约，再让 06 实现；04 生产适配等安全设计获批，Windows 05 不属首版。

## Comments

2026-11-04：本票不再把全部 ADR 批准作为阻塞，ADR-0014 已批准产品边界。10 设计可立即开展，源码等主会话批准；正常自动启用暂不实现。

2026-11-04 后续：主会话批准并分派最小生产切片：现有 buildRuntimeConfig 只供普通 Core 启动，合并后如存在 tun 字段，其 enable 必须为 false，订阅/Override 不能偷开；没有 tun 时不改变输出。保留其余合法 tun 字段，不选 DNS/路由默认、不新增 Settings 或可随意传 true 的公共参数。未来特权启动入口须经共享契约及权限门禁另行接入；此切片不等于已实现 TUN。其余接口不随本次部分批准自动放行。

该切片已实现：config.ts 两行变更，7项对抗用例；Core 138/138、State 125/125、桌面 Profile 调用方 7/7 通过，Core/State typecheck通过。验证包含 Profile/Override true、畸形值、删除字段、保留其他参数、原数据不变。此变更会禁用此前手写配置中未受应用授权的 TUN，必须随新包发布；现有2617cf9人工验收包不含此变更。整票仍未关闭，TUN公共接口和生产特权路径尚未实现。


2026-11-04：按维护者要求归并至 [06](06-state-and-ui.md)；本票历史证据不改写成新的通过结论。
