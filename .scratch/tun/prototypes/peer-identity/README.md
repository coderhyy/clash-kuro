# 无特权 macOS peer identity 实验

2026-11-04：本机 arm64、CommandLineTools macOS SDK 编译执行通过。仅创建临时 Unix socket 和两个普通用户子进程，无 root、LaunchDaemon、TUN 或代理操作。

```sh
mkdir -p /tmp/kuro-peer-proof
clang -Wall -Wextra -Werror -framework Security -framework CoreFoundation -lbsm .scratch/tun/prototypes/peer-identity/peer-identity.c -o /tmp/kuro-peer-proof/trusted
clang -Wall -Wextra -Werror -DVARIANT='"other"' -framework Security -framework CoreFoundation -lbsm .scratch/tun/prototypes/peer-identity/peer-identity.c -o /tmp/kuro-peer-proof/other
/tmp/kuro-peer-proof/trusted /tmp/kuro-peer-proof/other
```

结果：同 UID、内核 peer PID 与实际子进程一致；`LOCAL_PEERTOKEN` → `kSecGuestAttributeAudit` → `SecCodeCheckValidity` / `kSecCodeInfoUnique`，固定原生可执行身份接受，另一个 ad-hoc 可执行身份拒绝。两个产物经 `codesign -dv` 确认为 linker-signed ad-hoc、无 TeamIdentifier、无 sealed resources；没有付费证书或公证参与。首次沙箱执行在 bind 被 EPERM 拒绝；经工具权限审查后以当前普通用户重跑通过，并非提权执行。测试自身禁止 euid=0。

此实验只证明本机原语可用。允许身份取自测试 server 自身；生产允许清单必须来自管理员确认并写入受保护位置的安装记录，绝不能信任请求方自报 hash/PID。动态检查不等于发布者鉴别，也不覆盖 Electron 的 app.asar、加载的脚本/库、调试注入、资源替换、运行中修改、客户端进程退出后的身份复用、消息转发或同一可信程序的恶意调用。不同编译宏产生不同 code identity，不是对恶意篡改的完整攻击测试。

生产入口须将内核 peer 身份、受保护安装树与完整资源校验、允许的启动方式/构建加固、会话绑定及逐请求有限操作校验组合验证；失败或证据不完整时拒绝。现有 `hardenedRuntime: false` 的 Electron 包不能据本实验认定可作为 root RPC 的可信客户端。原型不被生产打包，不是安装器或认证服务实现。
