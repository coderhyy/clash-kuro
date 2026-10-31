# 开机自启 macOS 真机验证

Status: ready-for-human
Type: task
Blocked by: 01

ad-hoc 签名、未公证的 App 能否通过 SMAppService 注册为登录项，还没有验证过（ADR-0010）。

## 步骤

1. `bun run package` 打出 dmg，拖进 `/Applications`，按 README 去掉隔离标记后启动。
2. 在设置面板打开开机自启，记录界面状态（已开启或需批准）。若需批准，点按钮到“系统设置 → 通用 → 登录项”批准，回到窗口确认状态变成已开启。
3. 注销再登录：确认 App 自动启动、没有窗口和 Dock 图标、托盘在；有 Active Profile 时 Core 在跑；System Proxy 没开（符合决定 4）。
4. 在系统设置里关掉 Clash Kuro 的登录项，切回 App 窗口，确认开关变成关闭。
5. 在 App 里关闭后注销再登录，确认不再自动启动。
6. 普通打开 App（不是登录启动）仍然弹窗口。

## 若失败

- 注册报错或状态一直是 `not-found`：记录 `app.getLoginItemSettings()` 的输出，回到 spec 重议（可能需要签名）。

## Comments
