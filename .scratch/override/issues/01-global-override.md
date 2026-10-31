# 全局 Override

Status: resolved
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

### 2026-10-31

已实现全局 YAML Override：纯函数解析与递归合并、数组替换/前插/追加、null 删除、App-managed Fields 优先及控制器字段清理；主进程校验后原子保存 `override.yaml`，更新快照并按需重载 Core，启动时恢复原文。无 Active Profile 时仅解析 YAML。设置面板加入等宽编辑区、未修改/处理中禁用保存，并复用错误提示；demo Command 同步支持。

验证：新增 34 个测试，全量 281 个测试通过（Core 113、API 12、State 45、Desktop 111，含真实 mihomo 集成）；`bun run typecheck` 与 `bunx electron-vite build` 通过。全量测试首次因沙箱禁止本地 socket 报 EPERM，提权重跑后全部通过。实际 Bun 为 1.3.14，未替换环境；可选 UI 截图因 Playwright 浏览器配置被其他会话占用而跳过。
