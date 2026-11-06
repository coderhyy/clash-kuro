# c138 生产只读预检拒绝，未安装

用户已批准正常启停持续窗口：同范围明确失败后可修复、回归、独审、必要CI、冻结新候选并重试，前轮状态须明确恢复清理；不扩大到helper强杀/App-on退出/升级。通过或用户暂停才结束持续授权。

包c138652131a6bf9035225b0ff93b74b9c360b21d SHA f3b7fbdbb3fc7f49da44b9006418fc9cbc24cb6a1ebcd503f9adf0fed2c9f8d8与原批准router Profile SHA8e219e0a9098cbe6c617862e07e19951a225aaf606478ff46b6b3f167874b00a核验一致。安装目标/receipt/job无冲突，进程无第三方活动Core/App；网络基线与eb4清理后相同。

在安装前，通过同版本14份生产源码编译的只读工具直接读取真实Darwin route/DNS/interface，调用实际KuroProductionNetwork.preflightConfig；不复刻准入、不调用recover/writer/Core/service。生产TS createTunSessionConfig由精确批准Profile生成JSON SHA23e050864b7070f77e400fbe08904757276ebaf549ff7d258f473b41698f74de。工具SHA9142581102437697d9f34dca3ef908ff4e132759fc1fec72fb53111f26331b55。

实际root只读结果exit2：配置、216条路由与接口读取成功；后续默认出口/物理接口/固定地址池/LAN端点检查因DNS失败尚未执行，不称完整准入通过；DNS原始Global记录含__CONFIGURATION_ID__、__ORDER__、__IF_INDEX__、__FLAGS__，被真实preflight拒绝：`unsupported DNS resolver field __CONFIGURATION_ID__; preserving existing configuration`。没有静默删除字段/宽松重试。

c138没有安装、没有服务/Core/TUN或网络写入，故无本次安装清理。预检后代理、DNS/dynamicDNS、双族路由逐字节等于本轮基线。受限证据 `/private/tmp/kuro-c138-window-lauz6lg8`、工具 `/private/tmp/kuro-production-preflight-c138`、配置来源 `/private/tmp/kuro-profile-config-c138` 均留本机，不公开原始网络数据。

下一步DNS已知系统元数据兼容及生产组合回归，保留严格类型/语义与原始快照，独审后同版本预检；未声明真实TUN通过。持续授权未结束，不重新逐包索取授权。
