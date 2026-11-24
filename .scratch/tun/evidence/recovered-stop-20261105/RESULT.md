# 独立恢复证明集成

最终补丁efabda5ff8c0e955e76dc2ff8ccd835f67460eb620ad55ed02adc46982d50dd6通过独立审查后合入，保留fa529dd held-proof持久性。新增独立format3固定Core恢复证明，不含childReaped。原始owner字节、同安装writer/runtime/work、真实backend前后读回、证明先耐久后删除owner；未知/半写/超限证明保留。无owner不创建新权限，卸载升级job/lock/footprint门不变。

主会话标准集成检查exit0：KURO_SKIP_CORE_SYNTAX=1 node apps/desktop/scripts/build-macos-helper.mjs --test。作者23实际临时安装消费者链、8后端场景、全native和102升级中断均通过。普通UID隔离后端，不替代root/TUN真实崩溃恢复验收。

启动恢复组合链仍由另一候选补齐；本增量不代表首次网络窗口已具备条件。fa529dd CI Windows通过，macOS失败在独立普通Core socket权限断言（0666 vs0600），已另行诊断，不隐去失败。
