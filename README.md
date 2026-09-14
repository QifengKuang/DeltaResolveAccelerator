# 三角洲 · 主入口优化

Windows x64 客户端源码，当前版本 **1.0.4**。使用腾讯云聚通 MNA 香港线路处理指定入口解析请求，对局流量保持本机直连。

支持同时保存 Steam 与 WeGame 两个完整游戏程序路径。设置中每行填写一个 `DeltaForceClient-Win64-Shipping.exe` 的绝对路径，保存后根据实际运行进程匹配规则，切换启动平台不需要重新选择路径。只安装一个版本时也可以只填一个路径；启动时会检查所有已保存路径是否存在。

此仓库包含自有界面、后端脚本和离线测试。官方 SDK、PowerShell 运行时、安装包、设备密钥、个人设置、网络状态和日志均不随仓库发布。

## 克隆后编译与离线测试

使用 Windows 10/11 x64、.NET Framework 4.8，以及 PowerShell 7 x64。界面使用 Windows 自带的 .NET Framework C# 编译器，不需要 NuGet、腾讯 SDK、设备密钥或网络连接。

在 PowerShell 7 中克隆仓库并进入目录：

```powershell
git clone https://github.com/QifengKuang/DeltaResolveAccelerator.git
cd DeltaResolveAccelerator

# 编译需要管理员权限运行的正式客户端；编译过程本身无需提权。
./build/Compile-App.ps1

# 编译不提权的测试程序并执行全部离线回归。
./tests/Test-Offline.ps1
```

正式客户端生成在 `app/Accelerator.exe`。没有准备运行依赖与独立设备密钥时，编译成功并不代表可以连接云服务。

离线测试只在新建测试目录中使用模拟游戏文件、模拟密钥和模拟连接数据。覆盖双路径规则、旧单路径配置兼容、DPAPI 存取、原子状态写入及 UI 设置校验；不会启动游戏、SDK、TUN 或云端认证。输出位于被 Git 忽略的 `tests/output/`、`tests/ui-work/` 等目录。

可选生成模拟界面图片：

```powershell
./build/Compile-App.ps1 -PreviewBuild
$preview = Join-Path $PWD 'tests/output/settings.png'
Start-Process -FilePath ./build/AcceleratorPreview.exe -ArgumentList @('--preview', ('"' + $preview + '"'), '--preview-state', 'setup') -WindowStyle Hidden -Wait
```

## 准备真实运行依赖

项目使用 **MNA Windows SDK 0.23.1_e012851**，当前验证过的 PowerShell 运行时为 **7.6.6 Windows x64**。从各组件的官方来源取得原始 ZIP，并按照官方来源核对 SHA-256。相关入口见 [第三方依赖说明](docs/DEPENDENCIES.md)。

仓库提供离线解压脚本：显式传入两个 ZIP 和各自预期 SHA-256，不自动下载，也不读取其他电脑或旧安装目录。

```powershell
./build/Prepare-Dependencies.ps1 `
  -SdkArchive 'E:\Downloads\MP_SDK_v0.23.1_e012851_windows_amd64.zip' `
  -SdkSha256 '<经可信来源核对的 64 位 SHA-256>' `
  -PowerShellArchive 'E:\Downloads\PowerShell-7.6.6-win-x64.zip' `
  -PowerShellSha256 '<官方发布的 64 位 SHA-256>'
```

上述路径只是示例，需要替换为自己下载的文件。脚本要求目标依赖目录尚不存在，防止覆盖正在运行的 SDK。可加 `-ValidateOnly` 仅核对归档及哈希。哈希必须通过独立可信渠道核对，脚本本身无法证明归档发布者身份。

准备后目录应为：

```text
app/
  Accelerator.exe
  runtime/pwsh.exe
  backend/
    Control-Accelerator.ps1
    vendor_inspection/sdk_v0.23.1/linkboost/
      linkboost.exe
      linkboost-core.exe
      helper/multipath-helper.exe
```

运行 `app/Accelerator.exe`，接受 Windows 正常管理员提示，在设置中填写本机游戏路径并导入本机独立设备密钥。密钥由 Windows CurrentUser DPAPI 保护，不可通过复制另一个用户或电脑的 `private` 目录共享。此仓库不提供密钥或云账号。

首次配置由界面生成 `app/user-settings.json`。`gameExecutable` 保留旧版主路径字段，`gameExecutables` 保存最多两个路径；不需要提交任何个人路径到 Git。

## 连接进度

开启连接后，界面显示连接动画、后台实际执行的阶段和本次已耗时。阶段由后台状态更新驱动，不使用按时间自动前进的假进度；动画只表示任务正在处理，不能单凭动画判断连接已成功。

存在上次成功连接记录时，界面显示其耗时供参考。它不是本次的预计剩余时间或完成保证；首次使用没有历史样本时，不显示虚构参考值。实际连接完成以后台就绪状态为准。

## 流量范围与版本变化

- 固定香港区域、`speedMode 35`、mixed TUN、MTU 1500。
- 每个配置的完整进程路径仅匹配 `182.254.116.117:80/TCP` 入口解析请求。
- 固定健康探测地址使用现有自检线路，其余流量由 `MATCH,DIRECT` 保持直连。
- 1.0.4 增加连接动画、真实阶段、已耗时及上次成功耗时参考，便于观察启动过程。
- 1.0.4 收窄停止后的 IPv6 恢复判定：识别物理网卡上可确认由路由通告（RA）自动生成的 ULA 地址增减，以及同侧变化中精确对应的本地 `/128` 路由；其他差异仍需核对。
- 1.0.3 增加 Steam/WeGame 双路径，并将后台标准输出固定为 UTF-8，修复无控制台运行时中文错误乱码。
- 保留 1.0.2 的原子状态写入重试逻辑；持续写入失败仍会停止并报告错误。

成功建立线路、生成规则或通过离线测试，不能证明下一局必然使用主入口，也不能保证游戏延迟。游戏版本、HTTPDNS 行为、网络切换以及云端状态仍需要实际验证。

## 授权与共享范围

自有源码采用 [MIT License](LICENSE)。这不授予腾讯 SDK、第三方组件或云服务的额外许可，也不包含免费云服务额度。实际云服务访问取决于服务提供方、账号权限与费用。

当前源码保留既有共享试用限制：**2026-11-13 00:00:00 +11:00 截止**，界面和后端均执行此限制。本次开源没有延长或移除此限制；克隆、编译或修改个人设置不会获得新的云授权。

本次公开的是 1.0.4 源码，尚未在此仓库发布重新打包的安装程序。旧安装器和私人现场修复脚本没有纳入仓库。

## 排查与协作

另一台电脑首次接入、重启后出现旧运行记录、移动安装目录后的恢复问题，见 [本机与远程排查流程](docs/TROUBLESHOOTING.md)。本修复分支在 1.0.4 上合并了文件实际路径识别、旧启动会话归档和状态有效性检查，保留双平台路径与连接进度。恢复规则及验证边界见 [会话恢复说明](docs/SESSION_RECOVERY.md)。已有其他本地修复时仍需先备份并逐项合并。

提交问题时请描述版本、启动平台、问题时刻及脱敏后的错误文字。不要上传 `private`、`results`、SDK 运行目录、设备密钥或原始网络日志。
