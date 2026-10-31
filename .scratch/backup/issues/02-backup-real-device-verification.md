# 备份真机验证

Status: ready-for-human
Type: task
Blocked by: 01

对话框和 `app.relaunch()` 只能在真机上看。

## 步骤

1. 打包版或 `bun run dev` 下导入两份 Profile，设一个 Active Profile，打开 System Proxy。
2. 点“导出备份…”：先出现“请妥善保管”警告（切到 English 再看一次英文），再出现保存对话框；打开导出的 JSON 确认内容。
3. 删掉一份 Profile、改 mixed-port。
4. 点“导入备份…”选刚才的文件，确认对话框后：System Proxy 被关掉，App 自动重启，Profile 和 mixed-port 恢复，数据目录 `backups/` 下有 `pre-import-*.json`。
5. 导入一个随便改坏的 JSON：显示错误，数据不变，App 不重启。

## Comments
