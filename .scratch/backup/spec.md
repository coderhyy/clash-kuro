# 备份（导入导出）

Status: in-progress（待 02 真机验证）

第二期功能。术语见 `CONTEXT.md` 的 **Backup**。与覆写、英文界面并行开发，分支 `codex/backup`。

## 决定（grill-with-docs，2026-10-31）

1. 导出一个 JSON 文件：
   ```json
   { "format": "clash-kuro-backup", "version": 1, "createdAt": "<ISO 时间>",
     "settings": <settings.json 的整个对象>, "profiles": { "<id>": "<原始 YAML>" }, "override": "<YAML>" | null }
   ```
   `settings` 原样保留 `settings.json` 的所有字段（包括将来的 `language`）。不含 Runtime Config、pid 文件、Geo 数据和开机自启状态。不做单个 Profile 导出。
2. 导出前提示“备份含订阅地址和节点密钥，请勿分享”。不加密。
3. 导入整体替换，顺序：
   1. 确认对话框。
   2. 完整校验：结构、`format`/`version`、Settings、每个 Profile、Active Profile、Profile ID 与 `profiles` 的键一一对应、每份内容是字符串。文件大于 50 MB 直接拒绝。
   3. 把当前数据自动导出到 `backups/pre-import-<时间>.json`。
   4. 关 System Proxy、停 Core。
   5. 写文件：先写各 `profiles/<id>.yaml` 和 `override.yaml`（备份里为 `null` 时删除），删掉当前有、备份里没有的 Profile 内容文件，最后写 `settings.json`。每个文件原子写入；`settings.json` 最后写，作为提交点。
   6. `app.relaunch()` 后退出。
   - 校验失败时什么都不改。
4. 设置面板底部两个按钮：“导出备份…”“导入备份…”，用系统保存/打开对话框。不加托盘入口。
5. `override.yaml` 是可选的，本分支不依赖覆写分支：只当成一个可能存在的文本文件读写。覆写合并进来后再给导入加 Override 的 YAML 校验。
6. 对话框文案本轮写在主进程里（中文）。英文界面合并后改用共享翻译表。

## 形状

- `@kuro/state`（`backup.ts`，无 Electron/fs）：
  - `BACKUP_FORMAT`、`Backup` 类型、`parseBackup(json: string): Backup`（失败抛出可读错误）。复用 `store.ts` 的 Settings/Profile 校验（导出 `validateSavedState`，hydrate 也用它）。
  - `AppStore.exportBackup(): Promise<string>`：从 Platform 读 `settings.json`、各 Profile 内容和 `override.yaml`，返回 JSON 文本。
  - `AppStore.importBackup(json: string): Promise<void>`：按决定 3 的第 2–5 步，经命令队列串行。完成后 store 拒绝后续 Command（应用即将重启）。
- 桌面端主进程：
  - IPC `exportBackup`：警告对话框 → 保存对话框（默认文件名 `clash-kuro-backup-<日期>.json`）→ 写到用户选的路径（权限 0o600）。
  - IPC `importBackup`：打开对话框 → 确认对话框 → 读文件（50 MB 上限）→ `importBackup` → `app.relaunch()` + `exit()`。
  - 返回 `{ ok: true } | { ok: false, error } | null`（取消），渲染端显示结果。
- preload `window.kuroFiles` 加 `exportBackup()`、`importBackup()`；`env.d.ts` 同步。

## 内容

- `packages/state/src/backup.ts`（新）及测试，`store.ts`、`index.ts`、`store.test.ts`
- `apps/desktop/src/main/index.ts`、`ipc-channels.ts`
- `apps/desktop/src/preload/index.ts`、`renderer/src/env.d.ts`
- `apps/desktop/src/renderer/src/app.tsx`、`i18n/zh-CN.ts`、`styles.css`

## 不做

- 加密、单个 Profile 导出、托盘入口、云同步、合并式导入。

## Comments
