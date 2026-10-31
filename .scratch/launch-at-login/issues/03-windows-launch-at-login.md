# Windows 开机自启

Status: needs-triage
Type: task
Blocked by: `.scratch/mvp/issues/08-windows-system-proxy.md` 合并进 main

Windows 上 `getLaunchAtLogin` 目前返回 `unsupported`，开关隐藏。08 合并后再做：

- `setLoginItemSettings({ openAtLogin, args: ['--hidden'] })`，读取时传同样的 `args`。
- 登录启动的判断改为 `process.argv.includes('--hidden')`。
- 需要 Windows 真机验证，和 08 一起或在它之后做。

## Comments
