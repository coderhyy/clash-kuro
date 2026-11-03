# 备份真机验证

Status: ready-for-human
Type: task
Blocked by: 01

对话框和 `app.relaunch()` 只能在真机上看。

## 负责范围与执行依赖

- 本票负责原生保存／打开／确认对话框、真实 System Proxy 清理、Backup 导入后的 App 重启与数据恢复；01 已 resolved。
- 主会话统一安排当前集成提交的产物和系统状态操作；子 agent 负责只读检查与隔离测试；用户集中完成原生对话框操作、观察重启和数据核对。
- 与 Windows 08 收尾无代码依赖，可并行准备；与 macOS 自启 02 共用同一份 CI dmg，先执行本票并恢复数据，再执行登录项和注销验证。
- 执行前置条件：主会话记录当前产物的完整 commit、SHA256、安装路径与 macOS 版本；保存原有 Profile／Override／Settings 和 System Proxy 状态，准备可恢复的本地备份。测试用两个受控 Profile，含密钥的真实备份留在仓库外。
- 同机修改代理、登录项、路由或注销／关机的操作由主会话串行排期；等待人工窗口时可以继续 mocked tests 和其他平台工作。

## 步骤

1. 使用下方 2026-11-04 记录且摘要核对一致的 CI 打包版，由主会话协调安装与系统状态操作窗口；导入两份受控 Profile，设一个 Active Profile，保存一份有效 Override、界面语言和 mixed-port 基准值；Core 正常运行后打开 System Proxy，并记录真实系统代理端点。开发版可辅助排错，最终结果记录实际验收产物。
2. 点“导出备份…”：先出现“请妥善保管”警告（切到 English 再看一次英文），再出现保存对话框；打开导出的 JSON 确认内容。
3. 删掉一份 Profile、改 mixed-port。
4. 点“导入备份…”选刚才的文件，确认对话框后：System Proxy 被关掉，App 自动重启，Profile 和 mixed-port 恢复，数据目录 `backups/` 下有 `pre-import-*.json`。
5. 导入一个随便改坏的 JSON：显示错误，数据不变，App 不重启。

## 完成标准

- 中文、English 各确认一次警告／原生对话框文案；取消警告、保存／打开对话框或导入确认后，文件和 App 数据不变且不重启。
- 导出文件可解析，format/version 正确，Settings、两个 Profile 原文、Active Profile、Override 和语言完整；不含 Runtime Config、pid、Geo 数据和开机自启状态。导出文件权限为 0600。
- 导入有效备份后只有一个重新启动的 App，恢复两份 Profile 原文、Active Profile、mixed-port、语言与 Override；自动 `backups/pre-import-*.json` 存在且对应导入前状态。系统代理已实际关闭，没有仍指向旧端点的手动代理；Core 是否随 App 启动按既有 Active Profile 启动规则观察，不能要求重启后仍停止。
- 非法 JSON／非法 Override 被拒绝，Profile、Settings、Override 保持原值，App 不重启；不通过在真实数据盘制造写入故障来重复单测中的恢复路径。
- 结束后恢复原有数据与代理状态；在 Comments 写入每步实测结果、产物身份和恢复结果。主会话复核后关闭本票和 spec 的待验收状态。

## Comments

### 2026-11-03 并行验收准备

- 本轮源码基线为 `6ea3720de352bbc6c4214d327fff7c5ec5f71f35`；检查主进程 IPC 具备可信窗口校验、取消分支、50 MB 限制、临时文件原子导出、导入成功后的 `app.relaunch()` 与退出。store 导入在队列内先备份、调用 Platform 停止（Platform 负责先清代理），最后写 settings.json；写入失败自动恢复，恢复也失败才阻止后续 Command。
- 本轮 desktop 隔离验证：`bunx vitest run src/main/platform/login-item.test.ts src/main/backup-ipc.test.ts src/shared/i18n/zh-CN.test.ts --maxWorkers=2`，17/17 通过，覆盖 Backup IPC 原生 API mocks、中英文文案、取消、大小上限、失败保留与重启调用；state 的 `bunx vitest run src/backup.test.ts src/store.test.ts --maxWorkers=2`，107/107 通过，覆盖校验、往返、队列、代理清理失败和自动恢复。两组包含其他功能用例，不是 124 个真机 Backup 场景。
- 现有本机 dmg、dist App 与 `/Applications` App 是 2026-10-31 旧产物；其摘要与签名只读结果见 `../../launch-at-login/issues/02-macos-real-device-verification.md` 的同日记录。它们不作为本次源码的验收包。
- 当前阻塞：主会话准备当前提交产物并安排原生 UI／真实代理的串行人工窗口。本轮只运行 mocks/FakePlatform 与临时目录测试，没有启动真实 App、改系统代理／登录项／路由或触发注销／关机；未发现需要修改共享源码的缺陷，Status 保持 ready-for-human。

### 2026-11-04 精确 CI 产物与人工窗口

- 优先验收 [CI 41667528925](https://github.com/coderhyy/clash-kuro/actions/runs/41667528925) 的成功 macOS job、`kuro-macos-arm64` artifact；源码 commit 为 `6ea3720de352bbc6c4214d327fff7c5ec5f71f35`。文件 `/tmp/clash-kuro-acceptance-6ea3720/clash-kuro-0.1.0-arm64.dmg`，大小 `150277373` bytes，SHA256 `dda5f1ff6f7d8382182aaf325eb1a71fbf0ba97554af24e5e0129a4f72b70e6e`。本轮 `hdiutil verify` 完成、checksum VALID、退出 0，前后摘要与大小一致。此产物取代 10 月 31 日旧包作为本次验收候选。
- 验收结果只适用于 `6ea3720`，不覆盖后续 Windows 自启与 fixture 修复。macOS job 成功和本轮 17/17、107/107 隔离测试不能写成跨平台 CI 全通过；同 run 的 Windows Backup IPC mock／权限故障注入失败由主会话处理。
- 产物下载阻塞已解除，等待集中人工窗口。用户顺序为：记录原数据和真实代理基线 → 安装摘要一致的包 → 中英文导出与取消 → 导入有效备份并观察重启／真实代理清理／数据恢复 → 拒绝非法 JSON／Override → 恢复原数据及代理 → 再执行 macOS 自启 02。每一步的具体通过标准仍以上文为准。
- 新包未挂载、安装或启动，磁盘镜像完整性检查不代替原生 UI、真实代理和重启验收；Status 保持 ready-for-human。
