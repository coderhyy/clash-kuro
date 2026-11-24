# 固定 Core 控制实验：离线源码核对

2026-11-05。范围仅固定配置、argv、workdir、资源路径、环境与 Unix 控制 API；未运行 Core / `-t`，未改源码、安装或系统网络。结论不能代替下一冻结产物的真实执行授权。已有 normal 结果见 [639c64f 记录](evidence/core-control-execution-639c64f/RESULT.md)：Core 在控制就绪前自行退出 1，stdio 为 `/dev/null`，确切原因仍未知。

## 一手源码身份

本地 `/private/tmp/kuro-tun-mihomo-tag.json` 将 `v1.19.33` 解析到提交 `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`；`/private/tmp/kuro-tun-mihomo-tree.json` 的 `sha` 与该提交相同。本次对每份缓存原始字节计算 Git blob SHA1（`SHA1("blob " + length + NUL + bytes)`），全部与该 tree 对应条目一致。新增缺失源码只经 agent-reach 的 GitHub CLI 读取该固定提交，没有依据文件名推定版本。该核验绑定源码提交，不证明发布二进制可复现构建。

| 固定提交路径 | 已匹配 tree 的 blob SHA1 |
| --- | --- |
| `main.go` | `972caf8bc0f4b4f74ee9077e8dfd0123aa14368c` |
| `config/config.go` | `cc8c1016703c21f502cfb4151f5f0131bbb3be81` |
| `config/initial.go` | `61d128956e10e2cb848dde70d1810771bc85bc54` |
| `hub/executor/executor.go` | `796face2f1b9eb498035ce8d2cf72e62ea5a0b0c` |
| `adapter/outboundgroup/selector.go` | `2fea75032ab6b2ea0959d7515eb3501105b0a7fb` |
| `hub/hub.go` | `29ddd2e61cf56fed59518b60b3d12641ec3016b7` |
| `hub/route/server.go` | `6d37d4802bfe4e5caef8fc224479a1225c38ab8e` |
| `hub/route/configs.go` | `75c275630c2b0204caa6190a150278216c80d9fe` |
| `hub/route/proxies.go` | `e8623b52bbc024305ad891d6e90b5933ffbfca38` |
| `constant/path.go` | `f2463a4a235e7c10f24aaeb6ebadb1430b14d245` |
| `component/profile/cachefile/cache.go` | `89ce19170097af5ea8c031ab7893c873146120d2` |

## 明确可证的问题与边界

**成功 select 会触发 cache 初始化，`store-selected:false` 不保证没有 `cache.db`。** [proxies.go:98](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/hub/route/proxies.go#L98) 无条件求值 `cachefile.Cache().SetSelected(...)`；[cache.go:80–104](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/component/profile/cachefile/cache.go#L80) 先执行 `initOnce.Do(initCache)` / `bbolt.Open(C.Path.Cache(), 0666, ...)`，随后 `SetSelected` 才在第 34 行检查偏好。`Path.Cache()` 固定返回 `<-d>/cache.db`。这证明存在创建文件的调用路径；未实测磁盘创建或权限结果。原实验清理只接受 `config.json` / `core.sock`，因此未来成功切换后可能因已知额外文件而保守拒清。该问题已交 native agent 作仅实验内的有限修复，不扩生产 schema。

最小验收应包括：成功 select 的 fixture 创建 `cache.db`；只对本 owner、安全普通文件、单链接及已记录精确身份/摘要，在持有的直接 child 已 reap 后稳定复核再清退；同名 symlink、被替换文件、未知 sibling 必须保留/报错。不可仅把该名字加入无条件删除列表。此次历史失败尚未到 select，故该发现不是其退出原因。

**Unix controller 不验证配置中的 Bearer secret。** [server.go:251–295](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/hub/route/server.go#L251) 对 Unix 地址 Resolve、unlink、listen、chmod `0666`，使用 `router(cfg.IsDebug, "", ...)`；只有非空 secret 才装载 authentication。实验仍发送 Bearer，但不能把它作为 Unix 访问控制证明。实际边界是私有 `0700` work 祖先、socket 类型/owner/nlink/dev/inode 准入及持有 Core identity。固定绝对路径在该私有目录下，mkdtemp 固定六字符后缀下路径长度 52 字节，短于 Darwin `sun_path[104]`（含终止 NUL）；没有离线发现超长问题。普通用户同 UID 的恶意进程不因 `0700` 被隔离，不应宣称同 UID 完全安全。

Unix listen 失败仅记日志并 return，其自身不是源码中显式 `os.Exit(1)` 路径；不能据此推断历史早退。

## 配置、参数与环境核对

- 实验传入 `-d <absolute session-work> -f <absolute session-work/config.json>`，spawn 的 cwd 同一目录。固定 [main.go:60–77,130–174](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/main.go#L130) 声明这些参数，先 SetHomeDir，再 SetConfig / `config.Init`。`config.Init` 仅在目录/配置不存在时创建；实验预写非空 config，不存在必须另提供 `config.yaml` 的要求。
- `external-controller-unix` 是受支持 RawConfig 字段，`parseController` 原样保留，hub 将它传给 Unix server。TCP/TLS/pipe 地址为空，实验未启用 TUN/DNS/NTP/sniffer/iptables/tuic。`GET /version`、`GET/PATCH /configs`、`GET/PUT /proxies/{name}` 及写入 204 的调用形状与固定 route 源码一致；真实 HTTP framing/响应大小/500ms deadline 尚无 Core 通过证据。
- `dns.enable:false` 加 `nameserver:[]` 本身不触发“NameServer cannot be empty”：固定 [config.go:1415+](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/config/config.go#L1415) 的空 nameserver 检查要求 Enable；但 default-nameserver 无论 Enable 都必须非空/pure-IP，实验 `127.0.0.1` 满足这个源码条件。这里只是解析形状，未证明没有瞬时查询或 socket。
- `DIRECT` / `REJECT` 是 `parseProxies` 内置代理，实验 select 组引用它们、`MATCH,DIRECT` 没有缺失代理的离线证据。没有 GEO 规则/provider/UI 资源引用；本次覆盖的解析路径未发现要求先提供 GeoIP/GeoSite 文件的直接条件。**未覆盖所有传递依赖/package initializer，不能宣称所有资源访问或联网均不存在。**
- Core spawn 环境只有 `PATH=/usr/bin:/bin` 和 `LANG=C`，不继承 HOME、XDG、CLASH override、SAFE_PATHS 等。固定 [constant/path.go:28–53](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/constant/path.go#L28) 在 package 初始化时调用 `os.UserHomeDir()`；错误时退回 `os.Getwd()`，拼 `.config/mihomo`，这里只读 Stat，不 fatal。随后 main 按 `-d` 覆写 `Path.homeDir`。因此 **该已审初始化路径未显示 HOME 缺失是必然退出条件**；不能从中推出其他依赖不需要 HOME。当前本地 Go 1.27.3 的 `os.UserHomeDir` 实现也明确在 Darwin HOME 缺失时返回 error；它不是发布 Core 精确工具链证明（仓库 go.mod 仅 `go 1.20`）。新诊断应记录环境是否存在，不为消除猜测而继承整个用户环境。

## 未证事项与下一步边界

历史 Core exit 1 原因仍未知，不能归因于 HOME、缺资源、DNS、Unix socket 或 config。完整固定发布二进制的启动、HTTP 控制/读取、NoIP 采样、正常停止和 EOF 需要新冻结候选与新授权。本核对没有运行 Core、`-t`、Go 包测试、系统网络或安装操作。

下一候选至少应保存有界、受保护的 Core stdio 与失败配置摘要/环境存在性诊断；先离线验证日志和上述 known-cache 清理，再请求有限执行。两次 NoIP FD 采样只能证明采样时刻，不能证明全生命周期无瞬时 IP socket。ESRCH 仅证明记录的直接 Core 进程不在，不证明脱组后代全停；原生产 gate、root/真实 TUN 验收限制均不变。
