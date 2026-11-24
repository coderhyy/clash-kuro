# 自有路由缺席恢复修复（仅离线验证）

根因：v2恢复在自有路由缺席核验前要求全部系统稳定路由等于启动前快照。物理地址变化因此阻止停止证明，不能据此推导本应用仍有网络残留。

改动：保留完整安装、owner、writer退出、原utun、固定key与地址池、两次DNS读回及持久退役；外部路由差异仅记录，不写路由。同actor在journal退役后若诊断或work清理失败，保留原记录用于下一次拒绝和报告，不重建journal、不增加删除权。原closed proof/RPC不变。启动和active全局路由门本次未改。

精确补丁SHA256 `74fd077731b9536428d2a17d73a05e9aad3a2d5cee2f9c4aed30fc2a937b97ea`，base `6da324e03e2caf3182f6952178f82e4384bd71f0`。独立审查PASS，含sameactor失败后重试。旧方法+新回归运行RED、新实现GREEN；覆盖外部路由替换、第二次快照新增原utun/地址池足迹、真实无害child afterReap诊断及work失败。

集成验证：`KURO_SKIP_CORE_SYNTAX=1 node apps/desktop/scripts/build-macos-helper.mjs --test` 沙箱外普通用户exit0：native-suite、临时upgrade-suite、8条生产admission链与output-suite全部通过。首次沙箱运行因临时Unix socket bind被拒失败，记录保留；未改变断言。明确跳过真实Core语法进程，不执行系统安装、服务或网络操作。

本轮不证明真实恢复或转发成功。当前安装仍保留，需另行批准精确恢复工具；工具独审不能由本补丁PASS替代。IPv4 ENETUNREACH仍未定因；下一次网络实验尚未授权。机器原始记录仅保留本机，不随此摘要上传。
