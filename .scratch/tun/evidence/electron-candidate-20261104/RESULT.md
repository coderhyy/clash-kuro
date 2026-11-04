# 2026-11-04 集成检查点：硬化 App 与禁用安装包

硬化 App 可实际运行隔离 UI、preload IPC、Language/Override 与内存 Backup 往返。它不是完整 TUN 实验候选：生产 Authorize、接口就绪、网络安装/恢复 hooks 仍拒绝，真实 Core 管理未运行。具体动态输入、签名/资源负例与限制见 [Electron 验证记录](../../electron-auth-verification.md)。

## 精确产物

- App：`apps/desktop/dist/electron-runtime-candidate/mac-arm64/Clash Kuro.app`，身份见 [artifact.json](package/artifact.json) 的 client。原件未因原生最终集成而重签。
- 组合包：`apps/desktop/dist/kuro-tun-helper-client-disabled-0.1.0-arm64.pkg`。
- 包 SHA256：`c3cdf1af1f5bd9f7745171b55958c78589c564db53152de69e8d9f4ed6a5b6bf`。
- helper SHA256：`5a754926a197d6c0b437fb9a56cc1dde85fb7c1d4aeefa2f86ea5119d1526a0a`。
- 固定安装目标：`/Library/Application Support/Clash Kuro/Client/Clash Kuro.app`。卸载 helper 撤销 client.json 授权，保留 App；当前只支持 fresh install，已有/部分安装拒绝，升级未完成。

这是本地未提交源码快照的产物，不是 CI 验证发布提交；[源码摘要](package/SOURCE-SHA256SUMS)和[基点](package/source-state.json)保留关联。不能把早先 CI 或另一个 DMG 的结果移用于它。

## 最终离线核验

`pkgutil --expand-full` 只解包，未调用 Installer。解包 App 重做严格 seal、15 个 Mach-O runtime/entitlements、ASAR/fuses 和精确 client pin 校验，通过。PackageInfo 的 9 个 bundle 均位于固定 Client 目录，relocatable=false，relocate 与 bundle-version 列表为空，9 个 strict identifier 全覆盖。BOM 的 1251 项预期 UID 均为 0；这是包元数据，不是安装后的权限实测。包内 helper/Core 摘要与 manifest/metadata 一致；Disabled=true，RunAtLoad/KeepAlive=false。原始 [PackageInfo](package/PackageInfo.xml)、[BOM](package/bom-fum.txt)、[断言结果](package/verification.json)已保存。

最终 native `KURO_SKIP_CORE_SYNTAX=1 node apps/desktop/scripts/build-macos-helper.mjs --test` 通过：23 个 service fixture 场景；session 的 EOF/lease/identity/停止和启动取消；21 个接口关联快照；路由 wire+12 个归属恢复场景；DNS 29+5 个场景；普通用户临时安装/pin/篡改/卸载。两个启动屏障和停止 ACK 屏障覆盖本轮发现的并发窗口。生产编译使用 `-Wall -Wextra -Werror`。打包相关 29 测试与 desktop typecheck 通过。均不能代替真实 Core/网络实验。

本轮早期曾误触既有 mihomo `-t` 语法测试，已告知用户；没有启动 Core 会话，后续 native 测试显式跳过真实 Core。没有安装候选或执行 TUN/网络写入，也没有沿用实验 A 的系统授权。

## 现在可执行的校验（无需系统变更，约 1 分钟）

在仓库根目录执行：

```sh
shasum -a 256 apps/desktop/dist/kuro-tun-helper-client-disabled-0.1.0-arm64.pkg
cd .scratch/tun/evidence/electron-candidate-20261104
shasum -a 256 -c SHA256SUMS
```

保存本目录、包及旁边的 `.pkg.json`。摘要不一致就停止，不运行或重签来“修复”身份。不要双击安装该包：它尚不适合用户执行完整 TUN 验收。

## 下一项系统实验的最小边界（尚未准备完毕、未获授权）

先做不运行 Core、不改网络的受保护安装/动态鉴权观察，预计 5–10 分钟，只涉及固定 Client、helper、批准记录和隔离测试 socket。开始前必须补齐可区分合法 App 与冒充者、但不授予启动能力的观察入口，以及该精确版本的安装失败恢复清单；当前全拒绝不能冒充负例成功。完成安装后核验 root/ACL/链接/pin，合法 App 与同 UID 外部进程/重签副本分别验证，然后使用经审阅的卸载入口撤销授权并清理精确安装清单。身份不明、超时或清理不能确认时保留证据并停止，不扩大删除或 kill 范围。**当前不提供系统执行命令，也不请求“开始”。**

随后才单独提出固定 mihomo 私有 socket、direct-child/pgrp、utun 关联与停止实验；默认路由和 DNS 写入另按范围授权。完整 TUN 实验还缺固定 LAN/分域 DNS/代理出口规则的实际接线与 kernel readback、真实停止和 helper 强杀后恢复。不能用四条双栈 `/1` 候选或 fixture 的组清理宣称这些已满足。
