# 04：安装授权后的有限动态鉴权实验

> 实际执行更新：1ad5f06候选已在授权下尝试安装，preinstall被本机/private/var/run 0775父链检查阻塞；未进入动态auth，目标及receipt无残留。见[执行结果](evidence/auth-execution-1ad5f06/RESULT.md)。下述步骤保留为本次历史计划，不表示该包当前可成功安装，授权已结束。

范围：fresh-only，受保护 App 的无副作用 authenticate。实验 A 的授权已结束；本文所有安装、root 进程及卸载步骤必须另获用户明确授权。生产 TUN 启动仍拒绝，完整升级不阻塞本次实验但仍属于 04 的交付要求。

## 有限通过标准

1. 实际 Electron 候选通过严格完整 seal、封印 ASAR、最小 entitlement/runtime 与既定五项 fuse 检查；原有 14 项隔离功能/调试/环境载荷矩阵通过。只按该具体矩阵验收，不以“穷尽 Chromium/DYLD”作为前置。出现新的可复现加载/特权绕过再处理。
2. 在固定 root 保护目录完整安装后，合法 App 用内核 audit 身份通过**生产同一个** `AuthorizeClientAt`，返回精确 `{version:1,ok:true,authenticated:true}`。
3. 同 UID 外部程序、合法重签但与 pin 不同的 App 副本收到明确 native 身份拒绝。资源修改导致 seal 无效单独记录为 seal 拒绝，不冒充 native RPC 证据。原生真实签名普通用户夹具另覆盖同路径活进程资源变更与 pin 变更拒绝；它不代替 root 安装结果。
4. auth 服务拒绝 start/open/stop/recover/exec 等所有非观察操作；没有 token/lease/会话可供升级能力。服务不创建 ProductionService/Core/network 对象。生产请求先走相同客户端鉴权，再遇独立激活门；观察成功不会移除该门。
5. fresh 回执先于 App 复制落盘，绑定 helper/manifest/plist/完整文件清单。失败可恢复批准文件的缺失子集；未知、修改、身份不符内容保留并停止。实验结束核对 App、批准记录、helper、socket、plist、Installer receipt 的清理结果。
6. 每个客户端有明确超时，服务接受请求的软时限 300 秒；持久 endpoint 回执成功后才启用 310 秒 SIGALRM 紧急退出。超时不是成功证明，必须先确认该自有进程已退出，再按回执恢复；不通过猜 PID、广泛删除或临时扩大授权恢复。

边界：不要求抵御恶意 root、已被攻陷的 App/用户会话或用户已授予的调试/辅助功能控制。安装 pin 是该精确 App 的长期有限授权，不证明每条请求都是物理点击；root API 仍必须闭合配置、固定 Core 和准确会话归属。

## 与现有 App 的关系

实验候选只装到 `/Library/Application Support/Clash Kuro/Client/Clash Kuro.app`，不替换 `/Applications` 中现有副本、不修改登录项、不读取或迁移现有 Profile/userData。实验包 ASAR 内封印 `kuroAuthObservationOnly:true` 与源码提交：普通双击/hidden/PSN 启动退出，只允许 auth/runtime 两种隔离入口。无此封印标记的正式构建保持原行为。

实验用完整可执行路径启动，不按 App 名称或 bundle ID 查找，避免 LaunchServices 选错副本。每次客户端运行只写新建、当前用户独占的 OS 临时目录；不进入正常 main 或单实例锁。完成后按 fresh 清单删除本次受保护副本；现有 App 和共享父目录保留。此布置不是正式版并排安装策略。

## 运行步骤（授权后，预计 8–12 分钟）

最终候选路径、提交、SHA256、负例 prepared.json 和精确 helper 路径以同目录 `auth-observation-artifact.json` 为准；缺少该文件或任一摘要不符就停止。

1. 复算包、helper、脚本和负例摘要；只读确认固定 Tools/State/SocketDirectory/Client App/fresh 回执/恢复入口都不存在，且 `pkgutil --pkg-info dev.kuro.tun.disabled` 无既有 receipt。遇到已有安装不能覆盖或自动卸载它。
2. 保存安装前目标状态，然后管理员授权执行 `/usr/sbin/installer -pkg '<精确候选包>' -target /`。包保持 disabled，不 bootstrap launchd、不启动 Core。安装失败立即停止测试，只用下述固定恢复入口处理可证明属于本次的文件。
3. 读取 installed/client/fresh 记录，复核 root 所有权、ACL、seal、manifest 和包摘要。以管理员授权在前台运行记录中的**精确版本 helper** `--serve-auth`，保留该调用的退出状态；不执行 `--serve`。它只提供 `/var/run/dev.kuro.tun/auth.sock`，不注册新 LaunchDaemon。
4. 普通用户运行 `node apps/desktop/scripts/run-electron-auth-observation.mjs '<prepared.json>'`。它依次执行实际安装 App 正例、重签副本 native 负例、外部 Node native 负例、非观察操作负例；对修改 ASAR 的副本只做离线 seal 验证、不运行它。报告逐步写入 `kuro-auth-results-*`，失败即停止剩余测试。服务不存在/超时/解析错误不计为拒绝通过。
5. 等待服务正常退出（最多 300 秒软时限，310 秒紧急退出），保留管理员命令退出状态；检查 auth.sock/auth-observer.json 是否消失。紧急退出或异常时不继续测试，以回执和锁验证后恢复。
6. 管理员授权执行 `/Library/PrivilegedHelperTools/dev.kuro.tun-uninstall --uninstall`。入口先持全局/服务锁，校验 fresh 回执、文件/链接/权限/摘要和 auth socket device/inode；允许缺失批准文件，拒绝未知内容，不按 PID 杀进程。它删除本次受保护 App、helper、批准记录与固定 socket/plist，不碰用户数据/现有 App。若仅恢复入口本身残留，可重复同一固定命令完成最终清理。
7. 只读核对上述目标均不存在、`launchctl print system/dev.kuro.tun` 不存在；如 Installer 成功登记过 receipt，先用 `pkgutil --pkg-info-plist` 和 `--files` 与本次候选清单核对，再管理员执行 `pkgutil --forget dev.kuro.tun.disabled`。forget 仅清安装元数据，不代替文件清理。保存最终只读核验、日志及摘要。

停止条件：摘要/身份变化、已有目标冲突、真实客户端非预期退出、超时、无回执残留或无法确认清理。保留证据，只尝试上述批准回执恢复；恢复拒绝就报告具体路径，不扩大删除范围。本文不包含关机/注销、代理、路由、DNS 或登录项变更授权。

## `mihomo -t` 的准确含义

既有测试确实通过 `posix_spawn` 启动固定 mihomo 子进程，参数为 `-t -d <新临时目录> -f <该目录/config.json>`。测试器本身创建临时目录和配置，最后删除；进程输出也会写 stdout/stderr。它不是“没有运行 Core”。

固定 v1.19.33 的 [main.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/main.go#L170) 在 `-t` 分支之前调用 `config.Init`；[initial.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/config/initial.go) 在目录或配置缺失时会创建它们。随后 [executor.Parse](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/hub/executor/executor.go#L64) 进入配置解析，成功即退出，未进入后面的 `hub.Parse`/`ApplyConfig`，因此不会走该正常启动路径中的 listener/TUN/路由应用阶段。

但 `-t` 不是普遍无副作用的纯语法检查：[ParseRawConfig](https://github.com/MetaCubeX/mihomo/blob/v1.19.33/config/config.go#L625) 会构造代理/provider/规则/DNS对象，并注明部分规则解析涉及 geodata 加载和下载。既有测试使用预先创建文件、无 provider/GEO 规则的受限模板；当时未做系统调用/文件变化跟踪，不能追认“Core 绝无额外文件或外部访问”。可确认的是执行过子进程和临时文件写入、没有执行正常 TUN 配置应用；不能扩称完整零系统副作用验证。本轮所有 native 测试显式 `KURO_SKIP_CORE_SYNTAX=1`，未重跑 `mihomo -t`。
