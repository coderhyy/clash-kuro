# 本会话 utun 的 IPv6 多播伴生路由

真实11902日志拒绝 `ff00::%25/8`，gateway=`fe80::dca2:909d:93a3:558e%25`，held=`utun6/25`，flags=`25166081`。其为`UP|CLONING|MULTICAST|IFSCOPE`，没有GATEWAY/STATIC/HOST/PROTO2。

两名独立agent交叉核对Apple XNU固定提交和现场已有utun0–5：IPv6地址配置在IFF_MULTICAST路径自动创建ff00/8、ff01/32、ff02/32，gateway取接口当前地址、scope取ifindex；已有六个接口各有三条相同形状，清理后旧接口保持不变，本次utun6及该条目消失。该证据支持系统伴生路由分类，不证明任意第三方改动或跨重启归属；运行内核未做逐build源码对应证明。

实施只读识别候选限定三种精确prefix/规范zone、精确flags、同held Core接口name/index、实时唯一link-local/64地址匹配gateway。所有其他新增条目拒绝，所有baseline父路由仍固定；不添加删除这些伴生条目的权限，停止依赖准确Core/utun退出后核验缺席。

同时独立核验下游IPv6非host路由PRCLONING内核追加语义；有充分源码依据才补精确读回模型，绝不mask所有未知flags。此记录不是代码或真机通过结论。
