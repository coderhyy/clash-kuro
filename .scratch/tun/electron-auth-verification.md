# Electron 长期有限授权入口：硬化候选实测

2026-11-04，本轮在用户授权和主会话审阅隔离入口后，构建并运行了下述 **独立候选**。它与后文历史 dist/DMG、任何 CI 包不是同一产物。本轮没有安装 App/helper、启动真实 Core/TUN、读取原有 Profile 或修改代理、DNS、路由、登录项。

## 持久证据归档

原始 runtime 成功矩阵、file-fuse 失败对照和 tamper 报告，以及对应的小型 marker 源码/库和 entitlement fixture，已原样复制到 `.scratch/tun/evidence/electron-candidate-20261104/`，未复制整个 App 或 Chromium userData。归档时未重建、重签或启动候选。[sources.json](evidence/electron-candidate-20261104/sources.json) 记录原始临时路径、字节数及 SHA256；[SHA256SUMS](evidence/electron-candidate-20261104/SHA256SUMS) 覆盖最初 11 个归档文件及主会话追加的组合包核验证据（不含清单自身），逐项复算通过。三个原始报告的摘要与下文既有记录完全相同。原始 JSON 内的临时路径保留不改，读者应通过这里的持久链接读取证据。

## 冻结候选身份

完整 App 路径：`/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/electron-runtime-candidate/mac-arm64/Clash Kuro.app`。版本 `0.1.0`，Electron Framework `45.1.0`，arm64，ad-hoc，未 notarize。候选尚在普通用户工作区，**不具备安装后受保护路径的保证**。主会话另行准备的安装目标为 `/Library/Application Support/Clash Kuro/Client/Clash Kuro.app`，不能把构建目录当该安装身份。

```json
{
  "format": 2,
  "cdhash": "dec6d36f1109ea4970c5c79cbff493cdaee24477",
  "executableSHA256": "b227d91e80f33cb0d84c8c6edf416b897f6771360d19fd8431e3268757813f99",
  "infoSHA256": "c6ee4596dcdaebb3c624421de67937d7b62ad1be281a0ad96996186d2aba3ab8",
  "asarSHA256": "97749c5d4d67382480b9e2e7da76f728274aa6a3f7bad5fe34b2db2a46aa5a20"
}
```

`verify-macos-app.cjs` 对该包实际执行 deep/strict seal、ASAR raw-header hash 与签名 Info 元数据比对、fuse 读回；再枚举 15 个实际 Mach-O，全部包含 `adhoc,runtime`。主执行 entitlement 精确为 `allow-jit:true`、`disable-library-validation:true`；其余 Mach-O 只允许这两个键的 true 子集，没有 `allow-dyld-environment-variables`、`get-task-allow`、`allow-unsigned-executable-memory`。资源内普通 mihomo 的离线签名结果不表示其已运行或可替代 root Core 身份校验。

五项既有安全 fuse 保持生效：RunAsNode、NodeOptions、NodeCliInspect 均关闭，EmbeddedAsarIntegrity 与 OnlyLoadAppFromAsar 开启。`GrantFileProtocolExtraPrivileges` **保留 true**，原因有实际单变量对照：仅设 false 的候选能通过签名核验，但 `file://…/app.asar/out/renderer/index.html` 加载报 `ERR_FILE_NOT_FOUND`，而同一 ASAR 确有该文件且 extract 成功；恢复 true 后实际 renderer/CSS 正常。未为此新增 custom protocol 架构，不能宣称此 fuse 已关闭。

失败对照主执行 SHA256 `c94b31adc1aef9cf7c6f39483c590edf85cf9e02ab46ce016c290f16089806b6`，CDHash `c448af3677930aa2ff70332a39321f7d2f833017`；Info/ASAR hash 与上述最终包相同。失败证据 [原始 runs.json](evidence/electron-candidate-20261104/file-fuse-failure/runs.json)，SHA256 `d8f36c0825b8d469bf4f25c28d1f2c2f4e8246319773bf6fdcaa8fbae54736dc`。

## 实际隔离启动边界

packaged main 在正常 main、单实例锁和任何真实 Platform 构造之前，先检查 argv；只允许 `--hidden`、固定格式 PSN、以及降低能力的验证参数。未知参数拒绝退出 64。静态 imports 已检查为模块定义；真实平台、socket transport、Profile source、Geo 安装、更新 scheduler、helper client 均只在正常 main 的函数体内构造。Chromium 可能在 JS 前解析参数，所以 argv 单测不能替代以下实际 CDP 观测。

`--kuro-runtime-verification=<directory>` 只接收 canonical OS tmp 的直接子目录：固定前缀、全新空目录、非 symlink、当前普通用户所有、无 group/other 权限。提前切换 userData/sessionData/crash 目录，使用实际签名内 renderer/preload、IPC 和 AppStore；能力完全来自内存适配器，不构造真实 DesktopPlatform。Core/TUN、Core API、代理写、登录项写和 fetch 明确拒绝；stop/clear 只确认这个从未获得系统归属的内存模型。网络请求 allowlist 只有包内 `file://`，无 `devtools://` 特例。该参数不改变 helper 鉴权，也不是生产能力的 fallback。

生产与验证窗口均 `sandbox:true`、`contextIsolation:true`、`nodeIntegration:false`、`devTools:false`。正常生产 main 保留原 App 入口；本轮未启动该正常模式，不将内存 adapter 验证写成真实 Core 管理通过。

## 动态结果：14/14

普通用户运行 `node apps/desktop/scripts/verify-electron-runtime.mjs '<完整候选路径>'`；每个子进程独占新的空私有目录，20 秒失败终止、23 秒强制终止只针对自身子进程。五次成功启动都实际加载 renderer/CSS，走 preload IPC：读取 snapshot、修改 Language/Override、拒绝 Core/TUN/Login、在内存中 Backup 导出再导入并验证数据一致。验证脚本通过主进程持有的 webContents 执行这些无系统副作用调用，不使用 CDP；这是实际 UI 渲染/IPC 路径，尚非所有页面的人机交互验收。

| 场景 | 实际结果 |
| --- | --- |
| 正常隔离 UI/IPC + 内存 Backup | exit 0，报告与目录一致，renderer/CSS 存在，Command 结果符合拒绝能力模型 |
| `ELECTRON_RUN_AS_NODE=1` | 仍完成相同实际 UI/IPC，而非 Node 脚本模式 |
| `NODE_OPTIONS=--require=<外部marker>` | UI/IPC 通过，外部 marker 文件不存在 |
| `ELECTRON_RENDERER_URL=file://<外部marker>` | 仍加载签名内 UI/IPC，外部 marker 不执行 |
| `DYLD_INSERT_LIBRARIES=<临时已签constructor dylib>` | UI/IPC 通过，constructor stderr marker 未出现 |
| `--remote-debugging-port=<loopback临时端口>` | exit 64，进程存活期间每 5ms 连接采样均未成功，无 inspector/CDP listening 文本 |
| `--remote-debugging-pipe` | exit 64，fd3 重复发送 Browser.getVersion，fd4 无任何回复 |
| `--inspect=0`、`--inspect-brk=0` | 两例均 exit 64，无 inspector listening 文本 |
| `--js-flags`、`--renderer-cmd-prefix`、`--gpu-launcher`、`--no-sandbox`、外部 JS positional 参数 | 五例均 exit 64，无验证报告或外部 marker |

成功矩阵证据：[原始 runs.json](evidence/electron-candidate-20261104/runtime-pass/runs.json)，SHA256 `d0526ee15bb634cb17b659bd7c77f09ce5764d56c51c0b75333468989caefb89`。同一归档目录的 [result.json](evidence/electron-candidate-20261104/runtime-pass/result.json) 含最终 bundle hash，`runs.json` 保存逐次 argv、退出码、stdout/stderr、CDP 观测、实际 UI/IPC 报告。原始报告已按字节归档到持久仓库目录，内部临时路径保留为当时观测数据，不是当前读取位置；本记录中的摘要不能替代原始报告。报告 `realNetworkUsed:false` 指未构造/调用真实 Platform 网络能力，不是全 Electron 内核网络流量审计；探测器自身只连接 loopback CDP 端口。TCP 是采样观测，不是内核级完整可达性证明；没有将仅有进程退出当作 CDP 完全无法生效的证据。

源码回归：`runtime-verification.test.ts` 13/13；完整 desktop 421 passed、16 skipped（34 文件通过，1 skipped）；desktop typecheck 与两个验证脚本语法检查通过。build 和 afterSign 完成。没有执行真实 Core `-t`。

## 补充：冻结候选的实际离线篡改负例（3/3）

运行 `node apps/desktop/scripts/verify-client-tampering.mjs '<完整候选路径>'`，仅由普通用户复制到新私有临时目录，未运行任何 App、Core、dylib 或 helper。每个独立副本先通过现有 `macosClientPin` 与冻结输入一致性检查，完成后删除大副本，保留小型 evidence、原始工具诊断及 marker 源码/库；没有修改或重签原件，也没有更新安装 pin。

| 独立副本操作 | codesign / verify-macos-app 实际结果 | 身份结论 |
| --- | --- | --- |
| 在 ASAR 内 `out/main/index.js` payload 改一个字节，完整 archive header 原样不动 | 两者均拒绝，codesign exit 1：`a sealed resource is missing or invalid` | 仅 header 仍匹配不代表 payload 完整；外层资源 seal 捕获该次篡改。未运行运行时 ASAR integrity 负例 |
| 将实际 `Electron Framework.framework/Versions/A/Libraries/libffmpeg.dylib` 替换为本地编译且签名有效的 marker dylib，不执行 | 两者均拒绝，codesign exit 1，并定位 `Electron Framework.framework` 子组件 | 一个本身有效签名的库也不等于原 bundle 中受 seal 固定的资源 |
| 副本新增惰性文本资源，保留原 Info/ASAR、相同 runtime 与最小 entitlement，再合法 ad-hoc 重签外层 App | deep/strict seal 与 verify-macos-app 均通过；现有 `macosClientPin` 可派生结构合法 pin | 新 pin 与原 pin 比较明确不等，因此 seal 有效不能替代安装时固定身份 |

重签副本 CDHash `96d8190b6b1a89bf7f3fb872480a90e6e9938c9a`，执行文件 SHA256 `1b9e27e54739dca53905d32fd6912b06ac6b7ec0fcdfa89be76b52c800318713`。其 Info/ASAR SHA256 与冻结原件相同，仍因 CDHash/执行文件不同而不匹配原 pin。这是离线精确比较证据，没有启动 helper 或宣称已经完成真实安装 RPC 的动态拒绝。

原候选前后 pin 与上文完全相同；递归 611 条目录/文件/symlink 的模式、链接目标、文件内容摘要树 SHA256 前后均为 `a5b7285121ae042d869b294ef02b4357fbbd55827b00601c29315ca4019f5f54`。原件再次通过实际 deep/strict seal 与全部最小 entitlement/fuse 检查。原始报告 [tamper/result.json](evidence/electron-candidate-20261104/tamper/result.json)，SHA256 `fe29b171e0e3eb9aa9e3f628abe532329eb116c9e655f16675f9018323904203`。新增脚本语法检查通过，三个真实离线场景内置断言全部通过；无生产实现修改，不重复运行与该脚本无关的桌面测试。

## 仍未验证的边界

本轮结果支持继续验证受保护安装 App + audit/CDHash/完整资源 pin 的有限 RPC 候选，**不等于该安装鉴权或 TUN 已可用**。生产 helper 门禁由主会话保持。本轮未执行：安装路径保护/客户端 pin 实际授权、不同 binary 或重签 App 负例、ASAR/Framework 篡改启动负例、外部 V8 snapshot/所有 Chromium 启动前解析入口、SIGUSR1、全部 DYLD_LIBRARY_PATH/FRAMEWORK_PATH 变体、桌面快捷键/菜单逐项操作、生产模式真实 Core/helper/网络、Core utun/route/DNS 真机验收、正式签名或公证。DYLD constructor 单例和既有 C 阳性对照不能替代 Electron 全攻击面证明。未重打包、挂载或复用历史 DMG/CI 身份。

---

## 历史记录：硬化前 dist App 的离线核验

下文保留上一轮历史证据；其中“仅离线”“尚未 hardened”“尚未实现”等描述只对应旧产物与当时源码，不覆盖上文新候选及主会话正在完成的 installer/native 实现。

2026-11-04。维护者已接受安装时批准长期有限能力、日常开启不增加逐次原生弹窗。本记录核验现有 Electron 产物，支持继续验证 direct App 入口；不把它记为已可运行的 helper 授权方案。04/安全文档中早于该产品决定的逐次确认候选由主会话另行统一，本记录不修改这些文件。

**本轮仅离线读取，不重打包、不 mount DMG、不运行 Electron/App/Core，不安装服务、不改网络或系统设置。** 主会话独占实验 A。既有 C 探针的普通用户临时实验见下文，不能替代 Electron 动态验证。

## 精确产物与摘要

工作区 `/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro`。下列路径均相对此工作区；这是本机现有构建，不声明与当前源码或某个 Git commit 完全一致。

- App：`apps/desktop/dist/mac-arm64/Clash Kuro.app`，bundle ID `dev.kuro.desktop`，版本 `0.1.0`，arm64。
- Framework `CFBundleVersion`：`45.1.0`。此键来自实际 Framework Info.plist，非依赖声明推断。
- main/ASAR 修改时间约 `2026-11-04T14:44:02–09+0800`。当前副本 UID 501；它在用户工作区，不是已经通过 root 保护安装校验的 `/Applications` 副本。

| 对象 | SHA256 | 字节数 |
| --- | --- | ---: |
| `apps/desktop/dist/clash-kuro-0.1.0-arm64.dmg` | `4555bc6044842084ef1f3e4056745347610983c8d7ccdb3d46c78f3a4f368d00` | 150198614 |
| App `Contents/MacOS/Clash Kuro` | `9ba234337a2b46d97fc33e72764c592069f26e225751638494122445c747e88f` | 34800 |
| App `Contents/Resources/app.asar` | `5334fa5948ff6f6e8ca851fab09c57db4a0f5f99f057b1ed96060ee4d4cb9d0c` | 1438065 |
| App `Contents/Info.plist` | `b6ee0d218f4cecc58dfbd988ac77a4667113e34be1ae9ef8423b723d4587b45f` | 3835 |
| App `Contents/_CodeSignature/CodeResources` | `748795f5e4f4c422cef74e4e6b247f440035031171cdda8bc07675c94bdedeae` | 6776 |
| App `Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework` | `e24d14ae7fdfe1485014b72009b89ada72fb9c58a5eb5b2e1487d1e1a38fc476` | 206274448 |

DMG 仅取文件摘要，未挂载、未验证内部 App 与上述解包目录相等。本轮未下载或核验 CI 产物；dist App、该 DMG、CI 包是独立对象，不能互换 CDHash/摘要或把某一对象的通过结果套到另一对象。主执行 CDHash `15cf7794eaa2daf6a5dbf21376364e9074b16afb` 是代码身份标识，不是整个 bundle 的摘要或发布者证明。

## 离线通过项

执行 `node apps/desktop/scripts/verify-macos-app.cjs 'apps/desktop/dist/mac-arm64/Clash Kuro.app'` 成功；它调用 `codesign --verify --deep --strict`，读取实际 fuse，并检查签名内 ASAR integrity 元数据。未启动 App。

另从实际 ASAR 读取 raw header，单独复算 SHA256：`6f30d644a4a1c75d2143b3f49ea70a491107e37a0bc91227219f5d981d46fad8`，与 Info.plist `ElectronAsarIntegrity[Resources/app.asar]` 一致。该值是 **header** hash，不是上表完整 ASAR 文件 hash；CodeResources 的 `files2[Resources/app.asar].hash2` 则等于上表完整文件 hash。静态 seal 成功不证明运行期间没有外部注入。

实际 fuse wire：

| fuse | 实际值 | 当前意义 |
| --- | --- | --- |
| RunAsNode | disabled | 关闭 `ELECTRON_RUN_AS_NODE` 入口 |
| EnableNodeOptionsEnvironmentVariable | disabled | 关闭 NODE_OPTIONS 等 Node 环境入口 |
| EnableNodeCliInspectArguments | disabled | 本地 builder 文档明确涵盖 `--inspect` / `--inspect-brk` / SIGUSR1；不能由此推断 Chromium CDP 关闭 |
| EnableEmbeddedAsarIntegrityValidation | enabled | ASAR 运行时校验开关已设置，尚未做此包篡改启动负例 |
| OnlyLoadAppFromAsar | enabled | 主 App 搜索不回退到外置 app/default_app |
| EnableCookieEncryption | disabled | 本 App 无依赖此能力的授权机制 |
| LoadBrowserProcessSpecificV8Snapshot | disabled | 当前值记录，不据此认定任意 snapshot 参数安全 |
| GrantFileProtocolExtraPrivileges | enabled | 额外 file fetch/service worker/子 frame 权限尚未关闭 |

## 实际签名与 entitlement：尚未 hardened

离线枚举 bundle 内 15 个 Mach-O，`codesign --display --verbose=4` 全部返回 `flags=0x2(adhoc)`，**均没有 `0x10000` runtime flag**。主执行没有 TeamIdentifier。本机 SDK `Security/CSCommon.h` 定义 `kSecCodeSignatureRuntime=0x10000`，与当前产物状态一致。

主执行、四个 Electron Helper、`app_shim_loader`、`chrome_crashpad_handler`、`Squirrel/.../ShipIt`，以及普通 bundled mihomo 均携带以下 true entitlement：

- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

其余 Framework/dylib 未显示 entitlement。上述实际 entitlement 未显示 `allow-dyld-environment-variables` 或 `get-task-allow`。当前没有 runtime，所以**不能套用 hardened C 探针的注入拒绝结果**；也不能只将 yml 改 true 后宣称成功。bundled 普通 mihomo 的宽 entitlement 不等于未来受保护 root Core 的允许配置，安装版本必须独立核验。

已有 `scripts/check-adhoc-library-validation.mjs` 在普通用户临时目录实测通过：strict runtime 拒绝不同 ad-hoc dylib；runtime+disableLV、无 allowDYLD/get-task-allow 能正常 dlopen；相同签名下 `DYLD_INSERT_LIBRARIES` 的 constructor 在无 dlopen 路径未执行；非-runtime 阳性对照 constructor 执行。它只支持“disableLV 不等于 allowDYLD、该候选值得验证”，不证明 Electron 整体安全，也没有覆盖全部 DYLD 变体。

## 包内加载路径与可达性证据

实际 ASAR 只有 `out/main/index.js`、`out/preload/index.js`、renderer HTML/JS/CSS 和 package.json 等 11 个目录/文件条目，没有外置 node_modules/native addon。读取实际 main，字面量 require 仅 Electron/Node 内建模块，未发现动态 require 表达式、`process.dlopen` 或 `loadExtension` 业务入口。这是本次 App bundle 代码检查，不是整个 Electron/Chromium 的安全审计。

实际包内 main：

- renderer 与 preload 固定相对 ASAR 路径；`ELECTRON_RENDERER_URL` 仅在 `!app.isPackaged` 时读取。
- renderer `sandbox:true`、`contextIsolation:true`，未启用 nodeIntegration；CSP 为 `default-src 'self'; style-src 'self' 'unsafe-inline'`。
- 阻止 `will-navigate`；新窗口拒绝，仅 https 交给系统打开。
- `BrowserWindow` 未设置 `devTools:false`，Electron 45 本地声明明确默认 true。
- 未发现 `app.commandLine` 或 `remote-debugging` 参数过滤。单实例锁仅限制第二实例，不能保护尚未运行时的首次恶意参数启动。
- 实际 preload 暴露 `window.kuro.run(name,input)`；若攻击者能执行合法 renderer JS，就可提交受限 Command。这里不调用 setTun 或任何网络操作做验证。

`strings` 在实际 Framework 找到 `remote-debugging-port`、`remote-debugging-pipe`、`js-flags`、`renderer-cmd-prefix`、`gpu-launcher`、`disable-web-security`、`disable-gpu-sandbox`、`no-sandbox`。**字符串存在只证明二进制包含该入口名称，不能证明在本 App/fuse 配置下实际可用或已被利用。** 下一轮须验证启动前能拒绝危险入口，不能假定 JS 顶层删 switch 就足够早。

`otool` 离线显示主执行 RPATH `@executable_path/../Frameworks`；Electron Framework RPATH `@loader_path/Libraries`、`@loader_path/../../..`。本次检查的静态依赖指向 bundle Frameworks/Libraries 或系统路径，没有看到业务自选 dylib 路径。这不穷尽 Chromium 运行期动态库加载、argv 或用户数据影响。

当前 bundle 有 14 个标准 Framework 相对 symlink（如 `Versions/Current -> A`）；未发现 group/other 写位，但当前副本仍由普通用户拥有。`ProtectBundle` 一律拒绝 symlink，不能直接适配真实包；安装契约需按固定 manifest/解析后受保护目标验证合法内部链接，不能宽泛放行任意 symlink。`client.json` 目前只有读取，没有安装写入。现有 `Authorize` 还无条件拒绝完整鉴权，且一律拒绝 disableLV。这些都是尚未完成的接线，不是已通过的 direct App 方案。

## 可收敛入口与精确下一负例（均未执行）

在“非恶意 root、没有已获 Accessibility/调试控制或已攻陷 App 会话”的既定范围内，优先验证安装长期有限授权的 direct App。审计身份、受保护完整资源、hardened 启动及有限 RPC 必须组合；audit/CDHash 单独不证明用户意图或无注入。

可关闭/限制的候选：

1. production BrowserWindow 设置 `devTools:false`：App 无使用 DevTools 的产品功能；不把它单独当作 CDP 防护。
2. 在可信启动边界禁止 Chromium 远程调试、任意脚本/快照和进程 wrapper 参数。要验证拒绝发生在其生效之前，不能误禁 Electron 自己的 renderer/GPU/helper 进程参数，也不能仅靠客户端自报“安全 argv”。
3. 保留现有五项 fuse；production 不增加用户选择 JS/preload/extension/native addon 的入口。
4. `GrantFileProtocolExtraPrivileges` 可作为低风险关闭候选：本次业务源码未使用 file fetch、service worker、iframe/webview；仍须实际包验证 renderer module/CSS、窗口和 Backup 等流程，不能预先记为兼容通过。
5. 以实际 Electron 45 测试最小 entitlement：runtime=true，拒绝 allowDYLD/get-task-allow，disableLV 仅作为已检查加载边界的兼容例外；不要盲目移除 JIT 必需项，也不要保留不需要的 unsigned-executable-memory 后声称最小化。

动态验证前由主会话提供精确候选产物和安全隔离入口：确认独立空 userData、不读取现有 Profile，不自动启动普通 Core/TUN，不接真实 helper/network writer。不能只假设设置 HOME 或传 `--user-data-dir` 已正确隔离。下表是输入与通过标准，**不是本轮可直接执行的系统验收命令**。

| 负例输入/动作 | 必须取得的证据 |
| --- | --- |
| 同 UID 不同 binary/重签副本/不同 CDHash连接；复制合法 native shim转发 | helper按内核身份和安装 pin 拒绝；不能退回 UID/共享 secret |
| 首次启动 `--remote-debugging-port=0`；单独 `--remote-debugging-pipe` | 不出现可用 CDP session，无法 Runtime.evaluate 连到 renderer/preload；允许明确拒绝启动。只发送无副作用 JS marker，不调用 Command |
| `ELECTRON_RUN_AS_NODE=1` + 外部 marker JS；`NODE_OPTIONS=--require=<marker>`；`--inspect=0`/`--inspect-brk=0`、SIGUSR1 | 外部 JS 不执行，Node inspector 不开放；观察子进程退出/timeout，不能仅 grep fuse 值 |
| `DYLD_INSERT_LIBRARIES=<constructor marker dylib>`；分别测试 DYLD_LIBRARY_PATH/FRAMEWORK_PATH 同名替换 | hardened 实际 App 仍可正常启动但攻击者 constructor 不执行；阳性对照证明 payload 有效 |
| `ELECTRON_RENDERER_URL` 指向本地无害 marker；外部 app目录/入口 JS/preload、恶意 snapshot/wrapper 参数 | App只加载签名内预期资源或明确拒绝，不执行外部 marker；无需启动 HTTP 服务或访问外网 |
| 更改 ASAR header/任一 JS，或替换 Framework；symlink 逃逸与可写祖先 | 静态校验/启动/授权明确拒绝；不得同时更新受保护 pin 使负例自行变“可信” |
| renderer DevTools快捷键、菜单；正常窗口/CSS/Backup 等无网络回归 | 用户无调试产品功能；关闭额外 file privileges 不破坏正常流程 |

这些负例通过后，才能考虑在安装事务完成 pin/资源保护校验的前提下修改 Authorize 策略；不直接删当前拒绝门。长期有限授权不等于允许任意本地程序静默使用 root 能力；所有受限配置/broker/session/网络归属门仍保留。
