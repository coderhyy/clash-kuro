# macOS 人工验收入口

Status: ready-for-human
Blocked by: 用户明确开始并安排同机系统状态操作窗口

2026-11-04。本轮只准备资料、核对源码和只读校验安装包。用户明确说开始前，不挂载／安装 dmg、启动 App、读取个人数据或代理／登录项基线、修改系统设置、注销或关机。其他 agent 可继续独立代码和 mock 验证。

## 有效安装包与预计耗时

- **本轮 App 包**：`/tmp/clash-kuro-acceptance-9990da6/kuro-macos-arm64/clash-kuro-0.1.0-arm64.dmg`，macOS arm64，App版本0.1.0。
- 来源：[CI 41774486923](https://github.com/coderhyy/clash-kuro/actions/runs/41774486923)，macOS和Windows双绿；[草稿PR #3](https://github.com/coderhyy/clash-kuro/pull/3)依赖PR #2，均未合并。
- 源码提交：`9990da69c565cef973e8560636fd2fb68fddbf15`。下载后的两份`source-commit.txt`与CI headSha一致；本节及后续票据提交只记录结果，不把它冒充构建来源。
- **App SHA256**：`df1116f64e4719e11135442bc24b4a08b08b36ea0ae4bc57f2314ce6fd1ba130`。已与CI `SHA256SUMS`逐字核验，`hdiutil verify`退出0、checksum VALID；未挂载或启动这个CI包。
- 备份验收预计**20–30分钟**；登录项预计**15–25分钟，含两次注销/登录**。先完成Backup与恢复，再单独安排登录项；TUN另排。原App/数据保存与环境恢复另留时间。

只读复核命令（不挂载、不启动App）：

```sh
shasum -a 256 /tmp/clash-kuro-acceptance-9990da6/kuro-macos-arm64/clash-kuro-0.1.0-arm64.dmg
hdiutil verify /tmp/clash-kuro-acceptance-9990da6/kuro-macos-arm64/clash-kuro-0.1.0-arm64.dmg
```

摘要不符、文件缺失或verify非零时停止。`/tmp`可能被清理，正式开始前可复制原包、source-commit和SHA256SUMS到用户选择的私有保存目录，再核验副本。`2617cf9`及更早包仅保留历史，不用于验收本轮代码。

**禁用helper包仅供审阅，不安装到本次Backup/登录项环境：**`/tmp/clash-kuro-acceptance-9990da6/kuro-macos-helper-disabled-arm64/dist/kuro-tun-helper-disabled-0.1.0-arm64.pkg`；SHA256 `1a5711bfd26228d715d1d52b689bb479525457246d1a9429019cd5259b141333`。同一CI/源码提交，pkg摘要、helper.lock、manifest与pkg.json身份一致。它是fresh-only disabled-service候选，真实TUN start关闭，完整鉴权、root配置/broker、网络owner/lease/恢复与升级尚未完成。安装后服务socket未激活，App会保守显示unknown并拒绝普通网络写入，不能把它当可用TUN安装包。本轮仅生成/解包检查本地候选的脚本和BOM，从未执行Installer或脚本。

本机未进行安装、卸载、服务启动、真实代理/路由/登录项变更或注销。Windows CI沿用隔离runner既有WinINet备份/恢复验证，其通过不替代用户机器验收。

## 开始后先保存的内容

以下个人基线读取和保存均等用户明确开始后执行。证据保存在用户选定的私有目录，放在仓库外；仓库只记录提交、摘要、通过／失败和脱敏结论。

| 保存项 | 内容与用途 |
| --- | --- |
| 现有 App | 实际安装路径、版本、签名信息、可执行文件和 app.asar SHA256；覆盖安装前保留旧 App 的可恢复副本，不同时运行两个副本 |
| 产物与机器 | 新 dmg 路径／SHA256、CI／完整 commit、macOS 版本、安装位置、验收开始时间；安装后记录新 App 版本和签名检查结果 |
| 原始 App 数据 | 原始 Settings、所有 Profile 原文及 Active Profile、Override、语言；已有安全导出则保留原始 JSON。冷备份需先正常退出 App 并确认 App／其 Core 已停止，不能运行中盲拷作为一致性备份 |
| System Proxy | 对每个会受影响的网络服务记录 HTTP、HTTPS、SOCKS 的启用状态与 host/port；PAC 启用状态及 URL、自动发现开关、bypass／排除域名列表；如有代理认证，只在本地私密保存，不放日志或截图 |
| 开机自启 | App 内开关、系统登录项是否存在／启用／需批准，保存开始前状态，供最后恢复 |
| 测试材料 | 两份独立受控 Profile，不使用生产订阅密钥；有效 Backup、故意破坏语法的 JSON 副本、含非法 Override 的独立副本；有效文件始终原样保留 |
| 结果与恢复 | 新生成的 `backups/pre-import-*.json`、必要截图、每阶段开始／结束时间、观察结果和恢复核对；截图隐藏订阅地址、密钥、PAC URL 等敏感内容 |

源码 `apps/desktop/src/main/index.ts` 使用 `join(app.getPath('userData'), 'data')`，未覆盖 userData；产品名为 `Clash Kuro`，README 的 macOS 默认目录是 `~/Library/Application Support/Clash Kuro/`。因此默认业务数据目录为 **`~/Library/Application Support/Clash Kuro/data/`**，包含 `settings.json`、`profiles/`、`override.yaml`（如有）和 `backups/`。开始后确认本机实际安装产物的数据位置，再备份；路径不符时暂停核对，不能凭目录名覆盖数据。

导出的 Backup 不含 Runtime Config、pid、Geo 数据或开机自启状态，不能替代系统代理／登录项基线。冷备份保留原件供恢复核对，不把旧 `core.pid`、Runtime Config 或进程身份直接恢复到运行中的新实例。

开始后先核对是否已有其他工具管理系统代理。当前 macOS `clearSystemProxy()` 对所有启用的 network service 关闭 HTTP／HTTPS，未逐项核验归属；`setSystemProxy()` 也会写这些服务的端点和 bypass。因此发现其他工具代理或归属不明时，先暂停全部网络写入步骤，包括可能触发清理的正常退出、停止 Core、Backup 导入和注销；与用户确认可隔离的测试窗口及逐项恢复方案，再继续。保留原状态，不自动覆盖或替用户关闭其他工具。此检查在用户开始后执行，本轮没有读取真实代理配置。

## 阶段与通过／停止条件

主会话一次只协调一项会改代理、登录项或网络状态的验证。任何阶段异常都先保存脱敏结果并暂停后续步骤；恢复使用已保存基线，由主会话协调，不通过反复重试、删除数据或改权限扩大实验。

### A. 基线与安装准备

用户确认开始、保存其他工作后，记录上表基线并先通过代理归属检查；有其他工具代理时按上段暂停协商。需要冷备份时，确认可安全执行清理后从托盘正常退出，确认 App／Core 已停止后备份；保存退出前代理状态与正常退出后变化。主会话确认没有其他系统状态实验，用户再安装新包并检查安装后签名／版本。

通过：原 App、业务数据与系统设置均有可恢复记录，代理归属和可恢复的测试窗口已明确，安装产物与摘要一致。停止：数据路径或运行进程归属不明、备份不完整、存在其他工具代理尚未协商、代理原状态无法恢复、签名／安装失败。此阶段未通过不开始替换 Profile 或启用代理。

### B. Backup，预计 20–30 分钟

按 [Backup 02](../backup/issues/02-backup-real-device-verification.md) 操作：用受控 Profile 与有效 Override 建立测试数据；分别看中英文警告及取消路径；导出并保留有效文件；变更测试数据后导回，观察自动重启与真实代理关闭；再检查坏 JSON／非法 Override 拒绝。保留 pre-import 文件和关键截图，随后恢复原始业务数据及代理。

通过：取消无改动；导出内容完整且权限为 0600；有效导入恢复数据／语言／Override，仅有一个重启后的 App，旧代理端点已关闭，pre-import 对应导入前状态；坏文件不会修改数据或重启。Active Profile 可按原规则在重启后自动启动 Core，不能要求一直停止。

停止：代理仍指向已停止的 Core、出现两个 App、导入后原文不一致、缺失 pre-import、坏文件改变数据，或任何恢复报错。记录错误后先恢复基线；没有恢复核对就不进入自启阶段。

### C. macOS 开机自启，预计 15–25 分钟

按 [自启 02](../launch-at-login/issues/02-macos-real-device-verification.md) 操作。需要 Active Profile 观察时使用独立受控 Profile，并在本阶段结束恢复。打开开关，必要时在系统设置批准；回 App 确认状态已启用。第一次真实注销／登录应自动进入 Tray Mode，无主窗口和 Dock 图标，托盘可用，Core 按 Active Profile 启动、System Proxy 不重开。然后从系统外部关闭登录项，回 App 确认刷新，再在 App 内确认关闭，第二次注销／登录应不启动。最后普通手动打开应显示窗口。

通过：注册／批准／状态回读与上述两次登录观察均符合预期，普通手动启动正常。停止：注册报错、一直 not-found／需批准、开关与系统不一致、开启后不启动、关闭后仍启动、登录时出现窗口／Dock 或代理自动重开。保存结果并恢复原登录项状态，勿改签名机制或反复注销碰运气。

### D. 收尾与关闭票

按开始前记录恢复原业务数据、HTTP／HTTPS／SOCKS／PAC／自动发现／bypass 与登录项状态，核对当前 App／Core 和代理端点；保留有效备份、pre-import、私有证据与旧 App，直到用户确认恢复完成。两张原票分别追加精确产物、每步结果和恢复结果；只有各自标准都满足才关闭票。

通过：原有工作环境恢复，证据可对应到本次 CI 产物。停止：任一数据或系统状态不确定，保留票为 ready-for-human／失败待处理。**原始 JSON、Profile、PAC／代理认证、含密钥日志和未脱敏截图不上传，不提交仓库。**
