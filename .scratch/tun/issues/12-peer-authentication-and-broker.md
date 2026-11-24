# 无付费签名的调用者鉴别与有限控制通道

Status: resolved（仅任务归并；不是实现完成）
Type: task
Blocked by: 无（本票停止独立跟踪；未完成项及技术依赖由主票承接）
Owner: [04 主票](04-macos-privileged-adapter.md) 的负责 agent；主会话协调

## 归并结果

本票已并入 [04 主票](04-macos-privileged-adapter.md)，不再独立排期或作为主票的外部阻塞。原范围、验证和未完成项保留如下作为历史；归并不是安装、认证、TUN 接入或真实验收完成。最新批准策略与执行状态以主票、spec 和 ADR-0016 为准。后续结果写回主票 Comments，等待最终源码与验证证据。

## 归并前记录（历史，未完成项已转主票）

## 负责范围

从 04 拆出身份与通信部分，依据 [安全方案](../macos-helper-security.md)。复用外部原生 helper，不引入 Node addon/FFI。原语和纯协议测试可与 11 并行；固定协议与安装清单经主会话确认后才接入生产。

## 验收标准

- 从内核取得连接身份，不信请求方 UID/PID/hash；同 UID 不自动授权。身份 pin 由管理员安装确认，更新须走安装事务。
- 完整检查允许程序及其资源、受保护路径和启动方式；明确 Electron app.asar、调试/脚本注入边界。单个主执行文件 CDHash 或共享 secret 不构成完整信任链。
- helper 仅提供有限操作；没有任意 root shell、exec、文件路径、HTTP 转发。若 Core 以 root 运行，控制 socket 保持私有，仅 broker 校验后的操作可访问，不暴露 PUT /configs、升级或 provider 路径等绕过入口。
- 逐操作限制参数/大小、并发和会话；拒绝未认证、未知操作、额外字段、重放旧会话、版本不兼容、异常后迟到写入；客户端消失触发有界停止清理，不自动重启 TUN。
- 测试区分身份原语成功与完整认证成功；权限或归属证据不足拒绝，不降级为仅 UID 校验。

## Comments

2026-11-04：主会话完成[普通用户 C 原型](../prototypes/peer-identity/README.md)：LOCAL_PEERTOKEN/audit-token 动态身份检查可接受固定 ad-hoc 可执行文件、拒绝同 UID 的不同 ad-hoc 可执行文件。两分支通过、编译警告视为错误；无管理员权限或服务安装。此结果不证明 Electron 完整资源/注入边界或生产认证已安全，剩余验收保留。


2026-11-04：按维护者要求归并至 [04](04-macos-privileged-adapter.md)；本票历史证据不改写成新的通过结论。
