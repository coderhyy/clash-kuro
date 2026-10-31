# 英文界面与语言设置

Status: ready-for-agent
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
