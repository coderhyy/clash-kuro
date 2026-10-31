# Clash Kuro

mihomo 的精简桌面客户端：导入并定时更新 Profile，启停 Core，切换 Mode，在 Proxy Group 中选择 Proxy，开关 System Proxy，常驻托盘。

目前只提供 macOS（Apple Silicon）版本。Windows 版本在 System Proxy 完成后发布。

## 下载

在 [Releases](https://github.com/coderhyy/clash-kuro/releases/latest) 下载 `clash-kuro-<版本>-arm64.dmg`。

## 安装（macOS）

安装包没有经过 Apple 签名和公证（ADR-0010），首次打开会被 Gatekeeper 拦下，提示“无法验证开发者”或“已损坏”。按下面的步骤安装：

1. 打开 dmg，把 **Clash Kuro** 拖进“应用程序”（Applications）文件夹。
2. 打开“终端”，执行：

   ```sh
   xattr -d com.apple.quarantine "/Applications/Clash Kuro.app"
   ```

   这条命令去掉下载时 macOS 加上的隔离标记。没有输出就是成功；如果提示 `No such xattr`，说明标记已经不在了，可以直接打开。
3. 从“应用程序”里打开 Clash Kuro。

每次下载新版本覆盖安装后，都要重新执行第 2 步。

请从“应用程序”文件夹里运行，不要直接在 dmg 或“下载”文件夹里打开，否则 macOS 可能把应用放到随机的临时路径运行。

## 使用须知

- 应用数据保存在 `~/Library/Application Support/Clash Kuro/`，卸载应用不会删除。
- 有新版本时，应用会在启动时提示，需要手动下载安装。
- 如果 macOS 拒绝修改网络设置，开启 System Proxy 会失败，请在“系统设置 > 网络”里手动把 HTTP/HTTPS 代理设为 `127.0.0.1:<mixed-port>`。

## 开发

需要 [bun](https://bun.sh) 1.4.4。

```sh
bun install
bun run test        # 全部测试
bun run typecheck
cd apps/desktop
bun run fetch-core  # 下载锁定版本的 Core 与 Geo 数据（首次和更新 core.lock.json 后）
bun run dev         # 开发模式
bun run package     # 打包 dmg，产物在 apps/desktop/dist/
```

术语见 `CONTEXT.md`，架构决定见 `docs/adr/`。

## 发布

1. 把 `apps/desktop/package.json` 的 `version` 改成新版本并提交。
2. 打同名 tag 并推送：`git tag v0.1.0 && git push origin v0.1.0`。
3. `.github/workflows/release.yml` 会校验 tag 与 `version` 一致、跑测试、打包，并建一个草稿 Release 挂上 dmg。
4. 下载草稿里的 dmg 验证后发布：`gh release edit v0.1.0 --draft=false`。发布后已安装的用户才会收到新版本提示。

## 许可证

Clash Kuro 使用 MIT 许可证（ADR-0006）。内置的 [mihomo](https://github.com/MetaCubeX/mihomo) 使用 GPL-3.0，作为独立进程随包分发；许可证随附在应用包的 `Contents/Resources/licenses/` 中，源码见其仓库。
