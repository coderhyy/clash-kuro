# MVP spec

术语见 `CONTEXT.md`，架构决定见 `docs/adr/`。

## 范围

- 平台：macOS、Windows（ADR-0005）。
- 功能：导入 Profile（远程/本地）与定时更新；Core 启停；System Proxy 开关；Mode 切换；Proxy Group 中选择 Proxy；托盘。
- 第二期：TUN、覆写、Linux、特权 helper、开机自启、签名与自动更新、英文界面、导入导出。

## 约定

- 工具链：bun 1.4.4 workspaces + Turborepo 2.11.10（ADR-0011），electron-vite + electron-builder，Vitest。
- 测试重点是 `packages/core` 的纯函数；主进程暂不做 E2E。
- 界面：shadcn/ui（Base UI + Tailwind v4，ADR-0007），文案走 i18n 资源，只提供 zh-CN。
- 开发顺序：01 定接口 → 03–06 四路并行（各用独立 worktree）→ 07 集成；02 调研与 01 同时做。并行期间改接口，必须先回主干改。
- 数据目录：`app.getPath('userData')`，卸载不删。

## 行为规则

- 定时更新：间隔取 `profile-update-interval` 响应头，缺省 24 小时，用户可改；先直连，失败再经 Core 代理重试一次；失败保留旧内容并标出，下个周期再试；读取 `subscription-userinfo`。
- Active Profile 更新后自动生成 Runtime Config 并重载；`mihomo -t` 失败保留旧配置并提示（ADR-0003）。
- Orphan Core：pid 文件对应进程的可执行路径与打包的 mihomo 一致才 kill，否则只删 pid 文件。
- 启动时只清理指向本应用 mixed-port 的 System Proxy。
- 退出、关机、注销：先关 System Proxy 再停 Core，带超时，不阻塞关机。
  - Windows 上注销、关机时做不到（草案 ADR-0013，待确认）：注销开始后新启动的 helper 在 DLL 初始化时就被结束（0xC0000142 / 0xC000026B），会话结束前的同步清理可能失败。兜底是 RunOnce 在下次登录时清，再加上 Kuro 启动时的清理；注销/关机到下次登录之间，代理仍指向已停止的端口。普通退出不受影响。
- mixed-port 被占用：启动前检测并报错，不自动换端口。
- 唤醒：Core 存活则 `DELETE /connections`，否则重启 Core；System Proxy 幂等重设（ADR-0008）。
- macOS `networksetup` 权限被拒：提示用户手动设置 127.0.0.1:mixed-port（ADR-0009）。
- 新版本：启动时查询 GitHub Releases，有新版提示手动下载（ADR-0010）。
