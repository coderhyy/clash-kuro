# 调研：Windows System Proxy 立即生效

Status: ready-for-agent
Type: research

和 01 同时做。只查资料、写小实验（放在仓库外），不改仓库代码。结论追加在本文件 `## Answer` 下。

## 要回答

- 不引入 Node 原生模块，怎样设置当前用户的代理并让已打开的程序立即生效（`InternetSetOption` 通知）。候选：PowerShell 调 WinINet、小 helper exe、其他。
- 每个方案是否需要提权、耗时、是否被杀软拦截、如何打包进安装包。
- 如何读取当前代理，用于“启动时只清理指向本应用 mixed-port 的代理”。
- 推荐方案及其在 `Platform` 接口下的调用方式。
