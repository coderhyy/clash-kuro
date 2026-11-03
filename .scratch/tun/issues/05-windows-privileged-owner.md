# Windows TUN 权限与单一 Core owner 适配

Status: needs-info
Type: task
Blocked by: 03；D1 纳入 Windows；01/02 后选定权限机制（02 资料研究已完成）
Owner: Windows 平台 agent

## 负责范围

03 划定的 Windows 权限/owner 适配、native helper/协议及 Windows 资源构建测试。现有 `resident-*`、Platform 公共入口和 CI 修改由主会话协调；不改 State/UI。

## 验收标准

- 只有一个准确 Core owner；提权后仍按批准方案处理当前用户 WinINet、私有 IPC 和所有权验证，不新增竞争代理 writer。
- 获准 TUN 产物和权限路径可用；拒绝/取消授权、启动失败、owner 丢失、关闭超时有明确结果及 fake 负例。
- 保留 ADR-0013 的首次触发预算、关闭写入、停止/需重启和未知状态语义；若 TUN 需要改变，先回到 01/03 批准，不在适配中自行延长预算。
- 受影响 native 测试、TypeScript 测试、类型检查与 Windows CI 通过，精确产物身份可追溯。
- 真实路由、会话与恢复验证在 07/08 记录；旧普通退出/注销/关机样本不能自动成为 TUN 验收证据。

## Comments

2026-11-04：主会话已核实 issue 08 合入 `origin/main 6ea3720`、PR #1 MERGED，原主线整合依赖满足；最终集成 CI 由主会话核验。共享契约与权限选择仍待决定，本票尚未实现。
