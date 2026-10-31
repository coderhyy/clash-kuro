# 备份导出与导入

Status: resolved
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

### 2026-10-31

已实现 Backup 校验、导出与整体替换导入；复用 hydrate 校验并原样保留 settings.json 的未知字段。导入与 Command 共用队列，先自动备份，再关闭 System Proxy、停止 Core，逐文件原子替换，最后写 settings.json；导入成功或替换中途失败后均拒绝后续 Command，失败信息指向自动备份。

已接入受 trusted(event) 保护的 IPC、系统保存/打开/确认对话框、0600 权限导出、50 MB 上限、preload 类型和设置面板按钮。没有新增依赖，也不依赖 Override 或英文界面分支。

验证：全量 302 项测试通过（新增 55 项，含解析、往返、写盘失败、队列和 IPC 边界），根目录 typecheck 通过，electron-vite build 通过。沙箱本地 socket 测试遇到 EPERM 后已授权重跑成功；浏览器确认演示模式隐藏按钮，桌面桥接 UI stub 下按钮、忙碌态及成功/错误提示正常，控制台无错误。

02 保持 ready-for-human：原生对话框、真实 System Proxy 和 app.relaunch() 仍待真机验证。Override 目前仅作为可选文本保存，不校验 YAML；逐文件原子写入不是跨文件事务，中途失败需用 pre-import Backup 恢复。
