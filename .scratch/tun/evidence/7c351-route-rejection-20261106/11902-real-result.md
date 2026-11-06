# 11902 实机精确拒绝证据

源码11902bc18b6e552385829b3070591da4078fae0d，包0f1ab77ef06d1e800e3b838821f73d55584fa8790c3c8e30f0c70280bedec3a0。CI42159286109双平台首次成功、实际包独审及同版本生产只读预检通过。fresh安装/实际App身份及ready恢复通过。

一次正常开启创建双族utun6，原guard拒绝：phase=Core startup; owned-interface=utun6/25; observed={"destination":"ff00::%25","family":6,"flags":25166081,"gateway":"fe80::dca2:909d:93a3:558e%25","interfaceIndex":25,"interfaceName":"utun6","prefix":8}。

Core SIGTERM/exit0、captureComplete/networkRecovery restored均true；State仅Inbox/client/installed/stopped，owner/work/journals缺席。未发流量探针，未验正常on→off。App已正常退出，精确卸载及receipt清理成功，job/进程/安装/socket/身份记录独立确认缺席。代理/DNS与root基线相等，完整production preflight成功且生产稳定路由投影相等，raw动态缓存变化保留。原始受限证据/private/tmp/kuro-11902-window-b260j13r；root诊断/Library/Application Support/Clash Kuro/TunDiagnostics/80CB194B-A0E6-4137-89C0-956B244A37FE。

独立Apple XNU源码核验与同机baseline utun0–5交叉核验确认：配置IPv6 multicast接口时系统伴生ff00/8、ff01/32、ff02/32，flags0x01800101为UP|CLONING|MULTICAST|IFSCOPE。现场具体拒绝只显露ff00/8，其余两形状由源码及六个旧utun佐证，不冒充本次已捕获。拟最窄生产识别仍要求heldname/index/zone、精确flags和实时唯一linklocal gateway；不新增删除权，未知和第三方仍拒。该公开XNU版本不是运行内核逐build证明，证据见../utun-multicast-20261106/source-review.json。
