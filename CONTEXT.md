# Clash Kuro

mihomo 的精简桌面客户端：管理订阅，启停 mihomo，切换模式和节点，开关系统代理。

## Language

### 配置

**Profile**:
一份 mihomo 配置的来源，分远程（订阅 URL）和本地（YAML 文件）两种。原始内容只读，应用从不修改。
_Avoid_: 订阅（仅在指远程 Profile 时作口语）、配置文件

**Active Profile**:
当前启用的那一份 Profile。同一时间只有一份。
_Avoid_: 当前订阅、选中配置

**Subscription Info**:
远程 Profile 响应头 `subscription-userinfo` 给出的已用流量、总流量和到期时间。
_Avoid_: 流量信息、套餐

**Update Interval**:
远程 Profile 自动更新的间隔。取自响应头 `profile-update-interval`，缺省 24 小时，用户可改。

**App-managed Fields**:
由应用持久保存、并覆盖 Profile 中同名字段的配置项：模式、mixed-port、allow-lan、log-level、`profile.store-selected`、`geo-auto-update: false` 和控制通道。
_Avoid_: 覆写（覆写是第二期的独立功能）

**Runtime Config**:
Active Profile 加上 App-managed Fields 合成、经校验后交给 Core 加载的配置。
_Avoid_: 合并配置、最终配置

### 运行

**Core**:
mihomo 进程本身，随应用打包、由应用启停。
_Avoid_: 内核（中文口语可用，代码与文档用 Core）、clash

**Control Channel**:
应用与 Core 之间的本地 API 通道：macOS 上是 unix socket，Windows 上是 named pipe。
_Avoid_: external controller、API 端口

**Orphan Core**:
应用异常退出后仍在运行的 Core。凭 pid 文件发现，且只有可执行路径与打包的 mihomo 一致时才视为 Orphan Core。

**Mode**:
Core 的路由模式：rule、global、direct。
_Avoid_: 代理模式（易与 System Proxy 混淆）

**System Proxy**:
操作系统级 HTTP/HTTPS 代理设置，指向 Core 的 mixed-port。
_Avoid_: 代理开关

**Proxy Group** / **Proxy**:
Profile 中定义的策略组和其中的单个出站节点。用户的"节点选择"即在 Proxy Group 里选 Proxy。
_Avoid_: 线路、服务器

### 外壳

**Command**:
界面或托盘发给主进程的一次有类型的操作请求，如切换 Mode、选择 Proxy、更新 Profile。
_Avoid_: action、IPC 调用

**Platform**:
桌面端（或将来移动端）提供给共享包的系统能力集合：启停 Core、System Proxy、文件读写。
_Avoid_: native、bridge

**Tray Mode**:
窗口被销毁、只剩托盘的运行状态。此时状态由主进程持有。
_Avoid_: 后台模式、最小化
