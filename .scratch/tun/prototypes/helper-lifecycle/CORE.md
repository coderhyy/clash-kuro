# 实验 A 的固定 Core 无 TUN 候选

此分支只准备候选。**不沿用旧 fixture 实验的系统操作授权；当前不安装、不启动真实 Core（包括 `-t`）、不调用 launchctl、不改网络。** 生产源码、生产 helper 与旧实验 A 的编译分支保持不变。

目的只有一个：在 `AbandonProcessGroup=false` 的独立 LaunchDaemon 中，验证锁定 mihomo v1.19.33 是否保留 helper 的实际进程组，并在 helper 被 job 定向 SIGKILL 后由 launchd 清退。无路由、DNS、系统代理、TUN 或真实 Electron。静态源码未发现脱离进程组，不等于实际运行已证明。

## 准备与有限自测

主会话先冻结源码并提供 40 位 commit。普通用户执行（准备器只读 `git rev-parse/status/show`：要求当前HEAD精确匹配、所有输入clean且每个实际源码SHA与该commit blob一致，编译前后重复核验；不写Git）：

```sh
python3 .scratch/tun/prototypes/helper-lifecycle/prepare-core.py \
  --output /private/tmp/kuro-lifecycle-core-review-新的唯一名字 \
  --source-commit 主会话冻结的40位commit
```

准备器校验本地 `core.lock.json` 中 v1.19.33 的下载 archive SHA，解压后验证本机 thin Mach-O/filetype EXECUTE，并将实际 executable SHA 编译进 fixture。无网络下载；从不执行 `mihomo`。输出包含 fixture、两份同 SHA Core、两个独立 UUID、精确 normal/kill plist、八字段 approval、源码/编译参数/字节 inventory、SHA256SUMS。输出存在就拒绝，不覆盖旧包；失败输出保留。`--config stage epoch` 只调用实验自己的序列化器，不调用 Core。

普通用户可以编译候选后执行其 `lifecycle-a --self-test`：它只复制当前测试程序充当 Core fixture，创建临时 Unix socket/子进程，并在**测试外层**建立一次性组。真实 supervisor 路径从不 `setsid`/`setpgid`。它验证私有 readiness、继承组、held-child 停止、布尔成功凭据与 owner/work 清理。另执行 `python3 -m unittest discover -s .scratch/tun/prototypes/helper-lifecycle -p test_core_driver.py`，纯隔离测试不调用 launchctl。

复用 `core-experiment.m` 的配置、typed control、输出捕获、`KuroOwnedSession`，**不调用 ordinary-UID Worker/Guardian**。复用 session 的实验宏只改变 capture FD/可读文件 anchor/template/实验证据；spawn flags 仍没有 `POSIX_SPAWN_SETPGROUP`，环境仅 PATH/LANG，无 HOME、DYLD、CLASH 继承。normal/kill 各自 Core 在 stage 目录内，避免放宽 session 保护锚点。共享 Core 实验 worker 的空 cache 预创建行为不被本分支调用或依赖。

配置沿用已验证的无 TUN固定配置：五种 IP listener port 全 0；DNS/TUN/NTP/sniffer/iptables/tuic 关闭；无 proxy/rule provider、无 URL/外部 UI、无 startup shell；只私有 Unix control socket；固定内联 select 组 DIRECT/REJECT、MATCH,DIRECT。每次 readiness 与停止/kill 等待前完整读取 held child FD：发现 AF_INET/AF_INET6/AF_SYSTEM 或不完整枚举立即阻塞。该检查是观察时点，不是 OS 网络沙箱，也不证明所有瞬时 socket 从未存在。

## 专门授权窗口中的顺序（当前不要执行）

主会话需先核对产物/SHA/固定源码和确切系统窗口。以下 CLI 均使用本 review 里的完整、已审核 `core-driver.py`，以 `python3 -I` 调用；不会自动 sudo。每步参数：

```text
sudo /usr/bin/python3 -I /private/tmp/kuro-lifecycle-core-review-唯一名字/core-driver.py 操作 \
  --review /private/tmp/kuro-lifecycle-core-review-唯一名字 \
  --approval-sha 准备器打印的approvalSHA256
```

1. `install`：仅固定 root 文件复制，不加载 job。拒绝任何已有 binary/plist/数据目录；保护链拒 symlink、写权限、ACL。固定 label/binary/plist 与旧实验 A 相同，因此旧资源未清完就阻塞。数据目录下 normal/kill 各自 Core 副本和日志；无自动部分安装回滚。
2. `normal`：bootstrap + kickstart normal epoch。持有 direct child → 私有 `/version` + typed只读 mode/selection → 两次 FD/noIP 检查 → 持有该同一 child 的 TERM/必要时 KILL → waitpid/reap → 持久化 bounded日志与 reaped/cache证据 → 精确已知 work 清理/owner unlink/fsync。只有完整成功才原子发布 `normal-success.json`。命令还独立读回 supervisor/child 内核启动身份、组为空、work/owner不存在，两次确认。**驱动另要求精确 normal job 的 runs=1、not running、无 live PID/termination signal、last exit code=0（缺失/非0均拒绝，避免最后 fsync失败却留下完整成功文件时被误用）。root 成功 receipt 仍不能替代主会话独立核对这些 PID/start/PGID/executable、路径/进程消失及 launchctl 状态。** 如失败，不继续 kill，不重试该 epoch。
3. 主会话核对 normal 原始证据后，才准 `prepare-kill`：再次核对 protected normal成功、实际进程/组/路径已消失、normal job精确一次exit0且无 live PID，bootout并确认 absent；仅把精确旧 plist 替换为独立 kill epoch 的精确 plist。不启动 Core。
4. 独立授权的 `kill-test`：开始一次 kill epoch，readiness后核对 live supervisor/child/start/path/PGID、完整组仅两者、距 evidence单调时钟 <25秒。唯一 kill 操作为 `launchctl kill SIGKILL system/dev.kuro.tun.lifecycle-a`；从不对 evidence PID/旧 PGID 发信号。之后 1秒/5秒只读采样必须两者 absent且完整组空，且没有 supervisor正常 reap/fallback结果，才能写 `group-observation.json`。这仍是本次观察；主会话需独立核对。默认无 KeepAlive/RunAtLoad，不自动重启。
5. `inspect-normal` / `inspect-kill`：只读核验当前 stage精确安装、保护证据和实际身份/完整组/work存在性。未知或身份复用不当成 absent。检查旧 stage 前 plist 必须仍匹配它；切换后使用 kill observer。
6. `retire-normal` / `retire-kill`：只在两次实际进程/组 absent、精确 job无 live PID 后卸载该 job，再确认 job absent。**此命令不删除 root文件或证据。** 主会话保留日志后按确切已知文件另行审阅清理；不递归删除、不按旧 PID杀、不猜未知 cache/owner。kill 后 owner/work预计保留，不把此事实当生产恢复通过。

若 kill未按时发生，supervisor30秒窗口到期会仅停止自己仍持有的 child，记录 blocked并保留 work；该 fallback不算 launchd通过。若 helper已死而 Core/组仍存活或身份未知，驱动停止并保留所有证据，**不能凭记录 PID/PGID补杀**。没有新增 guardian/常驻监护层，真实失败需主会话按仍持有的 launchd job身份另行审阅，不能宣称自动恢复。

## 证据与边界

每流持续公平 drain，最多保留64KiB，持久化前脱敏实验token。固定0700 stage/0600文件：`attempt.json`、`config.redacted.json`、`launch.json`（argv、仅环境key、实际组、config/Core SHA）、`stdout.log`、`stderr.log`、`evidence.json`（两进程启动身份/路径）、正常 reap时 `reaped.json`（termination/capture/cache身份）、`result.json`；normal成功另有原子 `normal-success.json`。kill成功观察另有 `group-observation.json`。实验token来自本 stage UUID，仅本实验私有 control使用，不含用户Profile/账号凭据；redacted配置/输出不包含该 token。

approval闭合八键：format、normalEpoch、killEpoch、fixtureSHA256、coreSHA256、coreArchiveSHA256、normalConfigSHA256、killConfigSHA256。normal result/success闭合十二键：format、stage、epoch、status、approvalSHA256（native canonical JSON hash）、coreSHA256、fixtureSHA256、childReaped、workAbsent、ownerAbsent、termination、error。后三个消失/回收字段必须JSON布尔true；termination必须本次TERM/KILL请求后观测exit0或匹配signal，不能把提前自退算成功。原包/epoch不得重试，attempt/results/未知文件全部保留。

这里尚未验证实际 root LaunchDaemon+固定Core、真实网络恢复、TUN、helper-kill后生产恢复/卸载、升级或 App。真实窗口必须独立授权；本候选不把无害 fixture、仅拒绝路径、成功 receipt 或静态源码审查冒充这些结论。
