# 第二期并行执行入口

2026-11-04。主会话负责依赖、共享接口、Git 集成和最终验证；沿用下表现有 issue，本文件不取代各票的验收标准。

## 当前任务与完成标准

| 工作 / 负责者 | 依赖与并行边界 | 当前交付 | 完成标准 |
| --- | --- | --- | --- |
| [Windows System Proxy 08](../mvp/issues/08-windows-system-proxy.md) / 主会话 | 验收记录整合 → CI fixture 修复 → 精确提交 CI；与其他研究/自动验证并行 | 原验收文档已恢复；PR #1 已合入是既成事实；后续改动在 draft PR #2 | 新提交 Windows/macOS CI 及打包通过；真实恢复未验收项仍明确保留，不擅自关闭票或合并 PR |
| [macOS 自启 02](../launch-at-login/issues/02-macos-real-device-verification.md) / 验收 agent + 维护者 | 实现01已完成；当前产物已准备；真实登录项/注销操作需系统时段 | mock 检查、CI DMG 来源/SHA256/完整性、集中人工步骤 | 打包版注册/批准、登录进入托盘、系统外部禁用读回、关闭后不再启动，全部记录在原票 |
| [Backup 02](../backup/issues/02-backup-real-device-verification.md) / 验收 agent + 维护者 | 实现01已完成；与自启检查共享产物；实际代理/数据恢复串行 | mock 检查、真实对话框/重启与原数据恢复步骤 | 中英文对话框、导出、导入恢复数据、代理清理、自动重启、坏文件不变、验后恢复原数据 |
| [Windows 自启 03](../launch-at-login/issues/03-windows-launch-at-login.md) / Windows agent + 主会话 | 原阻塞“08合入main”已由 PR #1 和 `origin/main=6ea3720` 证实满足；无需等macOS验收 | 独立 worktree 实现、mock 启动测试，已整合；未扩张共享接口 | 单测/typecheck/Windows构建通过，再用精确产物完成登录项/隐藏启动/系统禁用/注销登录验收 |
| [TUN 01](../tun/issues/01-scope-and-lifecycle-decisions.md) / 主会话+维护者 | macOS/传统helper/互斥退出/正常重开关闭手动启用及双栈固定模板/无高级UI已批准 | 参数可技术选定；仅LAN/分域DNS隐私与DIRECT/无独立kill switch两组影响待确认 | 产品影响与源码候选/实测结果分开，不再等IPv6批准 |
| [TUN 02](../tun/issues/02-platform-feasibility.md) / 研究agent | 已resolved；保留一手资料 | 固定Core/平台机制/权限边界研究完成 | 不作为真实TUN验收 |
| [TUN 04 helper](../tun/issues/04-macos-privileged-adapter.md) / helper agent | 内含原11/12；安装事务与认证实验并行，生产pin依赖受保护安装记录；与06并行 | 已有原生服务/socket与客户端源码，可信链/root schema/准确owner及网络恢复仍关门；历史原型证据保留 | 安装/认证/broker/准确owner/网络归属清理完整验证，真实操作等“开始” |
| [TUN 06 生命周期](../tun/issues/06-state-and-ui.md) / 接入agent | 内含原03/10；机制无关契约和fake测试独立，生产联调等04 | 生产客户端/State/UI已接线；主会话阶段State151、desktop359+17skip/typecheck绿；最终组合待回填 | 共享契约/配置/调用方/测试矩阵为票内清单，互斥、重开关闭手动启用和未知门禁通过 |
| [TUN 08 集成验收](../tun/issues/08-tun-integration-acceptance.md) / 主会话 | 04+06技术门与具体产品影响；双栈/技术选型已批准，不依赖Windows05/07 | 精确源码/产物与结果待汇合 | 同一提交自动检查、产物、真实验证证据齐全，系统操作串行 |
| [TUN 07 旧Windows恢复](../tun/issues/07-deferred-windows-recovery-validation.md) / 主会话+维护者 | 准备独立；真实操作等精确范围、产物和“开始” | 取消关机/启动journal/retained-helper三项延期保留 | 不用EOF清理替代journal回放，不阻塞macOS首版 |

## 共享文件和系统状态协调

- Windows 自启只改 `main/index.ts`、`platform/login-item.ts` 及其测试；CI 修复只改 `backup-ipc.test.ts`、`platform.test.ts`，由主会话整合。TUN 源码由 04/06 实施 agent 按主会话指定文件范围推进，公共接口由主会话统一，不抢改同一文件。
- 主会话统一处理 Git 分支、提交、PR、rebase 和合并。子 agent 交付未提交的范围明确 diff；独立 worktree 只隔离文件，不隔离系统。
- 当前没有 agent 持有真实系统状态操作权。代理、登录项、网络路由、服务安装、注销/关机都由主会话安排一个场景完成并恢复基线后，再进行下一个；CI 使用独立 runner 的既有保护流程。
- macOS 人工验收顺序：先 Backup 场景并恢复数据/代理，后登录项批准与两次注销登录。每次先核对产物身份；现有 `2617cf9` 候选包只证明该版本，不能用于声称后续代码已验收。
- 等CI或真实系统时段时继续资料研究、mock验证和文档，不以一个平台等待为由阻塞其他独立任务。

## 暂不实施

- Linux：等待目标发行版/桌面环境、包格式和权限方案；依赖最终共享契约。
- 正式签名/公证：延期，不作为 ADR-0015 传统管理员安装路线的首版前置条件；后续正式分发另行确定身份/证书/发布范围。
- 自动更新：依赖正式签名以及helper/Core升级回滚策略，沿用ADR-0010。


## 当前执行与证据边界

- 人工入口见 [manual-acceptance.md](manual-acceptance.md)：现有候选包 `2617cf9`、CI41671769227 双平台成功，身份/SHA256/DMG完整性已核对；它不包含后续 TUN 改动。先 Backup 并恢复原环境，再登录项；维护者未说“开始”前不读取私人基线、不启动/安装 App 或改系统。
- [ADR-0014](../../docs/adr/0014-macos-tun-lifecycle.md)、[0015](../../docs/adr/0015-macos-traditional-privileged-helper.md)、[0016](../../docs/adr/0016-macos-tun-manual-start.md)、[0017](../../docs/adr/0017-macos-tun-dual-stack.md) 固定 macOS首版、传统管理员helper、互斥与退出清理、正常重开先残留检查并保持TUN关闭/仅手动开启。付费会员/SMAppService/DeveloperID/公证延期，不使用setuid Core/任意root命令路径。
- 实施仅跟踪04/06/08；原[03](../tun/issues/03-shared-contract-and-config.md)/[10](../tun/issues/10-mode-transition-contract.md)并入06，原[11](../tun/issues/11-protected-install-transaction.md)/[12](../tun/issues/12-peer-authentication-and-broker.md)并入04，旧票历史与回链保留。归并不是实现完成，不新建票。
- 已有证据：普通配置门禁 Core138/State125/桌面Profile7项和Core/State类型检查；既有生命周期定向12项；安装目录模型16项（setuid为元数据模拟）；C身份原语两分支。均仅证明受测范围，不证明完整Electron认证/root事务/网络恢复。异常锁下Backup可替换文件是历史缺口：生产store现于导入入口及await stop后requireSession，三异常时机拒绝目标替换且无Core/代理写；State全127/127和typecheck通过。完整TUN仍需准确owner/自有网络停止证据。
- 04 安装事务与认证/有限broker实验可并行，生产 pin依赖受保护安装记录；06机制无关契约/配置/生命周期回归独立。主会话接受最小接口再统一集成，源码由其他agent交付，最终命令和结果等待主票Comments回填，不先写完成。
- 本轮实际交付：06 Backup异常锁/停止期间异常的导入保护接入生产store（State127通过）；04离线准备器接package命令，消费真实锁与资源链，prepare/fetch23项通过，backup-ipc/Profile17项通过，根typecheck四包通过。真实资源因原生helper/pin尚缺明确exit1，无安装产物；准备器不是已完成helper服务，下一步仍需原生服务/有限协议及相关权限边界实现。尚无新CI/验收包，原2617cf9不含这些改动。
- 双栈固定模板/无高级参数UI/参数可技术选定已批准，正常启动关闭；[固定版本候选与证据](../tun/spec.md#固定版本事实与技术候选)初选mips、双族auto-route/auto-detect、native DNS/内部端点与redir-host，未执行root/网络实验、不作为已验证默认。IPv6路由、接口变化、AAAA/单族失败回退、停止/异常恢复、双栈泄漏测试为04/06/08清单。先完成root schema再实现模板；不静默关闭IPv6，不宣称全接管/防泄漏。
- Windows TUN05不实施，旧Windows07恢复独立保留；真实系统操作仍无“开始”授权，等待期间继续未阻塞隔离验证。Linux、正式签名和自动更新不扩张为本轮实施。

- 本轮新增接线检查点（更新上述早期“原生源码尚缺”记录）：原生helper/socket与macOS客户端已有源码，State与双语UI消费统一TunStatus/setTun/recoverTun；UI25项及renderer typecheck通过，主会话报告State151/desktop359+17skip/全量typecheck绿，最终native修复/build/CI/产物仍待汇合。原生当前拒绝未完成的完整Electron可信链、root配置schema和未知清理，不把UI可点或服务回答当成TUN可用。
- 当前可并行：04可信链/有限root schema/准确owner及两族网络恢复设计与隔离验证；06调用方/失败矩阵和UI；主会话组合检查。模板实现明确依赖04 root schema，而不是所有参数再等产品批准。01只集中LAN/分域DNS及明确上游隐私、显式DIRECT与无独立kill switch两组产品影响；不为这些新建票或默认选择公共resolver。

## 2026-11-04 生产接线与验证检查点

04原生helper、06状态/UI生产调用链与双栈规格并行交付后，由主会话收口：当前692项自动测试通过（API12/Core138/State166/Desktop376），另16项平台跳过；全量typecheck、App production build、本地DMG构建及native隔离编译测试通过。测试数包含参数化用例，不表示692项产品功能或真机场景。原型证据单列，不累加到产品测试数。

实际可运行的是普通Core/Backup/登录项原链路加TUN状态与恢复门禁，native socket/CLI为受限生产实现；尚不能启动真实TUN。04仍缺完整Electron可信链、root有限配置/broker、准确owner与lease、双栈网络归属清理和升级，06真实TUN接管依赖这些入口。disabled helper安装包不等于可用TUN产品，不能混入Backup/登录项验收。08负责同commit CI/dmg/pkg身份记录与后续人工验收；操作顺序仍Backup恢复→登录项，TUN另排且等待明确“开始”。

最终产物源码`9990da69c565cef973e8560636fd2fb68fddbf15`：[CI 41774486923](https://github.com/coderhyy/clash-kuro/actions/runs/41774486923) macOS/Windows均通过，App/helper下载后source-commit与摘要一致，DMG verify VALID。草稿PR #3依赖PR #2，未合并。精确路径、摘要、预计耗时与需保存内容以[人工验收入口](manual-acceptance.md)为准；TUN disabled pkg只审阅，不混入Backup/登录项验收。
