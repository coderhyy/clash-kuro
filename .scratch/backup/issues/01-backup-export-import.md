# 备份导出与导入

Status: ready-for-agent
Type: task
Blocked by:

按 `../spec.md` 实现。

## 验收

- `parseBackup` 单测：拒绝错误的 `format`/`version`、非法 Settings、非法 Profile、ID 与内容键不一致、内容不是字符串、非法 Active Profile；接受带未知顶层 settings 字段（如 `language`）的备份。
- `exportBackup` 单测：包含 settings、全部 Profile 内容、`override.yaml`（存在时）；不含 runtime 文件。
- `importBackup` 单测：校验失败时 FakePlatform 文件一个都不变；成功时先写 `backups/pre-import-*.json`，System Proxy 关闭、Core 停止，旧 Profile 内容文件被删，`settings.json` 最后写；之后的 Command 返回错误。
- 导出 → 导入同一份 → 数据一致（单测往返）。
- 设置面板有两个按钮；演示模式（无 `window.kuroFiles`）下不显示。
- `bun run test`、`bun run typecheck` 通过。

## Comments
