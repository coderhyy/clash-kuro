# 唤醒后不重载配置

最初计划休眠唤醒后热重载配置。改为：唤醒后检查 Core 是否存活，存活则 `DELETE /connections` 清掉失效连接，已退出则重启 Core；System Proxy 幂等重设。重载会重建 provider 并重新测速，代价大，而唤醒后真正失效的只是连接。
