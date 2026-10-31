# MVP 不签名，更新只提示

MVP 安装包不做代码签名和公证，README 说明如何绕过 Gatekeeper（`xattr -d com.apple.quarantine`）和 SmartScreen。macOS 自动更新要求应用已签名，所以 MVP 不接入 electron-updater，只在启动时查询 GitHub Releases 并提示手动下载。买了 Apple Developer 账号、做完签名（包括内置的 mihomo 二进制）后，再接入自动更新。

补充（v0.1.0）：macOS 包做 ad-hoc 签名（`identity: "-"`），只为让应用包的签名结构完整、`codesign --verify` 通过；它不是代码签名，没有开发者身份也不经公证，Gatekeeper 照样拦，仍需 `xattr`。ad-hoc 签名下 hardened runtime 的库校验会拒绝加载签名不一致的 Electron framework，所以同时关闭 `hardenedRuntime`；正式签名时再打开。
