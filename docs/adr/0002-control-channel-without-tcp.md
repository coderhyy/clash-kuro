# Control Channel 只用 unix socket / named pipe

Core 的 API 只通过 `external-controller-unix`（macOS）和 `external-controller-pipe`（Windows）暴露，不开 TCP 端口，避免本机网页和其他用户访问。mihomo 对这两条通道不校验 secret，所以不使用 secret，安全依赖：socket 放在应用数据目录且权限 0600；pipe 名每次启动带随机后缀。生成 Runtime Config 时强制删除 Profile 里的 `external-controller*` 和 `secret`，由应用写入。

## Consequences

- 无法用浏览器打开外部面板（如 metacubexd），除非以后显式开启 TCP 控制器。
