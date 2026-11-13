# 首次 TUN 正常启停窗口（待授权）

源码 `49f7dd6e610e18b2a4c59c85b92f2c29045b95d4`；不包含之后独立开发的崩溃停止证明改动。

- 安装包：`/Users/hyy/.codex/worktrees/windows-launch-at-login/clash-kuro/apps/desktop/dist/kuro-tun-finite-session-0.1.0-arm64-49f7dd6e610e.pkg`
- SHA256：`2f14fcde80dcfc3e8fe61cf403001ce5d655549cf7dd5514f207c23aecaa825a`
- Profile：同目录 `profile.yaml`，SHA256 `b526b172f24cfd64e0836acc2f718de5729cea5a38370ab595e6789ff6f4db46`。
- 固定 Core：mihomo v1.19.33，SHA256 `f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9`。
- CI：https://github.com/coderhyy/clash-kuro/actions/runs/42017796326 。实际解包独立核对通过，见 package-review/RESULT.md；未安装/未启动本候选。

## 人工动作和阶段

预计 25–40 分钟，不含未知故障处理。维护者处理管理员弹窗；先确认并自行退出冲突的第三方隧道模式，代理工具的配置不由 agent 修改。当前只读快照发现非 Kuro utun 占用固定池及 split-default；未识别其产品名，不猜测。若不便退出，窗口延期。

1. 核对摘要、准确安装目标无冲突、旧生产 job/owner/receipt/事务；保存只读路由、接口、完整 scoped DNS、代理、launchd 与安装身份基线到新建0700证据目录。第三方冲突处理后重读；仍有冲突则零启动。若现用 DNS 不再是 Profile 中的供应商，停止并重新准备相符 Profile，绝不静默替换。
2. fresh 安装此包，核对受保护 App、helper、manifest、receipt、Core 实际字节。App 固定在 `/Library/Application Support/Clash Kuro/Client/Clash Kuro.app`；固定隔离候选数据不读普通产品 Profile。仅按 READINESS 中准确 job load/print/kickstart 操作，不用 -w、enable、-k 或替代命令。
3. 从实际安装 App 导入测试 Profile，保持系统代理关闭，点击一次 TUN。核对实际 Core 身份、utun、双栈本机地址/DNS就绪、自有四条路由和临时 DNS；保存准确 owner/work/network 记录。Profile 显式 MATCH,DIRECT，不使用私人订阅，不宣称代理转发或远端 IPv6 已验收。
4. 点击关闭 TUN；核对准确 Core 退出、utun/自有路由/临时 DNS消失、原 LAN/scoped DNS/代理基线保持、owner/work清退和准确停止证明。全部通过才进入清理。不含故意 helper 强杀，也不把 owner socket 断开当实际 Electron 退出验收。
5. 核对有效 stopped 证明和完整足迹缺席后，正常退出实际 App 并确认其进程退出，再卸载准确 job，再使用受保护的准确卸载器。分别核对 job、进程、socket、App/helper、身份记录和安装 receipt；未知或改变项保留。候选普通用户数据与证据保留，不递归删除。

## 影响、停止条件与恢复

开启期间会运行 root 固定 Core，建立 utun、双族 split routes 和本应用临时 DNS；预期保留 LAN/分域 DNS。无独立 kill switch，隧道路由消失后系统可能直连。远端 IPv6 可达性不能由 IPv4-only 上游上的本地双栈检查证明。

摘要/身份/安装冲突、基线变化、接口或网络读回失败、未知归属、停止超时、清理不确定任一出现，停止后续启动与验收。保留原始日志、退出状态及记录，不临时修改安装字节或猜 PID/PGID。

先从同一 App 关闭 TUN；仍持有会话的原 worker 负责准确停止及重试清理。Core已退出但清理失败时保留 helper，使用“检查并恢复TUN”重新检查；不能先 bootout 造成持有证据丢失。客户端响应超时不等于清理结论，须独立读回。只有同归属、原值仍匹配的 DNS journal 可以恢复，路由仅按已有严格归属规则；不 flush 全局路由/DNS，不修改第三方配置。

若 helper 已异常死亡，fresh恢复仍须当前安装绑定、准确Core/helper缺席与工作目录/缓存/网络检查；不能因组空伪造已reap证明。当前崩溃卸载/升级证明仍缺，因此不能承诺所有故障自动卸载。超出现有恢复能力则停止并保留受保护安装/owner/work及证据，报告具体残留和下一项最小恢复方案；不扩大删除或信号范围。

独立恢复审查已完成：normal-only无须等全部crash卸载/升级实现，现有持有停止及原worker恢复路径可用。若49出现 `blocked/off` 且错误为 `uninstall checkpoint failed`，App recover 不会修复停止证明；此时必须保留安装与证据，不按off执行bootout/卸载。off后退出App仅为卸载清理，不证明TUN-on App退出生命周期。

独立包审查已通过。候选及执行步骤具备提交窗口授权条件；现场冲突、重新核验baseline/Profile与明确授权仍是执行门。本文件不构成执行授权。
