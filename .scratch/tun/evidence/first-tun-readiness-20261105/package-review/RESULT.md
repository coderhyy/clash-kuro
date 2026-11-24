# 49f7dd6 fresh finite-session 包离线独立复核

结论：**通过，未发现离线包交付阻塞**。本次只展开、读取与验证签名/摘要；没有执行安装脚本、App、helper、Core 或系统网络操作。

- 源提交：`49f7dd6e610e18b2a4c59c85b92f2c29045b95d4`。
- 包：`apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-49f7dd6e610e.pkg`，171,771,195 bytes。
- 包 SHA256：`2f14fcde80dcfc3e8fe61cf403001ce5d655549cf7dd5514f207c23aecaa825a`。
- sidecar SHA256：`b79cdd464fe8f97d6cbd08b1a2734c03220e3a2ac00f1adb630993e968c5a222`。
- helper SHA256：`1c4f67df8ca9794a99a3667dec3a19e6a4d563a18b1fc8c80992b95780f2d46e`。
- Core SHA256：`f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`；固定 v1.19.33 的 archive pin 与该提交 core.lock 一致。

已从实际展开 App 验证 hardened runtime、最小 entitlement、禁用 Node 注入/调试 fuses、ASAR integrity、完整 seal；实际 client pin 与 manifest、sidecar、App build record 一致。611 项完整 client inventory 的 bytes/hash 一致，合法 Framework 内部链接保留。封印元数据确为 finite-session/authObservationOnly=false/同提交；实际 ASAR main 包含固定候选数据隔离和当前固定 auth/control endpoints。

原生构建记录为同提交 sourceClean=true、tests=true、coreSyntaxSkipped=false、installerProtocol=2；与包中实际 helper 字节完全绑定。已独立逐字节核对该提交的全部递归 native import（14 个）和关键构建/App入口源码（5 个），并检查 actual helper 中 installation/runtime/cacheOrigin/cacheCheckpoint 等闭合字段与拒绝文本。详情见 [源码和字段核验](source-and-field-checks.json)。这不是独立可重现编译证明。

实际包 BOM 共 1,253 项，预期 UID/GID 均为 0/0。Inbox 为 0700，sidecars 为 0600，helper/Core/installer/recovery 为 0755；9 个 bundle 固定于受保护 Client 路径、不可重定位。实际 preinstall 仅调用包内 `preflight-native --begin-client-install`；postinstall 仅调用固定 `dev.kuro.tun/installer --install`。未执行这些脚本。预备 plist 与脚本 sidecar 一致，Disabled=true、RunAtLoad=false、KeepAlive=false、AbandonProcessGroup=false，参数为准确版本 helper `--serve`。包未直接布置 LaunchDaemons、TunDiagnostics 或 Upgrade payload；生产布局仍由 native installer 准入。

preflight-native、installer、固定卸载 recovery 和 Inbox helper 摘要相同。manifest/client inventory/plist 在 Scripts 和 Inbox 两份字节完全一致；包和 sidecar 复核前后未变化。包本身未签名，App/helper 为本地候选 ad-hoc 签名，不能据此宣称发布者身份或 notarization。

主会话报告此提交标准 native 全套、102 项升级中断、94 项 output 断言成功及 CI run 42017796326 成功；本审查未重跑这些测试，未将它们当真实 TUN 网络通过。

**限制：** BOM 仅为预期安装元数据，不能证明 root 实际安装保护或动态鉴权；本次不证明首次 TUN/数据面、helper crash 恢复、运行后卸载或真实升级通过。本包仅包含49f7dd6源码，不含随后仍在临时目录设计的 stopped-proof 修改。现场已有 route 冲突与人工网络窗口授权仍独立处理。

机器可读结论见 [verification.json](verification.json)，实际 ASAR entry 检查见 [asar-entry-check.json](asar-entry-check.json)。仅归档小型非敏感结果；完整 App/pkg、用户路径与原始日志不复制到此目录。
