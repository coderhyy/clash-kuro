# MVP 不签名，更新只提示

MVP 安装包不做代码签名和公证，README 说明如何绕过 Gatekeeper（`xattr -d com.apple.quarantine`）和 SmartScreen。macOS 自动更新要求应用已签名，所以 MVP 不接入 electron-updater，只在启动时查询 GitHub Releases 并提示手动下载。买了 Apple Developer 账号、做完签名（包括内置的 mihomo 二进制）后，再接入自动更新。
