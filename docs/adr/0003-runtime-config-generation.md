# Profile 只读，生成 Runtime Config

Profile 原始内容永不修改。每次启动或变更时，用 Active Profile 和 App-managed Fields 生成 Runtime Config，先用 `mihomo -t` 校验，通过后原子写入（写临时文件再 rename），再让 Core 加载。模式等运行时改动先写入应用设置再 PATCH 到 Core，因为 Core 重启会丢掉 PATCH 的结果。同一时间只启用一份 Profile，不做多份合并。

## Consequences

- Active Profile 更新后自动重新生成并重载；`mihomo -t` 失败时保留旧 Runtime Config 并提示，重载会断开现有连接。
- 节点选择由 mihomo 的 `profile.store-selected` 持久化，应用不另存。
