# 实验 A：无网络 launchd 进程组生命周期

固定 mihomo 无 TUN 的后续候选见 [CORE.md](CORE.md)。它使用独立编译分支与 normal/kill 两个新 epoch；下文旧 fixture 授权、marker/TTL 和旧产物不适用于真实 Core。

**执行更新：用户明确授权后，本 epoch 已执行并清理。** child 在强杀后约 1s/5s 已不存在，没有依赖 marker/TTL；测试 job、binary、plist、实验数据目录均已确认移除。证据与限制见 [结果记录](results-668F8E2A/RESULT.md)。下文保留执行前方案与精确产物记录；不要据旧授权自动重复实验。

2026-11-04：**当前只完成普通用户编译、自测和 review 目录准备。没有安装、运行 launchctl 或强杀系统进程。** 不属于生产 helper，不创建 TUN、网络 socket、路由或 DNS，不包含 broker 或生产 start 绕过。

本轮可审阅产物：

- 源码：`lifecycle-a.m`；固定路径驱动：`experiment-a.py`；驱动隔离测试：`test_driver.py`。
- 编译产物：`/private/tmp/kuro-lifecycle-a/lifecycle-a`。
- 普通用户准备目录：`/private/tmp/kuro-lifecycle-a-review`，包含 binary、精确 plist、approval；已存在时拒绝覆盖。
- 本次 epoch：`668F8E2A-414B-476C-A648-1DC49D24788B`。
- binary SHA256：`6a9c665c6af2dc3428db026d61ad5b734577afff809e00dba08ed968173798ef`。
- driver SHA256：`4b1c05025816da23ffe702eaaaa7598c12d4663c0c8836c608f059479ee64953`。
- native source SHA256：`3d1d01c8e2c8fe92fe33b46c4b6fbb5e275f55759a09c938b2f7319e9019e537`。
- 本机依赖已核验：macOS arm64、Apple clang、Foundation、`/usr/bin/python3` 3.9.6；Python 仅标准库。安装时检查 Mach-O 为本机 thin arm64/x86_64，不混用架构。其他机器需重新编译、生成新 review 并核验新 hash。

| 实验资源 | 固定值 |
| --- | --- |
| launchd label | `dev.kuro.tun.lifecycle-a` |
| binary | `/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a` |
| plist | `/Library/LaunchDaemons/dev.kuro.tun.lifecycle-a.plist` |
| 数据目录 | `/Library/Application Support/Clash Kuro/TunLifecycleExperimentA` |
| 数据文件 | `approval.json`、`evidence.json`、可选 `stop.json`、可选 `child-exit.json` |

## child 残留的有限清理

supervisor 用默认 `posix_spawn` 启动同 binary 的 child；不调用 setsid/setpgid。证据记录 epoch、label、binary SHA256/device/inode、supervisor/child PID、内核启动时间、实际 executable、parent/pgroup。child 内部每 20ms 检查一次：

1. root 保护目录中 root:0600、普通单链接、非 symlink 的 `stop.json` 是否仅包含**本次精确 epoch**；匹配才自行退出。错误 epoch、错误权限或读取失败均不批准停止。
2. 独立单调时钟期限 **300 秒**是否到达；到期自行退出，不依赖 helper 或 marker。期限检查与 observer 都使用原生 CLOCK_MONOTONIC；系统睡眠/暂停可能影响观察，不能拿墙钟等待代替身份核验。

自行退出会写 `child-exit.json`，reason 为 `stop-marker` 或 `deadline`。它解决本无网络 fixture 的残留，不是生产 Core watchdog。脚本从不向 evidence 中的 PID 发信号；身份复用或未知状态均停止删除。

**launchd 组清理通过只允许在 kill-test 的早期窗口判定**：run 后 30 秒内开始强杀，杀后 1 秒、5 秒采样，两进程均 absent，且没有 stop marker 或 self-exit receipt。TTL 或 marker 导致的消失属于“残留已自清理”，不得记为 launchd 通过。

## 本轮离线验证（可普通用户运行）

已有的 `/private/tmp/kuro-lifecycle-a` 是本轮专用构建目录，不要覆盖其他人的同名目录。全新机器先人工创建该空目录，再编译：

```sh
clang -fobjc-arc -Wall -Wextra -Werror -O2 -framework Foundation \
  .scratch/tun/prototypes/helper-lifecycle/lifecycle-a.m -o /private/tmp/kuro-lifecycle-a/lifecycle-a
/private/tmp/kuro-lifecycle-a/lifecycle-a --self-test
PYTHONPYCACHEPREFIX=/private/tmp/kuro-lifecycle-a/pycache /usr/bin/python3 \
  .scratch/tun/prototypes/helper-lifecycle/test_driver.py
```

本轮 native 自测通过：身份/starttime 错误拒绝、真实 `posix_spawn` pgroup 继承、真实普通子进程错误 epoch 不退出、正确 marker 自退出、无 marker 时单调时钟到期退出。驱动 **8 个隔离测试通过**：job/epoch/PID 绑定、缺 evidence 不删除、foreign marker 保留、unknown/reused PID 不发系统命令、symlink/FIFO 拒绝、非 root 系统操作拒绝。测试没有调用 launchctl；没有验证真实 launchd 行为。

全新 review 目录可由普通用户生成（本轮已生成，重复执行会失败）：

```sh
/usr/bin/python3 .scratch/tun/prototypes/helper-lifecycle/experiment-a.py prepare
```

## 用户明确“开始”后的固定命令

**下面当前不要执行。** 主会话先提供上述 binary、驱动源码的路径与 hash，用户核验后才授权系统操作；脚本不会自行 sudo。若本地重新构建，须使用新 review 输出的 epoch/hash 替换下面两项，不复用旧值。系统步骤预计 **3–5 分钟**；等待 TTL 的最坏清理约 **5–7 分钟清醒时间**。`run` 后 30 秒窗口有意限制很短，执行前先准备好下一条命令。

```sh
EXPERIMENT_DRIVER='/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/.scratch/tun/prototypes/helper-lifecycle/experiment-a.py'
EXPERIMENT_EPOCH='668F8E2A-414B-476C-A648-1DC49D24788B'
EXPERIMENT_SHA='6a9c665c6af2dc3428db026d61ad5b734577afff809e00dba08ed968173798ef'

# 1. 首次只复制已 pin 字节和固定 plist，不加载服务。
sudo /usr/bin/python3 -I "$EXPERIMENT_DRIVER" install "$EXPERIMENT_EPOCH" "$EXPERIMENT_SHA"

# 2. bootstrap + kickstart，记录初始精确身份，必须看到二者 same-instance-live。
sudo /usr/bin/python3 -I "$EXPERIMENT_DRIVER" run "$EXPERIMENT_EPOCH" "$EXPERIMENT_SHA"

# 3. 30 秒内执行：按固定 launchd job 强杀 supervisor，绝不用旧 PID。
sudo /usr/bin/python3 -I "$EXPERIMENT_DRIVER" kill-test "$EXPERIMENT_EPOCH" "$EXPERIMENT_SHA"

# 4. 无论组清理是否通过，都执行本次准确清理流程。
sudo /usr/bin/python3 -I "$EXPERIMENT_DRIVER" cleanup "$EXPERIMENT_EPOCH" "$EXPERIMENT_SHA"
```

可随时只读观察：

```sh
sudo /usr/bin/python3 -I "$EXPERIMENT_DRIVER" observe "$EXPERIMENT_EPOCH" "$EXPERIMENT_SHA"
```

安装前置检查：label/目标文件必须全不存在；root 祖先逐项 lstat、类型/mode 与 ACL 检查，拒绝 symlink、group/other write 或任何 ACL。只在缺失时创建固定共享 `Clash Kuro` 父目录为 0755，不 chmod/chown 已有共享祖先，卸载不删共享父目录。root 先把 review 文件完整读入并核验 hash/epoch/plist，再 O_EXCL 写固定目标；不执行 payload 提供的任意程序/脚本；系统命令执行的是经用户审阅、hash 核对的 Python driver，且使用 `python3 -I` 隔离导入。遇到既有/部分安装立即保留并阻塞。这是**实验驱动，不是完备生产安装器**；不保证电源中断原子恢复，也不抗 root 并发改动。

固定 plist 仅包含 Label、ProgramArguments（固定 binary/`--supervisor`/epoch）、RunAtLoad:false、KeepAlive:false、AbandonProcessGroup:false；不会自动重启。driver 每次修改服务前比对该 plist 和 `launchctl print` 的 program/参数/epoch，强杀前另核验 job PID 与 evidence supervisor 相同。

## 回滚与停止条件

`cleanup` 先核验 installed hash/approval/epoch/evidence 与确切 job，写入 root0600 epoch marker，让 child 自己结束；等最多 310 秒单调时钟。marker 无效仍有 child 的独立 300 秒期限。只有 observer 证明两进程 absent，才对核验无误的固定 job bootout，并再次核验 job 不存在、进程仍 absent、evidence 未变，最后删除 exact 文件和已空实验目录。它不会碰生产 label、网络或共享父目录。

- `GROUP-CLEANUP-PASS`：只证明该 fixture 此次的早期 launchd 行为。
- `GROUP-CLEANUP-NOT-PROVEN`：继续 cleanup；marker/TTL 清理成功也不能补记组清理通过。
- 缺 evidence、观察失败、PID 复用、错误 epoch/未知文件、固定资源变更、launchd 无法明确核验、等待超时：`BLOCKED`，保留文件；不得把未知当 absent，不 killall/pkill、不按旧 PID kill、不递归删除。
- 部分安装在 evidence 生成前失败同样会阻塞自动清理；由主会话只读核验后另给精确方案，不能声称脚本覆盖所有失败恢复。

保存终端完整输出即可：run/kill-test 打印核验的 launchctl 内容和每次身份观测；cleanup 在删除前打印 approval、evidence 和存在的 self-exit receipt，并输出回滚结果。这些记录不含 Profile/凭据。review 和构建目录保留供复核，主会话可后续单独处理。旧的、已被时基修复替代的 review 已保留为 `/private/tmp/kuro-lifecycle-a-review-before-clock-fix`，不得安装旧包。
