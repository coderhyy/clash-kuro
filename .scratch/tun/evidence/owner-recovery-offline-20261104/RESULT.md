# 06：有界旧owner/work恢复增量

本轮主会话严格clang编译并运行全量native fixture通过，`KURO_SKIP_CORE_SYNTAX=1`。普通UID临时目录/socket及无网络进程fixture；未执行mihomo/-t、安装、root服务或真实系统网络。17个聚焦恢复场景覆盖旧/非法收据、存活/复用/无法观测PID、未知/改动配置及socket、nil读取拒绝、部分删除后身份变化和安全重试。

未来format2 owner记录运行时配置SHA256及首次验证socket的device/inode。重启后不kill/adopt旧PID，只有重复明确ESRCH、保护收据仍一致、existing network absence hook通过后，才清退精确配置/socket/目录，最后清owner；未知对象和旧format1有work均保留。ReadProtected失败显式拒绝，避免nil被Hash成空内容摘要。

这仅证明记录进程absence，不证明后代/进程组退出。真实mihomo脱组行为及真实网络恢复仍未验收；现有network-only recovery为absence-only，实际DNS/route仍存在时保守拒绝。生产activation门未改。未重建或修改1ad5f06授权观察包。
