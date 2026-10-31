# 英文界面与语言设置

Status: resolved
Type: task
Blocked by:

按 `../spec.md` 实现。

## 验收

- 设置面板有语言选择：跟随系统 / 中文 / English，切换后界面、托盘立即变；重启后保持。
- 跟随系统：`systemLocale()` 以 `zh` 开头为中文，其余英文（单测）。
- `settings.json` 缺 `language` 或值非法时按跟随系统启动（单测）。
- en 与 zh-CN 的 key 集合一致（单测）；现有翻译测试迁到新位置。
- `<html lang>`、`formatBytes`、日期格式跟随语言（`display.test.ts` 覆盖英文）。
- 演示模式下两种语言各截图一次，确认英文文案不撑破布局。
- `bun run test`、`bun run typecheck` 通过。

## Comments

### 2026-10-31

Implemented the three-way Language setting, persisted as a top-level `language` field. Snapshots carry the preference and resolved language; missing/invalid saved values fall back to system. Language changes do not rebuild Runtime Config, restart Core, or change System Proxy.

Moved the Chinese table and its tests with `git mv` into `apps/desktop/src/shared/i18n/`, added English copy and shared tray/dialog translations, and wired the renderer, demo Commands, HTML language, dates, and byte formatting. Translation keys and interpolation placeholders match in both languages. Existing notices and validation errors also follow language changes.

Verification: `bun run test` passes (255 tests, 25 files; socket tests rerun with escalation), `bun run typecheck` passes, and `bunx electron-vite build` passes. Playwright demo checks cover English, Chinese, Follow system, HTML language, translated notices, and date formatting. No text/page overflow at 960x640, 720x520, or 390x844. The UI detector reports no findings.

Screenshots:
- `/Users/hyy/.codex/visualizations/2026/10/31/01a19193-6ae9-7dc3-abda-c6bebb0292c2/english-ui-en.png`
- `/Users/hyy/.codex/visualizations/2026/10/31/01a19193-6ae9-7dc3-abda-c6bebb0292c2/english-ui-en-settings.png`
- `/Users/hyy/.codex/visualizations/2026/10/31/01a19193-6ae9-7dc3-abda-c6bebb0292c2/english-ui-zh-CN.png`

Native Electron tray/dialog interactions were not manually exercised; tray labels are tested in both languages and main/preload/renderer builds pass. Main-process error messages remain unchanged, as specified.
