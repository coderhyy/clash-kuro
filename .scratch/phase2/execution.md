# 第二期并行执行入口

2026-11-04。主会话负责依赖、共享接口、Git 集成和最终验证；沿用下表现有 issue，本文件不取代各票的验收标准。

## 当前任务与完成标准

| 工作 / 负责者 | 依赖与并行边界 | 当前交付 | 完成标准 |
| --- | --- | --- | --- |
| [Windows System Proxy 08](../mvp/issues/08-windows-system-proxy.md) / 主会话 | 验收记录整合 → CI fixture 修复 → 精确提交 CI；与其他研究/自动验证并行 | 原验收文档已恢复；PR #1 已合入是既成事实；后续改动在 draft PR #2 | 新提交 Windows/macOS CI 及打包通过；真实恢复未验收项仍明确保留，不擅自关闭票或合并 PR |
| [macOS 自启 02](../launch-at-login/issues/02-macos-real-device-verification.md) / 验收 agent + 维护者 | 实现01已完成；当前产物已准备；真实登录项/注销操作需系统时段 | mock 检查、CI DMG 来源/SHA256/完整性、集中人工步骤 | 打包版注册/批准、登录进入托盘、系统外部禁用读回、关闭后不再启动，全部记录在原票 |
| [Backup 02](../backup/issues/02-backup-real-device-verification.md) / 验收 agent + 维护者 | 实现01已完成；与自启检查共享产物；实际代理/数据恢复串行 | mock 检查、真实对话框/重启与原数据恢复步骤 | 中英文对话框、导出、导入恢复数据、代理清理、自动重启、坏文件不变、验后恢复原数据 |
| [Windows 自启 03](../launch-at-login/issues/03-windows-launch-at-login.md) / Windows agent + 主会话 | 原阻塞“08合入main”已由 PR #1 和 `origin/main=6ea3720` 证实满足；无需等macOS验收 | 独立 worktree 实现、mock 启动测试，已整合；未扩张共享接口 | 单测/typecheck/Windows构建通过，再用精确产物完成登录项/隐藏启动/系统禁用/注销登录验收 |
| [TUN 01](../tun/issues/01-scope-and-lifecycle-decisions.md) / 维护者 + 主会话 | D1–D3 产品选择；D2以02证据为依据；与02研究并行 | 草案明确首批平台、权限生命周期、TUN与代理/配置策略的待决点 | 选择有记录，架构限制变动通过明确决定处理，不将提案当授权 |
| [TUN 02](../tun/issues/02-platform-feasibility.md) / 研究 agent | 无实现依赖；官方资料与只读检查 | 已完成[一手资料研究](../tun/platform-feasibility.md)，02 resolved | 技术结论均有来源，签名/权限/所有权边界和仍需实验项明确；未冒充真实TUN验收 |
| [TUN 03](../tun/issues/03-shared-contract-and-config.md) / 主会话 | 等01产品/架构决定；02已完成 | 待开始 | 共享类型、配置归属、协议与 Fake 一次统一并通过回归，供平台/UI复用 |
| TUN [04 macOS](../tun/issues/04-macos-privileged-adapter.md) / [05 Windows](../tun/issues/05-windows-privileged-owner.md) / [06 State/UI](../tun/issues/06-state-and-ui.md) | 都等03；只实现D1选中的平台。03稳定后分worktree并行 | 未开始实现 | 各票功能/失败路径/权限边界通过；UI可先用Fake联调，真实系统验收串行 |
| [TUN 07 恢复验收](../tun/issues/07-deferred-windows-recovery-validation.md) / 主会话 + 维护者 | 准备可并行；执行等明确实验范围、精确产物和系统时段 | 承接已延期取消关机、启动journal恢复、显式retained-helper恢复 | 三种场景独立证据；成功父进程EOF清理不算journal回放验收 |
| [TUN 08 集成](../tun/issues/08-tun-integration-acceptance.md) / 主会话 | 所选平台适配+06；Windows恢复边界还需07 | 待开始 | 最终同一提交的自动检查、产物身份和所选平台真实验收齐全 |

## 共享文件和系统状态协调

- Windows 自启只改 `main/index.ts`、`platform/login-item.ts` 及其测试；CI 修复只改 `backup-ipc.test.ts`、`platform.test.ts`，由主会话整合。TUN 当前只写 `.scratch/tun/`，不抢改共享接口。
- 主会话统一处理 Git 分支、提交、PR、rebase 和合并。子 agent 交付未提交的范围明确 diff；独立 worktree 只隔离文件，不隔离系统。
- 当前没有 agent 持有真实系统状态操作权。代理、登录项、网络路由、服务安装、注销/关机都由主会话安排一个场景完成并恢复基线后，再进行下一个；CI 使用独立 runner 的既有保护流程。
- macOS 人工验收顺序：先 Backup 场景并恢复数据/代理，后登录项批准与两次注销登录。每次先核对产物身份；现已下载的 `6ea3720` 包只证明该版本，不能用于声称后续代码已验收。
- 等CI或真实系统时段时继续资料研究、mock验证和文档，不以一个平台等待为由阻塞其他独立任务。

## 暂不实施

- Linux：等待目标发行版/桌面环境、包格式和权限方案；依赖最终共享契约。
- 正式签名/公证：等待身份/证书/发布范围；若选中的TUN安装机制要求签名，则作为该机制的明确依赖。
- 自动更新：依赖正式签名以及helper/Core升级回滚策略，沿用ADR-0010。
