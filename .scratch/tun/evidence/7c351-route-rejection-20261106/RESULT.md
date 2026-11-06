# 7c351真实窗口：双族utun创建，路由保护拒绝

精确源码7c3511f1193df258fb123b0fc9eef844b0a3cef7；包SHA256 05f11d41e0db8b9108d2b6066ec05389d77679b8a71ffe2a46a7af9e97094c1e。CI42156320520第二次双平台通过，第一次Windows collector timeout与origin响应同步失败保留。后者独立测试修复610836f，不追认旧CI初次成功。

同版本production readonly preflight与实际包独审通过。fresh安装、实际App seal/inventory/source及helper/Core匹配，实际App鉴权恢复ready/off。已启用Profile文件SHA8e219e0a9098cbe6c617862e07e19951a225aaf606478ff46b6b3f167874b00a保持。

一次TUN开启实际创建utun6([198.18.0.1/30],[fdfe:dcba:9876::1/126])，随后原守卫返回unexpected route appeared while creating Core utun; refusing takeover。客户端准确显示原始错误，没有旧2秒超时覆盖。未达到on、未运行流量探针，不能宣称正常启停通过。日志终态SIGTERM/exit0、captureComplete=true、networkRecovery restored=true；保护State保留stopped.json，无owner/session-work/网络journal。当前准确卸载脚本已发起，等待管理员操作，尚未记为卸载完成。

证据目录/private/tmp/kuro-7c351-window-2ve0msza；新root诊断/Library/Application Support/Clash Kuro/TunDiagnostics/DFE80FC0-E987-4475-8FF6-70D03E352369，均保留。原通用错误不包含被拒路由，不能猜测放宽。最小diagnostic-only补丁14125fdd95961fca3f5ccb9673e7338124b8c1f40cc37ee7b38ccbb9f5ce53c5已独审：原guard不变，仅精确closed7field/阶段/heldinterface进入既有错误诊断，≤1024B；3生产coordinator假backend回归与严格编译通过。真实条目待下一次受控证据。

安装前raw route变化曾阻止脚本（当时未安装）；只读复核后比较直接使用同版本生产KuroStableRoutes投影，DNS/interfaces严格相等，不另写宽松过滤。原raw快照均保留，未修改第三方设置/网络。
