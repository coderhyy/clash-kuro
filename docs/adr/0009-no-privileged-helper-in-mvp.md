# MVP 不做 macOS 特权 helper

参考项目（Clash Party、Clash Verge Rev）在 macOS 上都装特权 helper 来设置 System Proxy，因为 `networksetup` 可能因权限被拒。MVP 不做：直接调用 `networksetup`，被拒时提示用户手动设置 127.0.0.1:mixed-port。LaunchDaemon、SMAppService 授权、helper 升级和卸载的成本，等到第二期 TUN（本身需要 root）再一起承担。Windows 的 WinINet 代理按用户设置，不需要提权。
