# 调研：Windows System Proxy 立即生效

Status: resolved
Type: research

和 01 同时做。只查资料、写小实验（放在仓库外），不改仓库代码。结论追加在本文件 `## Answer` 下。

## 要回答

- 不引入 Node 原生模块，怎样设置当前用户的代理并让已打开的程序立即生效（`InternetSetOption` 通知）。候选：PowerShell 调 WinINet、小 helper exe、其他。
- 每个方案是否需要提权、耗时、是否被杀软拦截、如何打包进安装包。
- 如何读取当前代理，用于“启动时只清理指向本应用 mixed-port 的代理”。
- 推荐方案及其在 `Platform` 接口下的调用方式。

## Answer

调研日期：2026-10-30。**推荐随包分发、按当前用户运行的独立 Win32 helper exe，由主进程 spawn；不是 Node 原生模块，也不是提权服务，符合 ADR-0011。** 独立按微软 API 文档实现，不引入参考项目代码。

证据范围：下文 API 行为有官方文档依据，参考实现有固定版本源码依据；本机为 macOS，**没有 Windows 功能、权限、性能、杀软或安装包实测**。所有速度比较都是工程预期，不是测量结果；未编译 helper、未执行修改代理的实验。资料临时文件仅在 `/tmp/kuro-02-research/`。

### 先限定“立即生效”

- WinINet 的 `InternetSetOption(NULL, INTERNET_OPTION_SETTINGS_CHANGED=39, NULL, 0)` 通知设置变化，文档明确是在后续 `InternetConnect` 时检查；`INTERNET_OPTION_REFRESH=37` 使代理数据重新读取。`INTERNET_OPTION_PROXY_SETTINGS_CHANGED=95` 则专门通知 WinINet 实例更新代理，buffer 为 NULL、长度为 0 时通知所有可用实例。[1]
- 这不是强制所有程序切换流量的 API：采用系统代理并响应变化的客户端可在后续请求使用新设置；已有 TCP/CONNECT/WebSocket 不保证迁移，自带代理、忽略系统代理或缓存设置的程序可能需重建连接/重启。WinHTTP 与 WinINet 是不同栈，不能拿本方案承诺 WinHTTP 服务、所有 Electron/Node 请求都会跟随，更不能用需管理机器配置的 `netsh winhttp` 替代当前用户设置。[1][3]
- 首选正式的连接级 API：`InternetSetOptionW(NULL, 75, &optionList, sizeof(optionList))`，设置 `FLAGS / PROXY_SERVER / PROXY_BYPASS`；完成后通知并刷新（建议 `95 → 37`，逐项检查返回值；`39 → 37` 是另一条常见通知路径，不必全部叠加）。微软明确不建议应用直接改其底层注册表存储。[1][2]

### 三种方式比较

| 方式 | 可行性 / 用户权限 | 耗时（均未实测） | 安全软件 / 策略 | 打包与连接覆盖 |
| --- | --- | --- | --- | --- |
| PowerShell + `Add-Type` / P/Invoke | 可行；普通交互用户可写自己的代理，无需 UAC。既可写 HKCU 后调 39/37，也可封送结构调 75；推荐后者以处理连接级设置 | 每次新建 Windows PowerShell 5.1 进程要加载 CLR、命令模块、编译 C# 和 JIT；`-NoProfile` 只能去掉 profile 开销，不能消除冷启动和编译。预期慢于小型原生 helper；没有可信的本场景毫秒数 | Windows PowerShell 5.1 的 `Add-Type` 会编译 C#，可能涉及编译器子进程/临时文件，最终程序集可在内存；脚本块经过 AMSI。EDR 可能审查 Electron → PowerShell → 编译器/PInvoke 的行为链，不能断言必拦或必放。ConstrainedLanguage 禁止任意 C#/Win32 API；脚本执行策略也可能阻止 `.ps1`，`-ExecutionPolicy Bypass` 不覆盖组策略、AMSI、WDAC/AppLocker [4][5] | 系统自带 `powershell.exe`，不随包带解释器；`.ps1` 经 `extraResources` 放资源目录。仅通知不会扩展覆盖范围；调 75、按 RAS 名逐个设置才覆盖相应拨号/VPN |
| 独立 helper exe（C/Rust/Go） | 可行；同一用户 token 调 WinINet，无管理员权限；manifest 用 `asInvoker`，不安装服务。兼容 Electron ABI，与禁 Node 原生模块不冲突 | 启动 exe + 系统 DLL/API，无 PowerShell/CLR/C# 编译开销，预期最稳定；安全扫描、RAS 枚举仍可成为长尾。精简 C 最接近“几十 KB”；Rust 依链接配置而异，Go 自带 runtime，不能预设只有几十 KB | 避开 PowerShell/AMSI 脚本路径，不等于绕过杀软。未签名、低信誉 PE 仍可能被 Defender/EDR/应用控制拦截；SmartScreen 对下载程序/安装器有信誉检查，但不能推断每次内部 spawn 都弹 SmartScreen。MVP 不签名（ADR-0010），须接受此交付风险；以后需分别签主程序、helper 和安装包 [6] | `extraResources` 带架构匹配的 exe，资源目录外置于 ASAR；可完整实现 LAN + RAS 的 set/get/条件 clear [7] |
| `reg.exe` 只写 HKCU，不通知 | 能持久写入 `ProxyEnable`（DWORD）、`ProxyServer`、`ProxyOverride`（字符串）；通常不用管理员。**不满足已开程序及时更新的要求**，只能作为手动诊断手段 | `reg.exe` 无 CLR/编译开销，但多项写入通常需多个进程且非事务；命令快不等于生效快，客户端刷新时间无保证 | 系统工具无新增未签名 exe、无 Add-Type；EDR 仍能检测代理注册表变更，企业策略仍可能拒绝/覆盖，不能说安全软件无影响 | 不打包 `reg.exe`，用系统绝对路径。只写顶层键不能可靠覆盖 `Connections` 下拨号/VPN 的连接级配置，不应自行拼二进制 blobs；加通知就已不再是此方案 [2][8] |

共同权限边界：上述“不需管理员”只指当前用户、未被策略锁定的 WinINet 配置；企业强制代理、注册表 ACL 或应用控制可能让操作失败或不成为有效设置。不要自动提权、修改 HKLM 或试图覆盖组织策略，应保留错误并提示手动处理。安装器是否为 all-users 而提权，是另一回事；不要在提权的安装器/服务账户中代写用户代理。

PowerShell 若用于验证，应调用系统的 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -File <资源脚本> ...`，检查退出码并输出 JSON；不默认更改全机执行策略，也不把 bypass/host 拼接成可执行 C# 或 shell 字符串。若显式选择进程级 `-ExecutionPolicy Bypass`，应说明它的局限，不作为对抗企业策略的兼容措施。[4][5]

### get 与“只清理本应用”的契约

1. **读取优先用同一 helper 的 `InternetQueryOptionW(NULL, 75, ...)`**：返回 LAN 和每个 RAS 连接的原始 flags、proxyServer、bypass、PAC URL（保留 auto-detect/auto-config 标志），而非压缩为一个 `enabled/host/port`。查询返回的字符串按 API 要求 `GlobalFree`；W 版接口和 UTF-16 处理中文连接名。[2]
2. PowerShell 可 P/Invoke 同样读取；若只是 LAN 诊断，也可 `Get-ItemProperty` 后 `ConvertTo-Json`。`reg.exe query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer`（另查 ProxyEnable/ProxyOverride/AutoConfigURL）能读顶层值，但输出是文本、需处理缺失值/类型/编码，且不能代替 per-connection 查询。[8]
3. 清理前，在 helper **本次执行内重新读每个连接**。仅当手动代理标志开启，且服务器严格匹配应用持久记录的 `127.0.0.1:<mixed-port>`，才清除该连接的 `PROXY_TYPE_PROXY` 位；保留其它 flags、PAC/WPAD、bypass 和不相关配置，必要时在没有其它代理方式时保留 DIRECT。禁用手动代理无需删整棵注册表或清空所有字段。关闭后通知、刷新并回读；读取失败不当作“未开启”。
4. `ProxyServer` 可以是单一 `host:port`，也可以是 `http=...;https=...;socks=...`。按端点解析后精确比较，不用 substring、不只看第一个/http 值。保守规则：单值完全相同，或协议列表所有端点均指向本应用时才禁用；混有别人的端点或格式不认识就保留并提示，绝不整连接误关。`localhost`、`::1` 不自动等同 `127.0.0.1`。端口变更时应使用上次应用写入的端点记录，否则清不掉旧端口。
5. 端点匹配不是所有权证明：另一客户端恰好使用同一端口时无法区分；Windows 也无跨进程代理配置的 compare-and-swap，读后写前仍存在外部竞争。这是需求的已知限制，不应声称能安全恢复任意先前代理。此处只做条件清理，不增加通用备份/恢复功能。

### 拨号 / VPN

`INTERNET_PER_CONN_OPTION_LISTW.pszConnection=NULL` 仅表示默认/LAN，不是“全部网络”。用 `RasEnumEntriesW(NULL, NULL, ...)` 枚举当前可见的用户及 AllUsers 电话簿条目，再以每个名称分别 query/set；不需要修改电话簿本身。set、get、clear 必须使用同一覆盖范围，clear 逐连接判断归属，不能因 LAN 属于 Clash Kuro 就关闭全部 VPN 代理。[2][9]

这覆盖的是 **Windows RAS 连接的 WinINet 代理配置**，不覆盖所有第三方 VPN 的独立代理、路由/TUN、组织下发策略。运行后新建的 RAS 条目也不会被此前一次枚举自动设置，应在后续重设（如唤醒）重新枚举。逐连接修改非事务：即使某项失败，也应对已改项发送通知，返回每项状态/部分失败，不宣称整体成功；不盲目重试覆盖用户的后续修改。

### 参考项目（只总结思路）

- 本地 cvr `src-tauri/Cargo.toml` 使用 sysproxy git main + `guard` feature；根 `Cargo.lock` 锁到 **`89ad876a0942c049ae72e1472f9fc3ed62023c5e`**。该版本 Windows 实现：调 75 设置 LAN，再枚举 RAS 逐连接设置，最后通知 **95 + 37**（不是 39 + 37）；getter 则读 HKCU 顶层键、从协议列表优先挑 HTTP。可借鉴 API 顺序，**不能借此 getter 判断所有连接归属**。其 unset 将 flags 改为 DIRECT，会一起关闭自动代理，因此不能照搬到 Clash Kuro 的条件清理。源码仍留有中文 RAS 名可能失败的提示，需 Windows 验证；Windows bench 只是占位程序，不能作为耗时证据。[10]
- 本地 cp `src/main/sys/sysproxy.ts`（commit `6e1e986351dcd434c9084134c31b277fecfd8d59`）：Windows 走导入的 `sysproxy-rs` 手动/自动切换，bypass 用分号；关代理时同时关自动与手动代理，而非 Windows 上 spawn PowerShell。这里只借鉴分号格式与平台隔离，**不引入其 Node binding，不采用无条件清空自动代理**。[11]
- 许可证校核：cvr/cp 为 GPL 参考项目，遵守 ADR-0006，不拷代码也不逐行改写。另，锁定版本 sysproxy-rs 仓库自身的 `LICENSE` 实际标为 **MIT**，并非据依赖者的 GPL 就能推导它也是 GPL；本次仍仅总结思路，不复制实现。[10]

### 推荐落地：Platform → 主进程 → helper

共享包只声明异步 `setSystemProxy({host, port, bypass}) / clearSystemProxy() / getSystemProxy()`；具体进程调用仅在桌面主进程（ADR-0001/0004）。最小独立 C helper 使用 WinINet + Rasapi32，构建时链接系统库、避免要求用户另装运行时，按实际 Windows 发布架构生成产物，不常驻、不提权。

下列是**建议协议，尚无实现**；参数作为 argv 数组，`shell:false`、`windowsHide:true`，不用 `cmd.exe /c`：

```text
getSystemProxy()
  spawn(<resources>/bin/kuro-sysproxy.exe, ["get"])
  -> JSON {connections:[{name:null|RAS名称, flags, proxyServer, bypass, autoConfigUrl}]}

setSystemProxy({host:"127.0.0.1", port, bypass})
  spawn(helper, ["set", "--host", host, "--port", String(port),
                 "--bypass", bypass.join(";")])
  -> LAN + 当前 RAS：flags=DIRECT|PROXY，server=http=host:port;https=host:port
  -> 通知/刷新/回读，JSON 返回逐连接结果

clearSystemProxy()
  spawn(helper, ["clear", "--expected-server", "127.0.0.1:<上次写入的mixed-port>"])
  -> helper 内逐连接重新读取、精确匹配后仅关本应用手动代理；不匹配即不改
```

set 是用户明确启用 Clash Kuro 手动代理，需说明它会在目标连接上停用原 PAC/WPAD（不删其 URL）；clear 只取消当前可确认属于 Clash Kuro 的手动设置，**不承诺恢复启用前的 PAC/WPAD 状态**。bypass 使用 Windows 通配符/`<local>` 语法，不把 CIDR 当成普遍支持的格式。主进程与 helper 两侧均校验 host（MVP 固定 127.0.0.1）、端口 1..65535、字符串长度/控制字符，参数不解释成代码。

打包沿用 electron-builder **v26** 的 `win.extraResources`，例如：

```yaml
win:
  extraResources:
    - from: resources/win/${arch}/kuro-sysproxy.exe
      to: bin/kuro-sysproxy.exe
```

构建输入在项目内，打包后路径为 `path.join(process.resourcesPath, 'bin', 'kuro-sysproxy.exe')`，不放进 `app.asar`、不依赖 PATH；开发环境用开发资源绝对路径。PowerShell 方案也可用同一机制带 `.ps1`；reg.exe 方案无需带系统二进制。[7]

同一主进程串行执行代理操作；设有限超时、stdout/stderr 上限、退出码及 Win32 错误传递。超时视为**结果未知**，先 get 核对，不盲目重放 clear/set；通知失败也要报告“设置可能已写入”。退出前等待清理但不无限阻塞关机。helper 被拦截时提示用户手动改代理，**不静默退回到不通知的注册表写入**。

### Windows 验收缺口

发布前需在普通用户 Windows 10/11 上验证：已打开的 Edge/Chrome 与 WinINet 客户端后续请求、已有长连接、WinHTTP 不随动边界；LAN/已有及新建 RAS（含中文名）、混合协议与他人端点、PAC/WPAD、端口变化；策略拒绝、EDR/Defender、未签名 NSIS 安装与资源路径、各发布架构；部分写入/通知失败与退出超时。性能分别测全新进程的 PS 空命令、PS Add-Type+API、helper get/set、reg.exe，记录冷/热 p50/p95 和杀软状态，不用 macOS 测量或占位 bench 充数。当前没有可提交的 Windows 耗时或成功率数字。

### 引用

1. Microsoft：[WinINet Option Flags（37/39/75/95）](https://learn.microsoft.com/en-us/windows/win32/wininet/option-flags)。
2. Microsoft：[设置/读取 Internet options、per-connection 示例和 GlobalFree](https://learn.microsoft.com/en-us/windows/win32/wininet/setting-and-retrieving-internet-options)；[pszConnection 的 LAN/RAS 含义](https://learn.microsoft.com/en-us/windows/win32/api/wininet/ns-wininet-internet_per_conn_option_listw)。
3. Microsoft：[WinHTTP vs. WinINet](https://learn.microsoft.com/en-us/windows/win32/winhttp/winhttp-vs-wininet)。
4. Microsoft：[Windows PowerShell 5.1 Add-Type（编译与 P/Invoke）](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/add-type?view=powershell-5.1)；[PowerShell 安全特性 / AMSI](https://learn.microsoft.com/en-us/powershell/scripting/security/security-features)。
5. Microsoft：[语言模式 / Add-Type 限制](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_modes)；[执行策略及组策略优先级](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies)。
6. Microsoft：[SmartScreen 信誉、签名与下载检查](https://learn.microsoft.com/en-us/windows/security/operating-system-security/virus-and-threat-protection/microsoft-defender-smartscreen/)。
7. electron-builder：[v26 extraResources、FileSet / 架构宏](https://www.electron.build/v26/contents.html)；Electron：[process.resourcesPath](https://www.electronjs.org/docs/latest/api/process#processresourcespath-readonly)。
8. Microsoft：[reg query](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-query)；[reg add](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/reg-add)。
9. Microsoft：[RasEnumEntriesW](https://learn.microsoft.com/en-us/windows/win32/api/ras/nf-ras-rasenumentriesw)。
10. sysproxy-rs 固定版本：[Windows 实现](https://github.com/clash-verge-rev/sysproxy-rs/blob/89ad876a0942c049ae72e1472f9fc3ed62023c5e/src/windows.rs)、[Windows bench 占位](https://github.com/clash-verge-rev/sysproxy-rs/blob/89ad876a0942c049ae72e1472f9fc3ed62023c5e/benches/windows_behavior.rs)、[MIT LICENSE](https://github.com/clash-verge-rev/sysproxy-rs/blob/89ad876a0942c049ae72e1472f9fc3ed62023c5e/LICENSE)；本地 cvr 的 manifest/lockfile 只读核对。
11. Clash Party：[固定版本 sysproxy.ts](https://github.com/mihomo-party-org/clash-party/blob/6e1e986351dcd434c9084134c31b277fecfd8d59/src/main/sys/sysproxy.ts)（本地 clone 只读观察，仓库地址已核对 origin）。
