# Windows 开机自启

Status: ready-for-human
Type: task
Blocked by: `.scratch/mvp/issues/08-windows-system-proxy.md` 合并进 main（已满足：PR #1，main `6ea3720`）；当前集成提交的 Windows CI/打包产物、真机验收窗口
Owner: Windows 自启 agent（实现）；主会话（集成与验证）；维护者（真实登录会话）

Windows 实现已在本轮集成分支完成，待新产物与真机验收；原定内容如下：

- `setLoginItemSettings({ openAtLogin, args: ['--hidden'] })`，读取时传同样的 `args`。
- 登录启动的判断改为 `process.argv.includes('--hidden')`。
- 需要 Windows 真机验证，和 08 一起或在它之后做。

## 负责范围与共享接口

- 本票负责 Windows 登录项适配和登录启动进入 Tray Mode；沿用 `../spec.md` 的系统状态为准、仅打包版可用、登录后不恢复 System Proxy 三项决定。
- 复用 `Platform.getLaunchAtLogin/setLaunchAtLogin`、`LaunchAtLoginStatus`、`setLaunchAtLogin` Command、`AppStore.refreshLaunchAtLogin()` 和现有设置开关，不新增快照字段、Command 或 IPC。
- 预计修改 `apps/desktop/src/main/platform/login-item.ts` 与 `.test.ts`，将 `LoginItemApp` 的 Electron 切片扩展到 Windows 所需 options/result；修改 `apps/desktop/src/main/index.ts` 的首次启动和 second-instance 窗口判断，并补相应主进程 mock 回归测试。`platform/index.ts` 已传入 `app`，无需另接一条入口。
- 现有 store 单测覆盖系统状态重读、失败后重读、非法载荷和不持久化；仅在行为变化时补充。渲染层依据 `unsupported` 自动隐藏，无需专门的 Windows UI 分支。
- 主会话统一处理 Git 集成。Windows 真实登录项、System Proxy 和会话验证共用一台机器时串行执行。

## 实现前提与最小方案

1. 主会话以远端 main / PR 合并证据确认 issue 08 已合入；当前工作区分支名或已包含相似代码不足以解除 `Blocked by`。确认后记录依据，再开始源码实现。
2. macOS 分支保留现有 SMAppService 映射。Windows 打包版使用 Electron 的当前用户登录项，注册和查询使用相同 `args: ['--hidden']`，使用默认应用身份和当前可执行文件路径。开发版返回 `unpackaged` 并拒绝写入；其他平台或缺少 `app` 返回 `unsupported`。
3. Windows 开关反映本应用匹配启动项的实际启用状态。Electron 45 的类型说明明确：`openAtLogin` 按 path/args 查询，`executableWillLaunchAtLogin` 忽略 args；不能直接用后者把同一 exe 的其他启动项当作本项。实现时核对 `launchItems` 中匹配项的 `enabled`，并用下表覆盖系统禁用与不同 args 的情况。无需引入新的 `requires-approval` 状态或 macOS 设置入口。
4. Windows 首次以 `--hidden` 启动时只建托盘，不建主窗口；普通启动弹窗。macOS 继续使用 `wasOpenedAtLogin` 并隐藏 Dock。已有实例收到 Windows `--hidden` 的 second-instance 时保持原窗口状态；普通 second-instance 继续打开窗口。
5. 有 Active Profile 时沿用现有 Core 启动流程；登录项只启动应用。代理恢复、helper 生命周期和恢复记录继续由 issue 08 的既有流程管理。本票不注册 RunOnce、不新增服务或安装器、不记忆或自动开启 System Proxy。

## 自动验证矩阵

| 范围 | 场景 | 通过标准 |
| --- | --- | --- |
| 登录项适配 | Windows 打包版开 / 关 | setter 收到对应 `openAtLogin` 和 `['--hidden']`；getter 使用同样的 args，状态来自系统读回 |
| 系统状态 | 匹配条目启用、系统禁用、无匹配条目 | 分别显示 `enabled`、`disabled`、`disabled`；Windows 不显示 macOS 批准提示 |
| 条目身份 | 同 exe 不同 args 或其他应用条目启用 | 不得把其他条目计为本应用 `--hidden` 启动项启用 |
| 开发与不支持平台 | Windows 未打包、Linux、缺少 app | 分别返回 `unpackaged` / `unsupported`；setter 拒绝且不调用系统写接口 |
| macOS 回归 | 原有 status 与 openAtLogin 映射、注册参数 | 原有行为与测试继续通过，Windows args 不传给 macOS |
| 主进程 | Windows 首次 `--hidden` / 普通启动；macOS 登录 / 普通启动 | 登录启动进入 Tray Mode，普通启动建窗；macOS Dock 行为保留 |
| 单实例 | Windows `--hidden` / 普通 second-instance | 隐藏启动保持窗口状态；普通启动显示窗口 |
| store 与持久化 | 切换后、窗口聚焦后、注册失败后重新读取 | 快照跟随系统；`settings.json`、Backup 不新增登录项状态 |

实现完成需通过相关单测、根目录 `bun run typecheck` 与 `bun run test`，并成功构建 Windows 产物。自动验证使用 mock，不修改开发机登录项或代理。

## Windows 真机完成标准

使用合入 issue 08 后、包含本票修改的打包产物，记录 commit、产物身份、Windows 版本和各步骤结果；系统状态操作由主会话统一协调。

1. 普通打开 App，确认显示主窗口；设置面板显示开机自启开关，初始状态与匹配启动项一致。
2. 在 App 打开开关；确认系统启动项指向当前 App，参数含 `--hidden`，没有新增 RunOnce 或其他服务。
3. 用户注销并重新登录：托盘可用且不弹窗；有 Active Profile 时 Core 正常运行，System Proxy 未自动打开；托盘打开窗口功能正常。
4. 在 Windows“启动应用”或任务管理器中禁用本项，回到 App 聚焦窗口，开关变为关闭。再从 App 开启并读回系统状态，确认系统禁用不会导致界面误报。
5. 在 App 关闭开关后，再次注销 / 登录，确认 App 不自动启动；普通手动打开仍弹窗。
6. 按测试前记录恢复用户的开机自启状态，确认不影响其他应用启动项。真机各项通过后才将本票标记 `resolved`；仅自动测试通过时记录“实现完成，待真机”，保留待办。

## Comments

### 2026-11-03 — 并行准备完成，保留 issue 08 合入依赖

- 已检查登录项适配、主进程首次/二次启动、store Command/refresh、快照、设置 UI 和 Electron 45.1.0 本地类型声明。现有接口足够，未发现需要用户新增产品选择；系统禁用状态和启动项身份匹配属于实现与测试边界。
- 本轮只执行 mock 验证：desktop `login-item.test.ts` 2/2 通过；state `store.test.ts -t 'Launch at Login'` 2/2 通过（其他 70 项因过滤跳过）。这些结果验证当前 macOS/不支持平台基线，尚未验证 Windows 实现。
- 已明确文件范围、自动测试矩阵和 Windows 真机完成标准；源码实现等待主会话确认 `Blocked by` 已满足。未执行 Git 变更、登录项/代理/路由写入、真实 App 启动、注销或关机。

### 2026-11-04 — 依赖已满足，隔离实现并由主会话集成

- GitHub PR #1 已于 2026-11-03 23:47:29（Asia/Singapore）合入；重新 fetch 后 `origin/main` 为 `6ea3720de352bbc6c4214d327fff7c5ec5f71f35`。这满足原定“08 合入 main”条件，不表示取消或异常恢复验收已完成，也不表示旧 CI 失败可以忽略。
- 在独立 worktree 实现并集成四个文件：`platform/login-item.ts`、`platform/login-item.test.ts`、`main/index.ts`、`main/launch-at-login.test.ts`。复用现有 Platform/Command/快照/UI；Windows 按相同 `--hidden` 参数注册与查询，并核对可执行文件、参数及系统启用状态。
- mock 验证首次隐藏启动、普通启动、隐藏/普通 second-instance、Active Profile 的 Core 启动及不自动开启 System Proxy；macOS 登录/Dock 行为保留。未修改机器的启动项、代理、路由或登录会话。
- 独立实现类型检查 4/4、相关单测 19/19、桌面构建通过；主会话整合 CI fixture 修复后，全量测试 576 通过、16 平台相关项跳过，类型检查 4/4 通过。Windows 精确提交 CI 与打包产物由主会话继续核验，未把 macOS 测试当作 Windows 真机验收。
