# TUN 接入生命周期

Status: ready-for-agent（生产客户端/State/UI已接线；完整安全适配与最终验证分阶段）
Type: task
Blocked by: 主会话统一接口已接入；受限配置及V2客户端已接；实际开启先等04可信链/有限Core控制/准确owner与恢复；01产品边界已全部解决，不再等待DNS/DIRECT/kill switch选择
Owner: TUN 接入 agent；主会话统一 Core/State/桌面公共接口与源码分工

## 负责范围

共享契约、配置准入、FakePlatform/调用方、State/UI/托盘/i18n/demo 接入同一生命周期。合并 [03 配置/契约](03-shared-contract-and-config.md) 和 [10 测试矩阵](10-mode-transition-contract.md)，[contract.md](../contract.md) 作为票内实施清单，旧票只留历史，不形成票间审批循环。与 [04 helper](04-macos-privileged-adapter.md) 的安装/认证实验并行；正式源码只采用主会话统一的最小接口。

## 实施清单与验收标准

- 共享契约：区分安装、Core、实际网络、unknown 与转换门；共享包无 OS/DOM/提权依赖，复用 Command 队列、Platform 和首次关闭截止时间，不造第二套状态机。
- 配置准入：普通 Core 最终 `tun.enable=false`，Profile/Override/Backup 不绕过应用准入；原文不变、无 tun 不新增模板。特权入口另经批准门禁，不能提供任意 true 参数或路径。保留现有配置禁用切片证据。
- 已批准启动策略：正常重开 App 也先检查/恢复自有残留，保持 TUN 关闭，用户手动开启；异常/重连/唤醒/Backup 不自动开启，未知时提示处理且阻止新模式写入。安装不等于运行，不从持久偏好/导入内容恢复 TUN。
- 转换及调用方：旧模式退出、归属/停止确认后才启目标；覆盖 Profile/Override/Settings 重载、Backup/remove、quit、native-stop、resume。迟到 Promise 不重开门；Backup 停止证据不足不提交导入，保留普通 MVP 兼容范围。
- 测试矩阵：双向互斥；停止失败/未知目标零启动；部分启动与清理失败；并发/退出/超时/迟到；无 Active Profile 恢复；正常重开关闭并需手动开启；旧 Settings/Backup；卸载前清理。fake 只证明受测门禁，不替代 08。
- 网络/界面：配合 04 覆盖IPv6 路由、网络接口变化、双栈 DNS（AAAA 与回退）、停止/异常后的恢复，以及双栈泄漏测试。双栈固定模板/无高级 UI/参数可技术选定已由 [ADR-0017](../../../docs/adr/0017-macos-tun-dual-stack.md) 批准，首个候选见spec，root schema与离线候选已通过当前隔离验证；真实开启仍等04可信链、活跃会话与网络归属/恢复汇合。LAN/split DNS保持、不新增DNS供应商、不支持DNS具体拒绝及显式DIRECT已由 [ADR-0018](../../../docs/adr/0018-macos-tun-network-boundaries.md) 批准。开启与故障状态均展示无独立kill switch、路由消失可能直连；状态、忙碌/禁用、中英文与demo一致，不声称全流量/防泄漏，不静默关闭用户IPv6。
- Core/State/桌面受影响测试、类型检查与构建通过；真实适配与产物验收交 [08](08-tun-integration-acceptance.md)，不能以 UI 可点击标记完成。

## Comments

2026-11-04：03/10 仅票务归并，未表示 TUN 已实现。历史证据包括普通配置准入 Core138/State125/桌面调用方7项及类型检查、既有生命周期定向12项；详见历史票，不跨范围宣称通过。后续源码由实施 agent 交付，最终命令与证据待回填；没有真实系统操作。

2026-11-04 后续：Backup 历史停止证据缺口已修复生产 store：importBackup 入口与 await stop 后均 requireSession()，预先异常锁/备份中异常/stop 挂起异常迟到结果三时机均拒绝目标数据替换，无重启或代理写入。主会话报告三时机回归、State 全127/127和typecheck通过，文档已核对源码检查点；不把它扩大为完整TUN网络停止证明。最终组合CI/产物证据仍待回填。

2026-11-04 本轮生产接线：主会话统一TunStatus、snapshot.tun与setTun/recoverTun，桌面macOS客户端、State和双语UI已接入。未安装不假报安装；blocked/unknown展示真实error并可请求恢复；仅ready且off/on、非忙碌才正常切换；demo不假装native可用，重开手动启用文案无全流量承诺。UI/i18n/dev-bridge25/25及renderer typecheck通过；主会话随后报告State151、desktop359通过/17skip与全量typecheck通过。后续native修复、组合build/CI与精确产物由主会话最终回填，不能以接线或阶段数关闭本票。

2026-11-04 生产接线收口：state166/166（含39项TUN矩阵）通过；UI→IPC→既有Command队列→macOS socket客户端接通。独立TUN恢复锁不清掉native restart锁；startup/no-profile先检查恢复；转换/Backup停止证据/配置重载手动重开/late-result/quit/dispose门禁已接入。resumeCore作为仅main调用的方法整段进入原队列，避免唤醒把已排队TUN切回普通Core；普通流订阅按owner暂停/恢复。平台start入口受shutdown门禁与in-flight等待控制，始终沿首次deadline，超时不报告成功。macOS clearSystemProxy新增每服务HTTP/HTTPS严格Enabled:No读回，失败阻止后续模式启动；既有全局清理范围未改变，不称已实现自有TUN网络恢复。

原生start仍拒绝，故当前没有可用双栈TUN会话。root闭合schema与离线候选已实现并通过隔离验证；native owner/lease组件测试不等于生产会话接通。剩余门为完整可信链/有限broker、活跃session与并发独立status接入、网络owner清理/恢复的生产汇合，不再把schema本身列作未实现，也不等待用户再次批准双栈。仅取消/恢复/门禁的fake矩阵通过不能关闭本票。本轮开启与故障状态常显双语无kill switch/路由消失可能直连/显式DIRECT说明，并纳入开关aria-describedby；相关UI/i18n/demo27项及renderer typecheck通过，未改启用门禁或执行真实启动。


2026-11-04 当前实现复核：生产 Profile → Override → 当前 mode 的受限 TUN 配置先准入，再停止旧模式；反向 `startCore` / `setSystemProxy` 通过 `stopTunIfNeeded(beforeStop)`，在 inspect 确认活跃后先离线验证目标普通配置，失败不调用 TUN stop/普通 start/代理 set。主会话报告 State170/170，本 agent 只读复核并重跑该两项回归通过。V2客户端完整发送重验后的config，无V1start回退；有限帧/严格UTF-8与重复键/sequence/单心跳/lease、断链unknown和停止独立status读回已实现，会话捕获竞态已修复，临时socket43/43及main typecheck通过。原生Serve仍串行并拒绝open，活跃session/并发status与可信链/broker/网络归属恢复仍未汇合；本票保持进行中，无真实系统验收授权。
