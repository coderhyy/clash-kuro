# 全局 Override

Status: ready-for-agent
Type: task
Blocked by:

按 `../spec.md` 实现。

## 验收

- `applyOverride` 单测覆盖：递归合并、数组整体替换、`+key` 前插、`key+` 追加、嵌套层级的 `+key`、`null` 删除、不修改入参、`+key` 的值不是数组时报错。
- `buildRuntimeConfig` 单测：Override 写 `mixed-port`、`mode`、`external-controller`、`secret` 都不生效；Override 改 `rules`、`dns` 生效。
- `setOverride` 单测：YAML 错误或 `applyRuntimeConfig` 失败时 `override.yaml` 和快照都不变；成功时写文件、快照更新、Core 在跑则重载；没有 Active Profile 时只校验 YAML。
- 重启后从 `override.yaml` 读回。
- 设置面板有 Override 编辑区：保存按钮在内容未改动或处理中时禁用，失败显示错误，演示模式可用。
- `bun run test`、`bun run typecheck` 通过。

## Comments
