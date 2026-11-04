# 开机自启 macOS 真机验证

Status: ready-for-human
Type: task
Blocked by: 01

ad-hoc 签名、未公证的 App 能否通过 SMAppService 注册为登录项，还没有验证过（ADR-0010）。

## 当前有效产物与人工入口

- 使用 [CI 41671769227](https://github.com/coderhyy/clash-kuro/actions/runs/41671769227) 的 `2617cf9`、macOS／Windows 双绿产物：`/tmp/clash-kuro-acceptance-2617cf9/clash-kuro-0.1.0-arm64.dmg`。SHA256 为 `98db3afba40fedc24905877fe8d04ae6c10904142051ff4a37f0135388b0065f`，本轮只读 `hdiutil verify` 通过；下方旧包记录保留为历史。
- 校验命令、保存清单与逐阶段条件见 [人工验收入口](../../phase2/manual-acceptance.md)。自启约 15–25 分钟，含两次注销／登录；安排在备份验收及原数据恢复之后。用户明确开始前不读取个人基线、不安装启动 App、不改登录项／代理或注销。
- 开始后先核对其他工具的系统代理。当前 macOS clear 会关闭所有启用网络服务的 HTTP／HTTPS，未逐项校验归属；若发现其他工具代理或归属不明，先暂停退出／停止 Core／注销等可能清理代理的步骤，与用户协商隔离窗口和基线恢复，不自动覆盖。

## 负责范围与执行依赖

- 本票负责 macOS 打包版的系统登录项注册、批准、状态刷新，以及真实登录启动进入 Tray Mode；01 已 resolved。
- 主会话统一准备精确提交的 CI 产物、记录产物身份和安排系统状态操作窗口；子 agent 负责只读检查与隔离测试；用户完成系统批准和注销／登录。
- 与 Windows 08 收尾无代码依赖，可并行准备；与备份 02 共用同一份 CI dmg。先完成备份验收并恢复数据，再进行本票的登录项和注销验证，避免注销中断备份操作。
- 执行前置条件：当前提交的 dmg 已准备、保存已有登录项与 System Proxy 状态、主会话确认同机没有其他代理／登录项／路由验证在运行。该操作窗口是资源依赖，不取消原有 issue 依赖。

## 步骤

1. 用户明确开始后，使用上方当前有效 CI dmg，按人工入口保存基线并核对 SHA256；主会话确认串行操作窗口后，由用户安装到 `/Applications`，按 README 处理隔离标记，记录 macOS 版本、实际安装路径和安装后签名结果，再启动。仅版本号 0.1.0 不足以证明产物身份；如要验收后续代码，先替换为对应提交的新 CI 产物并重新记录身份。
2. 在设置面板打开开机自启，记录界面状态（已开启或需批准）。若需批准，点按钮到“系统设置 → 通用 → 登录项”批准，回到窗口确认状态变成已开启。
3. 注销再登录：确认 App 自动启动、没有窗口和 Dock 图标、托盘在；有 Active Profile 时 Core 在跑；System Proxy 没开（符合决定 4）。
4. 在系统设置里关掉 Clash Kuro 的登录项，切回 App 窗口，确认开关变成关闭。
5. 在 App 里关闭后注销再登录，确认不再自动启动。
6. 普通打开 App（不是登录启动）仍然弹窗口。

## 完成标准

- 在同一个已记录身份的打包产物上完成上述六步；每步保存时间、观察结果和必要截图。注册、批准后状态回读、系统外部修改后刷新均符合 spec。
- 两次真实注销／登录分别证明“已启用会启动”和“关闭后不启动”；启用时没有主窗口／Dock 图标、托盘可用，Active Profile 的 Core 已运行且 System Proxy 未重开。
- 普通手动启动仍显示窗口；测试结束恢复开始时的登录项状态、Profile 数据和代理状态，并记录恢复结果。
- 将实测结果追加到 Comments，主会话复核后才把本票与 spec 的待验收状态关闭。mock 测试和签名检查不能代替 SMAppService 注册或真实登录启动。

## 若失败

- 注册报错或状态一直是 `not-found`：记录 `app.getLoginItemSettings()` 的输出，回到 spec 重议（可能需要签名）。

## Comments

### 2026-11-03 并行验收准备

- 本轮源码基线为 `6ea3720de352bbc6c4214d327fff7c5ec5f71f35`；检查到 `login-item.ts` 仍仅允许打包 macOS 调用系统登录项，主进程用 `wasOpenedAtLogin` 隐藏 Dock／跳过窗口，窗口聚焦会刷新状态。
- 本轮隔离验证：desktop 下运行 `bunx vitest run src/main/platform/login-item.test.ts src/main/backup-ipc.test.ts src/shared/i18n/zh-CN.test.ts --maxWorkers=2`，17/17 通过；state 下运行 `bunx vitest run src/backup.test.ts src/store.test.ts --maxWorkers=2`，107/107 通过。这里包含两项登录项映射／注册门禁测试，以及 store 的启动读取、切换后回读、刷新与不持久化测试；其余是共享备份／翻译检查，不全部算作自启场景。
- 只读检查发现现有 `apps/desktop/dist/clash-kuro-0.1.0-arm64.dmg` 和 `dist/mac-arm64/Clash Kuro.app` 为 2026-10-31 产物。dmg SHA256 为 `8a0d1acd945ab6d4302cf876eaef25254a802db98344ff79f7ea6796dc47799a`；dist 与 `/Applications/Clash Kuro.app` 的 app.asar SHA256 相同，均为 `0cef962ce29840b06a2cb209debbc06e1c082a6c1d5dec706fe49c00fbca1984`。dist App 的 `codesign --verify --deep --strict` 通过，`codesign -dv` 显示 adhoc、无 TeamIdentifier。这证明旧包签名结构完整，不能证明它包含当前源码或能注册登录项。
- 当前阻塞：等待主会话准备当前提交产物，以及用户的系统批准／两次注销登录窗口。本轮没有打包、启动真实 App、修改登录项或代理、注销或关机；Status 保持 ready-for-human。

### 2026-11-04 精确 CI 产物已准备

- 主会话已核实 PR #1 于本轮前合入 main `6ea3720de352bbc6c4214d327fff7c5ec5f71f35`。[CI 41667528925](https://github.com/coderhyy/clash-kuro/actions/runs/41667528925) 的 macOS job 成功，使用其 `kuro-macos-arm64` artifact 中的 `clash-kuro-0.1.0-arm64.dmg`。
- 已下载到 `/tmp/clash-kuro-acceptance-6ea3720/clash-kuro-0.1.0-arm64.dmg`，大小 `150277373` bytes，SHA256 `dda5f1ff6f7d8382182aaf325eb1a71fbf0ba97554af24e5e0129a4f72b70e6e`。本轮 `hdiutil verify` 完成且退出 0，报告 checksum VALID；验证前后 SHA256 和文件大小一致，未将下载中的部分文件计作可验收产物。临时目录可能被系统清理，人工窗口前再次核对文件存在与摘要。
- 这份包的验收只覆盖 `6ea3720`；它不包含随后独立分支的 Windows 开机自启或 CI fixture 修复。macOS job 成功不等于整条跨平台 CI 成功：本次 Windows job 存在 Backup IPC 启动 mock 与权限故障注入失败，主会话另行修复；上轮 17/17、107/107 是 macOS 隔离结果。
- 产物准备阻塞已解除。剩余集中操作为：先完成备份 02 并恢复数据，再批准系统登录项、两次真实注销／登录及普通手动启动核对，最后恢复原状态。磁盘镜像校验只证明 dmg 完整；新包的安装后签名、真实注册和登录启动仍待执行。本轮未挂载、安装或启动 App，未修改系统设置。

### 2026-11-04 人工验收入口更新

- 当前候选更新为上方 `2617cf9` 双绿 CI 包，SHA256 与预期一致，`hdiutil verify` checksum VALID、退出 0。旧 `6ea3720` 包不包含后续改动，保留历史记录但不作为当前验收包。
- 已把保存原 App、冷备份业务数据、系统代理各协议／PAC／自动发现／bypass、登录项原状态及两次注销的阶段条件集中到人工入口。本轮只核对源码与包；用户尚未开始，真实操作与个人基线读取均未执行，Status 保持 ready-for-human。
