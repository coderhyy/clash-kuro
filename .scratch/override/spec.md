# 覆写（Override）

Status: done

第二期功能。术语见 `CONTEXT.md` 的 **Override**。与英文界面、备份并行开发，各自一个分支（`codex/override`）。

## 决定（grill-with-docs，2026-10-31）

1. 只支持 YAML，不支持 JS 脚本。
2. 全局一份 Override，对所有 Profile 生效。按 Profile 单独覆写是后续项；不做多条列表。
3. 合并规则：
   - 两边都是 mapping 时递归合并。
   - 数组和标量整体替换原值。
   - 键名写成 `+key` 时，把值（必须是数组）插到原数组前面；写成 `key+` 时追加到后面。任何层级、任何数组键都适用。原值不是数组或不存在时当作空数组。
   - 键名写成 `key!` 时整个值直接替换原值，不递归合并，值里的键也不再解析标记。
   - 其他标记写法（`!key`、`+key!`、`key!+`、`<key>`、`key<`、连续标记等）报错，不当作普通键写进配置。键中间的 `+`、`!`、`<`、`>` 仍是普通字符。
   - 值为 `null` 时删除这个键。
4. 顺序：Profile → Override → App-managed Fields，App-managed Fields 始终优先。合并后照旧删除 `external-controller*` 和 `secret`，Override 不能开 TCP 控制器（ADR-0002）。
5. 编辑和保存：
   - 设置面板里一个等宽字体的 textarea，不引入编辑器依赖。
   - 保存时先解析 YAML，再生成 Runtime Config 并跑 `mihomo -t`（`applyRuntimeConfig`），全部通过后才写 `override.yaml` 并重载 Core。没有 Active Profile 时只做 YAML 解析和合并规则校验（标记写法、`+key`/`key+` 的值必须是数组）。
   - 失败时保留旧 Override，界面显示错误。
   - 空内容（或只有注释）表示没有 Override。
   - 快照带 `override: string`（原文）。

## 形状

- `@kuro/core`（`config.ts`）：
  - `parseOverride(yaml): ProfileParseResult`：空内容得到空 mapping；顶层必须是 mapping。
  - `applyOverride(base, override): ParsedProfile`：纯函数，不修改入参，按决定 3 合并。
  - `buildRuntimeConfig(profile, settings, controlChannel, override = '')`：解析后先 `applyOverride`，再删控制器字段、写 App-managed Fields。
- `@kuro/state`：
  - `AppStoreDeps.buildRuntimeConfig` 的 input 增加 `override: string`。
  - 启动时读 `override.yaml`（不存在为 `''`）。快照字段 `override: string`。
  - Command `setOverride({ yaml })`：按决定 5 校验、写文件、`change`、`reloadIfRunning`。`prepareRuntime` 用当前快照的 `override`。
- 桌面端：`app/profiles.ts` 把 `override` 传给 `buildRuntimeConfig`。

## 内容

- `packages/core/src/config.ts`、`config.test.ts`、`index.ts`（导出）
- `packages/state/src/index.ts`、`store.ts`、`fake.ts`、`store.test.ts`
- `apps/desktop/src/main/app/profiles.ts`（及测试）
- `apps/desktop/src/renderer/src/app.tsx`、`dev-bridge.ts`、`i18n/zh-CN.ts`、`styles.css`

## 不做

- JS 脚本覆写、按 Profile 覆写、多条覆写列表、语法高亮编辑器。
- 托盘入口。

## Comments

- 2026-10-31：补 `key!`（整体替换），不做 `<key>`；未知标记组合报错。
