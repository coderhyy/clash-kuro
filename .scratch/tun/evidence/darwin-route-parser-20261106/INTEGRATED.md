# 主会话整合

已集成route补丁7c591b87534cd721c2f4ab7ce66acb56f8fa821f724b148bf4cc761dca4f0d24及唯一有效snapshot组合补丁2d5890bd8937bee73f2af9a1830343135adaece509179b63f4dd282d7c010903。

组合在每次route backend snapshot中运行生产decoder，错误进入实际recoverSession与store；旧decoder真实得到blocked/unknown、routes: invalid route mask，fixture正常退出。修复后fresh到ready/start/stop/offready，其余6条继续通过。初始化CHECK-only旧补丁未集成。

主会话标准 node apps/desktop/scripts/build-macos-helper.mjs --test exit0，含固定Core普通用户-t、原生边界/升级/输出回归及显式7条组合。未安装服务、未运行Core会话或TUN。整合日志见integrated-native.log。候选尚未重新冻结，需提交CI及干净源码构建；不得重试eb4包。
