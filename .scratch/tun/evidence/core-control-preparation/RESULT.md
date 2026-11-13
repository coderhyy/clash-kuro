# 固定 Core 前置实验：离线准备结果

源码提交：`639c64fbfd3d371057dfd59d8b01b882c8aebbe3`。状态：**可执行，等待真实 Core 新授权**。未执行 normal/EOF、mihomo、`-t`、安装、job 或网络设置变更。

产物目录：`/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/core-control-experiment-639c64fbfd3d371057dfd59d8b01b882c8aebbe3`

- 执行器 SHA256：`0f010836b99a4251dacf3e923bab4c720a87fda0dfea22d06a3b73f8f4986114`
- 固定 mihomo v1.19.33 SHA256：`f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`
- inventory.json SHA256：`445ebe1992beefeabbe2da958a17c1d133426f0117cec8267b94db42a9f46e06`（固定 payload 清单摘要，不是 pkg 或 App 摘要）
- experiment.json SHA256：`83ef292d814a531bc75ecc1224b263c6fb080799e0d04619deadf310e405a326`
- epoch：`51ACE461-6D10-48F2-8828-E00282DD8C4E`

`artifact.json` 保存完整编译 flags、编译器、recursive source inventory、锁定 archive 与实际二进制来源。构建前后 source commit/clean 状态核对通过，未下载/运行 Core；runtime ad-hoc 签名及strict校验通过。最终目录执行 `shasum -a 256 -c SHA256SUMS` 六项全部OK。

## 实际自动验证

- 生产 helper/native strict clang、全fixture通过，包含25个service场景；显式KURO_SKIP_CORE_SYNTAX=1。见compile-command.txt/stdout.log/stderr.log。
- 独立runner源码严格编译、38个fixture断言通过，见native-fixture-verification.log。
- **最终签名产物**仅执行`--inspect`及`--self-test`：inspect为prepared、normalPassed=false；self-test exit0，38断言通过，stderr空。没有执行真实Core。最终产物self-test的异常fixture evidence留在`/private/tmp/kuro-core-PQihn9`，通过条件含worker已reap、组无成员及fixture Core明确ESRCH；owner/config/socket刻意保留，不作持久PID清理。
- builder纯内存self-check与node语法检查通过；git diff --check通过。没有新远端CI运行，不把历史CI当本提交证据。

## 下一步精确授权范围

预计5–8分钟（含身份、证据和残留核对），普通用户，不需管理员密码。按[步骤](../../core-control-experiment.md)先复核SHA256SUMS与inspect，再仅运行本目录`core-experiment --normal`。只有退出0、normal-success完整绑定本epoch/hash、准确Core/worker/组退出与owner/work/socket清理确认全部通过，才进入`--eof`。EOF是owner Unix连接断开，不是实际Electron退出。

每阶段启动固定Core，写入独立`/private/tmp/kuro-core-XXXXXX`目录（Core副本、config、owner、私有socket），在产物目录写stage-attempt/result/success证据。不发送代理请求/延迟测试，不创建公开IP监听；固定配置关闭TUN、DNS、NTP及remote providers。两次FD读回仅是时点证据，不能证明从未瞬时联网。

恢复：正常/EOF使用准确未reap direct-child停止；CTRL-C或15秒阶段观察超时后，仍存活的guardian只对held unreaped supervisor锚定、身份已核对的专用组执行有限TERM/KILL收尾（约1.8秒等待，另含读取/调度）。然后核对组为空、原Core明确不存在。成功只删本次精确匹配工作文件/目录，保留result/success。未知成员、身份/摘要变化、无法确认停止、未知工作文件一律blocked并保留base/owner/config/socket证据，停止下一阶段；不从持久PID或程序名杀进程，也不临时扩大删除。guardian自身SIGKILL/脱组后代不在保障内；本次不故意进行这类强杀。

## 生产缺口

安装绑定的鉴权→有限会话接线和resume前持久neverStarted=false已实现；默认/auth-only产物仍禁用activation。首次真实root TUN前仍须补运行后的准确卸载证明及新生产候选。跨helper重启对仍存在的路由/DNS仅保守阻塞/absence恢复；后代退出、真实utun双栈/LAN分域DNS恢复未验证。完整升级继续保留04要求，不阻塞本次ordinary UID实验。
