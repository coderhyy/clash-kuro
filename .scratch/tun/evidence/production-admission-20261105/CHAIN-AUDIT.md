# 生产启动链审计与组合回归要求

来源：49实际fresh窗口的App blocked/off失败；完整现场与清理见../first-tun-window-20261105/RESULT.md。旧包不再试。

主会话及未参与startup实现的tun_spec审计真实路径：actual main → store active Profile/Override准入 →普通模式停止 → platform SystemProxy off → macos-tun V2 → ServicePeer → serveOpenFrame →闭合schema/Authorize+activation/preflight →固定Core/安装/监督身份 → runtime/cache/owner →durable revoke/start →CONT →version/utun/内部双栈DNS →路由/DNS写入读回 →on。

唯一已证实不可达状态：初始legacy Status blocked/off；store因off跳过recover；adapter也因off直接返回；start要求ready。修复不得将初始状态盲设ready。必须通过真实调用者授权、finite安装activation及残留恢复后ready。

保留门：auth-only、安装身份/事务不符、未知owner、非闭合配置、第三方路由冲突、readback缺失；V1start有意拒绝，启动必须V2带闭合配置及持续会话。ProcessRequest旧V2及KuroNetworkRoutesReady/CoreDNSReady占位仅在已被ServicePeer提前分派后的旧fallback，非正常App可达start路径，不为展示进度全部删除。固定stack:mips已按本地固定sing-tun源码核验。

旧3086补丁仅ready的四条跨语言测试不足，不作为有限start完成。新版必须可在仓库/CI重跑：真实临时安装identity+manifest →生产Status →真实AuthorizeClientAt和KuroSessionActivationAt →actual main/store/adapter query/recover →ready → actual serveOpenFrame有限start/stop。签名原生relay用于普通UID测试，不声称Electron/root动态认证实证；Core和系统backend隔离替代，关键状态转换不mock。

至少fresh、残留恢复、错误身份、错误配置、恢复失败blocked；附owned stop ACK/ready-off但finally未退出时不冗余recover的确定性回归。不能以缺fixture env默认skip通过CI；build脚本显式提供现有native临时binary执行该组。

冻结前条件：新组合实际通过、独立审查新精确patch、停止持久性和恢复证明集成后检查、修复本次CI socket权限race并CI通过。真实Electron/root Core/utun/DNS/routes仍待新候选窗口，不由组合测试替代。

CI补充：d14073a macOS新增恢复矩阵在旧整套30秒外层budget触发ETIMEDOUT，单项断言无失败。仅协调整套native watchdog为80秒、外层90秒，不改各启动/停止/恢复期限。Windows同run出现netsh/PowerShell/UI多项超时，保留失败，不放宽业务门或断言；待整合CI验证。CI日志保留/private/tmp/kuro-d140-ci-failed.log。
