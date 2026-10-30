# 线 A：配置逻辑

Status: resolved
Type: task
Blocked by: 01

只改 `packages/core`，纯函数 + Vitest。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

- 解析 Profile YAML，非法内容返回可读错误。
- 生成 Runtime Config：删除 `external-controller*`、`secret`，写入 App-managed Fields（含 `profile.store-selected: true` 和 Control Channel）。
- 解析 `subscription-userinfo`、`profile-update-interval` 响应头。
- 定时更新的纯逻辑：间隔取 `profile-update-interval`，缺省 24 小时，用户设置优先；计算下次更新时间；更新失败时保留旧内容并标出失败。
- 以上均有 Vitest 用例。

## Answer

- 从 `@tern/core` 导出 `parseProfile`、`buildRuntimeConfig`、`parseSubscriptionUserinfo`、`parseUpdateInterval`、`effectiveUpdateIntervalHours`、`nextUpdateAt`、`isDue`、`applyProfileUpdate`。
- 新增类型：`ParsedProfile`、`ProfileParseResult`、`ProfileUpdateResult`；已有接口不变。
- `parseProfile` 返回 `{ ok: true, value }` 或 `{ ok: false, error }`；`buildRuntimeConfig` 接收原始 YAML 或上述解析结果，返回 YAML，非法输入抛出可读错误。仅检查 YAML 结构，语义校验仍由调用方通过 `mihomo -t` 完成。
- `applyProfileUpdate(profile, previousContent, fetchResultOrError, now)` 返回新 Profile、原始内容、`attemptedAt` 和 `nextUpdateAt`。失败保留旧内容、成功时间和订阅元信息，只更新 `lastError`；成功清除错误并替换内容与服务端元信息。
- 时间戳除 `SubscriptionInfo.expireAt`（Unix 秒）外均为 Unix 毫秒。远程 Profile 间隔优先级为有效用户值 > 有效服务端值 > 24 小时；本地 Profile 无自动更新期限。失败后调用方须保留返回的 `nextUpdateAt`，或将 `attemptedAt` 作为 `nextUpdateAt` / `isDue` 的第三参数，避免立即重试；不改变 `Profile.updatedAt` 仅表示成功时间的约定。
- 使用 Bun 1.4.4 执行 `bunx turbo test typecheck`，8 个任务全部通过；core 共 89 个测试。仅新增 `yaml@2.9.1` 依赖，保持 lockfile v2。
