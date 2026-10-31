# 英文界面

Status: done

第二期功能。术语见 `CONTEXT.md` 的 **界面语言**。与覆写、备份并行开发，分支 `codex/english-ui`。

## 决定（grill-with-docs，2026-10-31）

1. 语言设置三档：跟随系统 / 中文 / English，默认跟随系统。跟随系统时 `app.getLocale()` 以 `zh` 开头用中文，其余用英文。
2. 存为 `settings.json` 的顶层字段 `language`（`'system' | 'zh-CN' | 'en'`），不放进 `Settings`。缺失或非法时按 `'system'` 处理，不报错（备份导入的旧文件也能启动）。
3. 快照同时带用户的选择和解析后的语言。渲染端和托盘都读快照。托盘文字从 `apps/desktop/src/main/index.ts` 的 `trayLabels` 搬进共享翻译表，跟随语言。
4. 翻译界面、托盘和对话框。`<html lang>`、日期和数字格式跟随语言。领域术语（Profile、Active Profile、Core、System Proxy、Mode、Proxy Group、Proxy、Override 等）两种语言都保留英文。主进程的错误信息本轮保持原样（英文）。
5. 测试断言 en 和 zh-CN 的 key 集合完全一致。

## 形状

- `@kuro/state`：
  - 类型 `Language = 'zh-CN' | 'en'`，`LanguagePreference = 'system' | Language`。
  - 快照字段 `language: LanguagePreference`、`resolvedLanguage: Language`。
  - `AppStoreDeps.systemLocale(): string`；解析规则在 store 里（纯逻辑，可测）。
  - Command `setLanguage({ language })`：校验、写 `settings.json`、`change`。不影响 Runtime Config，不重载 Core。
  - `persist` 写 `settings.json` 时带上 `language`。
- 翻译表搬到 `apps/desktop/src/shared/i18n/`（`zh-CN.ts`、`en.ts`、`index.ts`），主进程和渲染端共用；`tsconfig.node.json`、`tsconfig.web.json` 都 include 它。`t(key, values)` 按当前语言取文案；渲染端在快照变化时设置当前语言，主进程按快照的 `resolvedLanguage` 取托盘文案。
- `display.ts` 的 `formatBytes`、`date` 按当前语言格式化。
- 设置面板加语言选择（三档）。

## 内容

- `packages/state/src/index.ts`、`store.ts`、`fake.ts`、`store.test.ts`
- `apps/desktop/src/shared/i18n/`（新，替代 `renderer/src/i18n/`）及测试
- `apps/desktop/tsconfig.node.json`、`tsconfig.web.json`，必要时 `electron.vite.config.ts` 的 alias
- `apps/desktop/src/main/index.ts`：`systemLocale: () => app.getLocale()`，托盘文案
- `apps/desktop/src/renderer/src/app.tsx`、`live-panel.tsx`、`display.ts`（及测试）、`dev-bridge.ts`、`index.html`、`styles.css`

## 不做

- 其他语言、运行时下载语言包、翻译主进程错误信息。
- 托盘里的语言切换入口。

## Comments
