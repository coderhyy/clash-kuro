# 安装边界隔离模型（非生产）

2026-11-04 本机运行：

```sh
python3 .scratch/tun/prototypes/helper-install/check_install.py
```

结果：16 tests，OK。标准库 unittest，无新增依赖、root、真实进程执行、launchctl、安装、网络或系统配置写入。仅在 TemporaryDirectory 创建文本假产物，以当前 UID 模拟受保护 owner；脚本不进入生产打包。

覆盖合法固定清单、文件/manifest/版本目录 symlink、可写目录/可执行文件、错误 owner、硬链接、Core 路径替换、helper 字节修改、manifest 与匹配恶意摘要同时修改、额外路径字段、重复 JSON 键、大小限制，以及打开 FD 后 pathname 替换仍读取原 inode。使用 dirfd/O_NOFOLLOW 检查单一固定组件，只返回已读字节，不按批准路径重开执行。

首次运行是15/16：原 setuid 用例 chmod(04755) 后未触发拒绝，因此不能认作真实 setuid 拒绝成功。修正后的 `test_setuid_core_metadata` 直接模拟 fstat 返回含04755的普通文件元数据，证明 exact mode 检查拒绝该输入，不设置真实 setuid。**元数据模拟与真实文件系统权限测试不同**；生产真实权限验证仍未完成。

限制：fixture anchor 由测试提供，未验证真实 /Library 祖先/ACL/root owner；没有安装授权、代码签名、完整 Electron 资源、manifest 初始信任来源、同时写入竞态压力、执行 FD/已保护路径或 launchd 事务的证明。FD 路径替换用例仅证明读取对象固定，不证明未来按路径执行安全。本模型的 independently pinned manifest hash 由 fixture 提供，生产必须来自管理员批准并受保护的安装记录，不能信客户端或 manifest 自我声明。
