# 固定路径修复后的有限鉴权候选

实现提交：`e8ae1dc394ce59d447051d2a3fff4fdcd51a6492`。同一干净提交构建helper与封印auth-only/sourceCommit的Electron；证据文档单独提交。包SHA256：`98562290ab91af7372cf1d7d2c8d2145e6e1f0453adb6c1203710c3d319a6177`。完整路径/参数/负例/脚本hash见[产物清单](../../auth-observation-artifact.json)。

**新包准备完成，尚未授权或安装，未执行安装后动态鉴权。** 前次1ad5f06安装失败及授权已结束。原包仍保留原摘要，其App原件现在在`apps/desktop/dist/electron-runtime-candidate-auth-1ad5f06/mac-arm64/Clash Kuro.app`；前次精确清单追加保存于`../auth-observation-1ad5f06/artifact-original.json`。

## 路径和权限修复

- 唯一native SocketDirectory为`/Library/PrivilegedHelperTools/dev.kuro.tun-run`，auth/control/lock、fresh安装、部分恢复、卸载共同派生。TS集中端点与连接前祖先校验，脚本共用authEndpoint；跨语言一致性回归通过。
- 保持严格root所有权、非symlink、无group/other-write、空ACL策略；不修改/private/var/run。已有public祖先和run目录必须可由普通用户搜索，0700拒绝而不chmod。端点0666允许普通连接，lock0600；连接不授予操作权限。
- auth/control分别57/60个UTF8字节；sun_path含NUL容量104，103接受、104拒绝，bind前检查不截断。
- root:daemon0775仍拒绝，错误包含路径与mode原因；owner/symlink/ACL也附路径。旧run叶存在就保留并拒绝fresh，不迁移/连接/删除。

## 验证结果与范围

- native全套通过（显式KURO_SKIP_CORE_SYNTAX=1），含真实host旧0775拒绝与新祖先只读ACL/metadata/search检查、普通UID临时两端点连接、7 inventory负例+19 fresh失败恢复及准确卸载场景。
- desktop485通过/16跳过、typecheck通过；同提交真实Electron隔离矩阵14通过。没有运行真实Core管理。
- 离线解包seal/pin、完整inventory与preflight helper一致；9个固定bundle、1255条BOM预期root owner、disabled plist确认。BOM不代替实际安装权限。
- 准备时新旧目标路径、job与Installer receipt无冲突；授权开始前必须重新核对。

普通UID临时socket连接和root祖先只读检查不能替代安装后的实际Electron正例。下一步仍仅[有限auth实验](../../auth-observation-experiment.md)：8–12分钟、fresh安装→前台auth-only→正负例→等待退出→准确卸载和receipt清理；不bootstrap job、不运行Core/-t或网络操作。异常仅按预先批准回执恢复，无法确认时保留停止。

06恢复增量已包含，但ESRCH仅证明记录Core进程不存在，不证明所有后代退出；真实mihomo及网络恢复留给另行实验。完整升级和正式集成验收尚未完成，生产启动门保持关闭。
