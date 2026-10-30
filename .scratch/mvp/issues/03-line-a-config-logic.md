# 线 A：配置逻辑

Status: ready-for-agent
Type: task
Blocked by: 01

只改 `packages/core`，纯函数 + Vitest。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

- 解析 Profile YAML，非法内容返回可读错误。
- 生成 Runtime Config：删除 `external-controller*`、`secret`，写入 App-managed Fields（含 `profile.store-selected: true` 和 Control Channel）。
- 解析 `subscription-userinfo`、`profile-update-interval` 响应头。
- 定时更新的纯逻辑：间隔取 `profile-update-interval`，缺省 24 小时，用户设置优先；计算下次更新时间；更新失败时保留旧内容并标出失败。
- 以上均有 Vitest 用例。
