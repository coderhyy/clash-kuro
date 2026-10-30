# 线 D：界面

Status: ready-for-agent
Type: task
Blocked by: 01

只改 `apps/desktop/src/renderer`，用假状态快照开发。在独立 worktree 开发。需要改 01 定下的接口时，先回主干改，再继续。

## 验收

- shadcn/ui（Base UI + Tailwind v4，ADR-0007），文案全部走 i18n，提供 zh-CN。
- 页面：Profile 列表与导入、Proxy Group 选择、Mode 切换、System Proxy 开关、设置（mixed-port、Update Interval）、Subscription Info 展示、更新失败标记。
- 所有操作只发 Command，不直接访问 Core。
- 流量与日志的 WebSocket 只在窗口存在时订阅。
