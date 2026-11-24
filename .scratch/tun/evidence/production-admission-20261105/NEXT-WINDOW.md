# eb4 正常启停窗口（准备完成不等于执行授权）

仅此候选的正常路径，预计25–40分钟，不含未知故障处理。当前 App 未运行，[独立离线包审查](offline-package-eb4/RESULT.md)已通过；须用户批准本窗口后才执行。本文不启动或安装任何产物。

- 源码：`eb4beec05283c60dd99715bf2b702a58c0fb9d44`。
- 包：`/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-eb4beec05283.pkg`。
- 包 SHA256：`78cc71471ca1674e19caf4630798878330b452fb5b6ef2894fbdbda0fbc717d7`；身份/构建记录：[freeze-eb4.json](freeze-eb4.json)、[candidate-eb4.json](candidate-eb4.json)。
- [CI 42057942407](https://github.com/coderhyy/clash-kuro/actions/runs/42057942407) 双平台成功；标准原生测试含固定 Core 实际 `-t`，7条生产准入组合链通过。它们不等于 Electron/root/TUN 真机通过。
- Profile：[profile-router.yaml](../first-tun-preflight-20261105/profile-router.yaml)，SHA256 `8e219e0a9098cbe6c617862e07e19951a225aaf606478ff46b6b3f167874b00a`；显式 `MATCH,DIRECT`，不使用私人订阅，不新增 DNS 供应商。

包 metadata 的 `disabled=true` / `serviceAutoStart=false` 指安装时不自动启动服务；finite `startAvailable=true` / `productionActivation=true` 指具备有限会话能力。源码链审查未发现新增无条件拒绝，实际启动仍必须通过身份、鉴权恢复、配置及网络基线读回，不以 metadata 代替运行证据。

## 一次窗口的顺序与通过条件

1. **核验与 fresh 前置**：确认独立包审查结论、包摘要、准确安装路径/job/receipt/事务无冲突。由用户自行关闭冲突第三方隧道，agent 不代改其配置。新建0700证据目录、0600文件，保存当前接口、双族路由、完整 scoped DNS、系统代理和安装身份基线；与 router Profile 的 DNS 和准入边界一致才继续。特别核对 `192.168.0.1` 的物理接口 host/LAN 路由更具体、优先于 TUN `/1`，开启后仍经物理接口可达且不回入隧道循环；无法证明则不开启。任何基线变化先停下重新核对，不静默改 Profile。
2. **fresh 安装与实际 App 恢复**：用户处理管理员授权；核验受保护 App/helper/Core/manifest/inventory/receipt 的实际身份，按固定服务流程加载有限 helper。从 `/Library/Application Support/Clash Kuro/Client/Clash Kuro.app` 启动实际 App，确认初始状态，执行已鉴权的“检查并恢复 TUN”，独立读回 `ready/off`。`blocked/off` 不作为 ready；auth-only、拒绝或恢复失败即停止。此前不启动 Core/TUN。
3. **Profile 与开启**：重新确认基线一致后才导入上述精确 router Profile；保持 System Proxy 关闭，不改普通用户私人 Profile。点击一次 TUN，保存实际 root Core 的路径/hash/pid/start/会话归属、utun、本地双栈地址、自有路由和临时 DNS 读回；不得只凭 UI 显示 on 判通过。
4. **正常流量证据**：在已批准的有限测试请求期间，记录实际 Core 流量/连接读回与对应 utun/路由证据，确认正常流量经过本会话。保留 LAN/scoped DNS 行为及代理基线；显式 DIRECT 仅验证本路径，不声称代理出站转发已通过。当前外网 IPv6 未验，本地双栈证据不能替代它。
5. **正常关闭**：在同一 App 点击关闭 TUN。核对准确 Core 退出、自有 utun/路由/临时 DNS 清退、原网络与代理基线保持、owner/work 清退和受保护停止证明；独立状态读回一致才通过，不以单个 off 或客户端超时推断完成。
6. **Quit 与准确卸载**：仅在正常停止及证明核验通过后 Quit，确认 App 进程退出，再按固定流程退役准确 job、执行受保护卸载器及精确 receipt 收尾。逐项核对 job/进程/socket/App/helper/安装记录；保留候选用户数据、受限原始日志和 `TunDiagnostics`，不递归删除未知对象。此处 TUN 已 off，不作为 TUN-on App 退出验收。

## 停止、恢复与保留

开启 TUN 会改变本次拥有的系统路由和临时 DNS，可能影响其他系统流量、DNS解析并造成短暂断网。没有独立 kill switch；隧道路由消失后系统可能直连，不承诺故障期间阻断全部流量。

身份/摘要/基线不符、第三方冲突、授权拒绝、配置/网络读回失败、未知归属、停止超时或停止证明失败均停止后续启动和卸载。先在原 App/原持有 worker 执行关闭或显式恢复；即使诊断保存失败也须独立核对网络恢复。客户端超时不等于 Core 或网络已清理。

Core 已退出但清理失败时保留原 helper 和会话，不先 bootout 丢失持有证据。跨 helper 恢复仍限当前安装、准确 Core/helper 缺席、工作目录/cache 与实际网络后端检查；不凭旧 PID/空组伪造 childReaped，不向旧 PID 发信号。只有原值/归属仍匹配的对象才按现有恢复逻辑处理，不 flush 全局网络或修改第三方配置。

若归属、网络、停止证明或卸载资格无法确定，保留受保护安装、owner/work/cache、诊断和原始退出状态，报告具体残留；不因 off 自动扩大删除。不得把本正常窗口承诺为所有故障可自动卸载。

本窗口排除故意 helper kill、TUN-on App 退出、实际 upgrade、外网 IPv6 及 Linux/正式签名/自动更新。先前 root697 无网络实验和49未启动失败保留历史证据，不重复作为本窗口步骤。应保存各阶段命令/退出码、App/helper/Core/配置身份、UI状态、流量/utun/网络前后读回、停止证明及卸载结果；不上传含密钥或私人 Profile 的文件。
