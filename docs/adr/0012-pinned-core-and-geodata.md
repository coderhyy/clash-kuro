# Core 和 Geo 数据锁版本随包分发

`apps/desktop/core.lock.json` 记录 mihomo 的版本标签、每个平台安装包的 URL 和 sha256，以及 Geo 数据（`Country.mmdb`、`GeoSite.dat`、`ASN.mmdb`）所在的 meta-rules-dat 提交和各文件 sha256。`scripts/fetch-core.mjs` 构建时下载并校验，任何哈希不匹配都让构建失败；URL 必须钉在标签或完整提交上，不允许 `latest`。

Geo 数据选择锁版本打包，没有选择“关闭 `geo-auto-update` 加配置下载地址”。原因：

- 首次启动不依赖网络。订阅里的 `GEOIP`、`GEOSITE`、`IP-ASN` 规则在 `mihomo -t` 阶段就要读取数据，文件不在时 mihomo 会去 GitHub 下载；在需要代理才能访问 GitHub 的网络里，这一步会失败，导致 Runtime Config 校验不过、Core 无法启动（2026-10-30 用 v1.19.33 实测）。
- 可复现。同一版本的安装包行为一致，Geo 数据和 Core 一样随应用升级（ADR-0005）。
- 代价是安装包增加约 21 MB（三份文件合计），以及数据会随时间变旧，要靠发版更新。

App-managed Fields 因此加入 `geo-auto-update: false`，Runtime Config 不让订阅打开自动更新。Geo 文件在启动前复制到 Core 的数据目录，文件名用 mihomo 默认名（`Country.mmdb`、`GeoSite.dat`、`ASN.mmdb`），不设 `geox-url`。`geodata-mode` 保留订阅的设置；订阅若打开 `geodata-mode: true`，mihomo 需要的 `GeoIP.dat` 没有随包分发，会在首次使用时下载。

## Consequences

- 升级 Core 或 Geo 数据只改 `core.lock.json`，需要同时更新 URL 和 sha256。
- mihomo 的 GPL-3.0 许可证文本也锁定哈希，随包放在 `licenses/`（ADR-0006）。
