# 04/06：普通 UID 固定 Core 的有限控制实验准备

状态：新诊断候选准备中，须由主会话提交后重新离线构建并冻结精确身份；本轮没有运行 Core 或 `-t`。旧 `639c64fbfd3d371057dfd59d8b01b882c8aebbe3` 产物与[历史准备记录](evidence/core-control-preparation/RESULT.md)原样保留，不覆盖、不修改、不重试。历史记录的授权与结果不自动适用于新候选。此实验不安装 App/helper、不重复 root 客户端鉴权，不开放生产 `Authorize` 或 `activationAllowed`。auth observation 的精确包、pin、证据不复用为本实验 Core 证据。

## 离线交付与身份

提交冻结源代码后，普通用户运行：

```sh
node apps/desktop/scripts/build-core-control-experiment.mjs --self-test
node apps/desktop/scripts/build-core-control-experiment.mjs darwin-arm64
```

第一条只在内存验证 archive 摘要、版本及 Mach-O 类型/架构；不创建文件或子进程。第二条只从 `resources/.cache/<core.lock archive SHA256>` 读取固定 v1.19.33 gzip，验摘要后解压，不下载、不运行 Core（包括 `-t`），编译独立 `core-experiment.m` 并 ad-hoc runtime 签名实验执行器。编译宏固定 `KURO_CORE_EXPERIMENT=1` 及实际解压 Core/锁定 archive 的 SHA256。Core 副本保持原 archive 解压字节，不为方便运行而改写或重签它。

输出为 `apps/desktop/dist/core-control-experiment-<完整源码提交>/`，拒绝覆盖既有目录：

- `core-experiment`：本次普通 UID 实验执行器；不替换生产 helper。
- `mihomo`：锁定 archive 解压得到的固定 Core。
- `experiment.json`：闭合 `format/protocol/target/coreVersion/coreSHA256/coreArchiveSHA256/runnerSHA256/epoch` 八字段；仅固定文件名，无外部路径选择。
- `artifact.json`：源码提交、递归 native import/source 摘要、精确编译 flags/编译器版本、Core 锁定 URL/archive/executable 摘要、执行器摘要、manifest/inventory 摘要、下述诊断契约及未执行声明。
- `core.lock.json`、`inventory.json`、`SHA256SUMS`：来源与固定 payload 文件名/大小/mode/摘要。`bundleSHA256` 明确定义为 sorted `inventory.json` 字节的 SHA256，不是 Electron App 身份，也不是完整目录包含自身的递归摘要。`SHA256SUMS` 覆盖交付的其余全部文件。

`artifact.json` 的 `appBundle` 和 `productionHelper` 均为 null；不将已通过 auth 安装实验的 App/helper 摘要冒充本实验使用者。builder 要求构建前后同一提交、`apps/desktop` 与 `packages` 源码干净、所有递归源文件摘要不变。

## 新候选诊断契约

`experiment.json` 仍为八字段，success 仍为 16 字段；新候选的 `coreStdIO` 改为 `bounded-redacted-capture`，不接受旧包的 `discarded-to-dev-null` 作为新诊断证据。每次运行由 guardian 新建独立 `/private/tmp/kuro-core-evidence-XXXXXX` 目录（0700），与可清理的运行 `base` 分离；result 的 `diagnosticsDirectory` 指向该目录。准备脚本只在 `artifact.json` 记录契约，不预建或复用任何运行证据。

目录内固定五个文件，均为 0600：

- `config.redacted.json`：实际启动配置的脱敏副本，移除本次控制 secret；实际 `configSHA256` 与 `redactedConfigSHA256` 分别记录，不能互相替代。
- `launch.json`：固定 argv、工作目录及环境变量键集合；不记录 secret 或环境变量值，不提供任意启动参数入口。
- `stdout.log`、`stderr.log`：各最多保留 64KiB。超过上限仍持续读取并丢弃超量字节，不能因停止读取而堵住 Core。持久化前移除本次 secret，包括读取块边界上的匹配；这是对已知会话 secret 的脱敏，不保证任意 Core 输出均无其他敏感信息。
- `diagnostics.json`：`format/failureStage/termination/capture/cacheIdentity/diagnosticError/configSHA256/redactedConfigSHA256/workAbsent/ownerAbsent` 十字段。`capture` 对 stdout/stderr 分别记录 `bytesRead/retainedBytes/truncated/eof/readErrno`。日志错误单独记录，不改写已观察到的退出码或信号。

`launch.json` 仅写 `format/argv/workdir/environmentKeysSet/inheritsEnvironment/configSHA256/redactedConfigSHA256/configSummary` 八字段。环境存在性记录 PATH/LANG 为 set，HOME/DYLD_*/CLASH_* 为 absent；Core 不继承用户环境。`configSummary.secret` 仅为固定 `[REDACTED]`。

直接 child 已 reap 后，先落两份脱敏日志、已知 cache 身份和含 termination 的 `diagnostics.json` checkpoint，完成目录 fsync，才允许清理对应运行文件。最终 diagnostics 更新先校验自身原 checkpoint 字节及严格权限，不覆盖未知改动；无法留证应报告 blocked 并保留相关运行数据。采集器在 child 退出后再给 500ms drain 窗口、最多等待 1 秒 join；未确认 EOF/读回完整则拒绝清理。诊断目录保留供审阅，不能把它的存在解释为 Core/owner/work 清理失败，也不能把目录存在当作证据已完整落盘。查看/分享日志前仍需检查内容。新候选冻结完成后才可请求执行授权。

[固定 Core 离线核对](core-control-offline-review.md)已发现 select 可能初始化 `cache.db`，以及 Unix controller 不验证 Bearer secret。诊断脱敏不提供访问控制证明；实验的 Unix 边界依赖私有目录和 socket/Core 身份核对，同 UID 恶意进程不因 0700 被隔离。已知 cache 也只能在直接 child 退出、身份与摘要稳定确认后有限清理，不能据文件名扩大删除范围。

## 授权后的有限执行顺序

当前仅准备，以下命令不得作为 build/test 附带执行。执行前先冻结实际产物路径、源码提交、manifest/执行器/Core 摘要、guardian 截止时间和恢复步骤，再请求这一次普通 UID Core 执行授权。

1. 只读复算冻结目录 `SHA256SUMS` 和 `artifact.json`，确认当前为普通 UID，源码/架构与本机匹配。只按精确输出目录和文件执行，不按程序名找其他 App/Core。
2. 执行该目录 `core-experiment --self-test`：仅原生配置/fixture/session/control 校验，不运行真实 Core 或 `-t`。此结果与 builder 纯内存 self-check 区分记录。
3. 获得授权后，才执行精确路径的 `core-experiment --normal`。执行器只读自身 canonical 目录的固定清单与 `mihomo`，使用内建 nonTUN/no-DNS/no-public-listener 配置和私有控制路径，固定序列验证 `/version`、有类型有限控制及读回（mode 与 DIRECT/REJECT 选择）、正常 stop 及清理证明。记录实际 fixed Core PID/start identity、执行器/guardian、临时工作目录与精确退出结果。
4. 原生执行器先以独占创建写 `normal-attempt.json`；只有完整通过才写同 epoch/hash 绑定的 `normal-success.json`。success 闭合的 16 个字段是 `format/epoch/stage/status/coreSHA256/runnerSHA256/session/configSHA256/coreVersion/coreAbsent/ownerAbsent/workAbsent/groupAbsent/termination/coreStdIO/noIPReadbacks`。要求 `format:1`、对应 `stage`、`status:passed`、同 epoch/Core/runner 摘要、合法 session UUID 与 config 摘要、四个 absence 布尔值全 true、`termination.observed:true`、`coreStdIO:bounded-redacted-capture`、`noIPReadbacks:2`。失败结果 `<stage>-result.json` 不具有通过含义。失败、超时、未知停止、任何摘要/权限不符立即停止；不根据 PID 猜杀，不进入 EOF 阶段。重复同阶段被拒绝；如需修复重试，先审查/处理本次遗留，再冻结新 epoch。
5. 仅 `--normal` 成功证据完整且继续获授权时执行 `core-experiment --eof`。原生再次校验同 epoch、Core/执行器/清单绑定的 normal 成功，先写 `eof-attempt.json`，由 guardian 对自己持有的 owner socket 执行写端关闭，验证生产 `KuroOwnedSession` 的 EOF 停止与清理；只有完整成功写 `eof-success.json`。这不是实际 Electron 进程断线实验。
6. `--inspect` 只读校验固定产物身份和 `normal-success.json`，输出 receipt 与 `normalPassed`；它不读取各 stage result、不重新扫描工作目录/进程，也不清理残留。残留需从各 `<stage>-result.json` 的 `base` 开始另行只读检查；未知文件/进程保留，交人工审阅，不从持久 PID 取得 signal/清理授权。保存 stdout/stderr、阶段证据及摘要。

guardian 的事件观察窗口为 15 秒，结束后走有限进程组清理：先给 worker 500ms 自然退出机会，再最多 SIGTERM 等 300ms、SIGKILL 等 1000ms；约 1.8 秒等待另含有限身份读回与调度开销，不是操作系统保证的硬实时总时限。worker 自身 owner socket lease 为 5 秒。只有 guardian 仍持有未 reap 的直接子进程 anchor、核对 PGID 与全部组成员时，才允许该有限清理；无法证明时保留证据并报告 blocked。

success 的 `termination` 也是闭合对象：仅 `request/observed/exitCode/signal` 四字段，`request` 为 `none`、`SIGTERM` 或 `SIGKILL`，`observed:true`，且只能是 `exitCode:0..255` 配 `signal:null`，或 `exitCode:null` 配 `signal:1..NSIG-1`。该状态证明退出已观察，不要求 Core 必须自然退出；具体请求和退出结果原样留证。

**helper SIGKILL 阶段当前没有可执行入口，也不在上述授权范围。** 出现新的或未知残留时先报告，不能把正常 stop/EOF 的成功扩称跨 helper 崩溃恢复。

## 通过范围与剩余缺口

通过只证明该固定普通 UID Core 的私有控制、直接子进程生命周期、正常停止与有限 EOF 行为。NoIP 仅是两次进程 FD 观测，不证明执行期间从未有瞬时 IP socket 或网络访问。guardian 只在自身存活且 held unreaped 直接子进程 anchor/PGID 有效时清理已核对的进程组，未知成员保留并阻止成功，不按持久 PID 信号；不能覆盖 guardian 被 SIGKILL 或脱离组的 Core 后代。

它不证明 root 运行、生产 App→helper 动态鉴权与 Core 会话组合、真实 Core 无后代或后代不持有 utun，也不证明 TUN、路由/DNS、代理、登录项、launchd、升级或卸载。生产 root 候选及真实系统网络实验继续单独准备和授权。
