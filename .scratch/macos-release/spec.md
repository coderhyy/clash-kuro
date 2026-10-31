# macOS 首发 v0.1.0

Status: resolved

术语见 `CONTEXT.md`，签名相关决定见 ADR-0010。08（Windows System Proxy）挂起，不在本次范围。

## 决定（grill-with-docs，2026-10-31）

1. 只发 macOS；Windows 等 08 完成并真机验证后再发，届时 README 补 SmartScreen。
2. 只发 dmg。zip 留到接入自动更新时再加（electron-updater 需要 zip，ADR-0010 规定签名后才接）。
3. CI 发布：推 `v*` tag 触发 workflow，在 `macos-latest` 上构建并上传到 Release；只有该 job 有 `contents: write`。
4. 只发 arm64。
5. ad-hoc 签名（`identity: "-"`），关闭 hardened runtime；不算代码签名，README 仍需 `xattr`。
6. Release 先建草稿；验完 dmg 后 `gh release edit vX.Y.Z --draft=false` 发布。草稿不算 `releases/latest`，不会触发新版本提示。
7. workflow 第一步校验 tag 与 `apps/desktop/package.json` 的 `version` 一致，不一致即失败。本次版本改为 0.1.0。
8. 安装包命名 `clash-kuro-${version}-${arch}.dmg`。
9. Release 说明用 `--generate-notes`，开头固定一段：链接 README 安装说明并给出 `xattr` 命令。

## 内容

- `README.md`：简介、下载、安装（拖入 `/Applications`、`xattr -d com.apple.quarantine "/Applications/Clash Kuro.app"`）、数据目录、开发命令、发布流程。
- `apps/desktop/electron-builder.yml`：mac target 改为 dmg/arm64，ad-hoc 签名，`artifactName`。
- `apps/desktop/package.json`：`package` 脚本产出 dmg；版本 0.1.0。
- `.github/workflows/release.yml`：tag 触发、版本校验、测试、打包、建草稿 Release 并上传 dmg。
- `.github/workflows/ci.yml`：macOS 产物改为 dmg。

## Comments

2026-10-31 实现：本机 `bun run package` 产出 `clash-kuro-0.1.0-arm64.dmg`（143 MB），`codesign --verify --deep --strict` 通过，内置 mihomo 为 ad-hoc 签名；`spctl` 拒绝（未公证，符合预期）。模拟下载隔离标记后按 README 执行 `xattr -d` 即可启动，Core 正常运行。release workflow 尚未在 GitHub 上跑过，首次推 tag 即为实测。
