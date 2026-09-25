# 第三方依赖

本仓库的 MIT License 仅覆盖本项目自有源码和文档。下列组件不随源码提交；使用或再分发时应遵循它们各自的条款和通知。

| 组件 | 用途与当前适配版本 | 官方入口 |
| --- | --- | --- |
| .NET Framework | Windows 界面，4.8 | [Microsoft .NET Framework](https://dotnet.microsoft.com/download/dotnet-framework/net48) |
| PowerShell | 后台脚本，当前验证过 7.6.6 Windows x64 | [PowerShell 源码与发布](https://github.com/PowerShell/PowerShell) |
| 腾讯云聚通 MNA | Windows SDK 0.23.1_e012851；香港解析线路 | [产品文档](https://cloud.tencent.com/document/product/1385)、[Windows 可执行程序 API](https://cloud.tencent.com/document/product/1385/126853) |

PowerShell 的主项目使用 MIT 许可，包含的模块可能另有许可。使用官方完整 ZIP 时保留 `LICENSE.txt`、`ThirdPartyNotices.txt` 和模块原有许可文件。

本项目不能授予腾讯 SDK 的再分发权或云服务使用权。请自行从有权访问的官方渠道获取 SDK，确认适用条款，并使用对应电脑获得授权的设备密钥。不要将运行过的 SDK 目录打包给他人，其中可能含有设备身份、配置和日志。

`build/Prepare-Dependencies.ps1` 只核对调用者传入的 SHA-256、校验归档路径并解压到固定的 Git 忽略目录。SDK 原始 ZIP 应直接包含 `linkboost/` 目录，PowerShell ZIP 根目录应直接包含 `pwsh.exe`。归档解压前后均不执行其中的程序。

如手动准备，先确认加速器已停止且退出，将干净的 SDK 原始 ZIP 解压至 `app/backend/vendor_inspection/sdk_v0.23.1/`，将 PowerShell 官方完整 ZIP 解压至 `app/runtime/`。不要把已有的 `private`、`results`、`user-settings.json` 或运行生成的 SDK 文件合并进新目录。

本仓库不含 Inno Setup、第三方安装器引擎或第三方语言文件。构建脚本可产生本项目自有客户端、轻量安装器和完整自有程序包；这些产物均不携带上述第三方运行依赖，也不授予其再分发许可。
