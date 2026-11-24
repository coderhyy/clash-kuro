# 有限动态鉴权实验通过，精确清理完成

本次授权只覆盖实现提交`e8ae1dc394ce59d447051d2a3fff4fdcd51a6492`、包SHA256 `98562290ab91af7372cf1d7d2c8d2145e6e1f0453adb6c1203710c3d319a6177`。2026-11-04执行；最终核对完成于20:52:31 +08，本次授权结束。

## 实际结果

1. **实际安装Electron正例通过。** 固定安装路径App的seal/pin、inventory与root安装回执匹配后，真实进程请求生产同一鉴权路径，返回authenticated=true、nativeRejected=false，进程exit0。非原生fixture替代证据。原始结果见`clients/installed-result.json`。
2. **身份负例明确拒绝。** 重签Electron返回`client resources or exact approved identity are unavailable`，nativeRejected=true；外部Node收到`client hardening is insufficient`。没有将超时或协议错误算作身份拒绝。修改ASAR副本另做离线seal拒绝，未启动；它不是动态RPC结果。
3. **非观察操作全部拒绝。** 正例之后，start/open/stop/recover/exec均返回`auth observation accepts only version-1 authenticate`。观察成功没有token/lease/生产会话授权；未运行Core或真实TUN。
4. **精确清理完成。** 观察进程正常到时exit0；固定卸载入口exit0；确认批准安装路径消失后，核验Installer receipt的1254条清单与本包一致，pkgutil forget exit0。最终本次App/helper/版本目录/socket目录/身份记录/fresh与recovery回执/plist均不存在，job和Installer receipt不存在，精确路径进程快照无匹配。详见`final-state.json`。

未bootstrap/启动LaunchDaemon job，未运行Core/-t，未修改代理/路由/DNS/登录项或注销。未调用kill，未自动覆盖冲突或放宽检查。期间receipt初检脚本曾把install-location空字符串误当成非根目录；只读核对后按volume `/` + location空串解析为 `/`，与PackageInfo安装根一致，1254条文件无差异后才允许forget。没有身份或路径冲突。

保留诊断材料：源码工作区中的批准包、负例prepared目录、客户端隔离临时数据与复制到本目录的原始响应/日志/摘要；它们不是系统安装或运行残留。现有App/用户数据、系统共享父目录和Installer历史日志保留，未扩大删除范围。

## 证据边界

本次证明实际受保护安装App的有限动态身份鉴权及fresh精确卸载；不证明真实Core/utun、路由/DNS、完整升级或异常网络恢复。生产启动门仍关闭。06的ESRCH证据只证明记录Core不存在，不证明所有后代退出。下一系统实验必须单独准备并重新授权。
