# 固定 control.sock 生命周期修复

本记录不代表 TUN 转发或网络恢复验收通过。用户另行批准的一次清理现已完成：固定socket、原740安装与准确Installer receipt均清除；job/App/Core缺席，原format3及清理证据已归档。

## 已确认根因与最小修复

原fresh卸载只接受service.lock/auth.sock，生产Serve却创建control.sock。卸载在目录白名单阶段拒绝，尚未删除安装文件。现场socket究竟来自哪一种退出分支尚未确认；不能将它推定为worker超时。

统一固定端点检查用于Serve启动前、Serve退出、fresh/legacy卸载及升级静默检查：受保护祖先、准确service.lock持锁、socket类型/owner/mode/nlink、无监听者（仅ECONNREFUSED接受）、删除前同dev/inode/uid/gid/mode/nlink复核。Serve退出只清理自己实际绑定的inode；worker未排空时锁保留至进程退出。升级仅检查，不删端点。未知文件仍拒绝；legacy批准记录移至目录/锁/端点检查之后。无新增CLI、receipt格式、组件或任意路径入口。

## 真实隔离验证

实际ServeAt/ServicePeer在普通用户私有目录创建Unix socket、accept状态请求并响应退出；正常退出、异常退出残留后重启、残留后实际service/network恢复及Uninstall均有执行证据。恢复使用真实持久DNS journal及状态层，仅系统DNS后端替换为内存对象。负例覆盖占锁、独立活监听者、regular/symlink、错误mode、替换inode及其他未知文件，并保留安装身份。drain负例只在未获授权的authorize处阻塞，Core/preflight/start钩子调用必须为零。

原740源码消费者已读取现场原始format3字节并接受；实际611项App和安装文件复制到隔离前缀，唯一有意省略计划退役的control.sock，原Uninstall返回成功且目标缺席。普通UID映射与system:NO不替代现场root、job、执行入口和元数据复核。

原始安装、进程和机器证据只存本机临时目录，不提交远端。最终受限清理必须另行授权，先核新工具与原安装全部固定摘要及准确socket身份，再调用不变的原740卸载器；任何不符即停止，无自动重试。

## 授权后的实际结果

07918b8b冻结清单34项及固定support全部复核；socket-only工具exit0，原740 Recovery卸载exit0。安装11路径与固定socket缺席，独立job查询113，own process匹配为空；receipt forget0，查询1。工具成功包含原安装/证明/准确job及进程组缺席、原锁独占、固定socket无监听者及删除前身份复核；未运行Core或服务、未修改网络。新root0700证据 `/private/tmp/kuro-740-socket-retirement-authorized-etnhqtus`，独立只读结果 `/private/tmp/kuro-740-socket-final-readonly.json`。旧诊断、原恢复/实验记录和候选用户数据保留，授权随窗口结束终止。
