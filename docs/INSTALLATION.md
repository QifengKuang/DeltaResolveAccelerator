# 安装、快捷方式与自动更新

当前完整版本为 **1.1.1**，包含新的后端恢复模块。请先阅读 [完整构建与部署说明](BUILD.md)。本文的普通安装更新命令和签名自动更新通道仍只替换界面；下面的 1.1.0 版本路径用于说明旧通道，不能获得 1.1.1 的后端修复。

## 固定安装位置

默认安装目录是 `%LOCALAPPDATA%\Programs\DeltaResolveAccelerator`。首次安装可用 `-InstallDirectory` 选择另一个长期使用的本地目录；位置保存在 `HKCU\Software\DeltaResolveAccelerator\InstallPath`，后续安装和修复自动沿用。已有安装不通过重新选择目录来搬迁，避免产生第二份程序和不同的设备配置。

桌面和开始菜单里的 `三角洲加速器.lnk` 都指向安装目录的 `DeltaLauncher.exe --launch`。工作目录与安装目录一致，图标来自独立的 `DeltaResolve.ico`，不依赖更新时被替换的 EXE 图标资源。快捷方式关闭分布式文件追踪，防止 Windows 跟随被替换的文件跳到构建目录。每次修复原位替换同名快捷方式，不添加副本。

安装器拒绝临时目录、Git 工作区、链接或联接目录、应用包缓存及网络路径。写入前后用 Windows `GetFinalPathNameByHandle` 验证真实路径；如果 MSIX 宿主将文件重定向到自己的缓存，安装会停止。遇到此提示，应从普通 Windows 终端运行安装器，不能绕过校验后继续。

## 更新已有安装

安装脚本使用 PowerShell 7。已有安装自带的 `runtime\pwsh.exe` 可以运行它。先停止加速并关闭界面，然后运行：

```powershell
& "$env:LOCALAPPDATA\Programs\DeltaResolveAccelerator\runtime\pwsh.exe" -NoProfile -File .\build\Install-App.ps1 -SourceDirectory .\app
```

默认只替换四个自有文件：`DeltaLauncher.exe`、`Accelerator.exe`、`Accelerator.exe.config`、`DeltaResolve.ico`。本机后台脚本修复、运行时、SDK、设备密钥、网络恢复状态、日志及游戏路径设置均保留。

正在运行的界面、启动器或 SDK，以及尚未安全停止的连接状态会阻止替换。安装器和自动更新器使用相同的每安装目录互斥锁；安装期间还持有界面锁。每个文件先备份再原子替换，失败时恢复已变更文件和原快捷方式。记录和备份留在安装目录 `.installation` 下。

只修复快捷方式时，无需关闭界面：

```powershell
& "$env:LOCALAPPDATA\Programs\DeltaResolveAccelerator\DeltaLauncher.exe" --repair-shortcuts
```

也可以用 `Install-App.ps1 -RepairShortcuts`。若独立图标或程序文件已缺失，请使用完整安装包修复，而不只是重建快捷方式。

## 首次安装与第三方依赖

轻量引导包只包含安装脚本和上述四个自有文件，适合修复和升级已有安装，不重复下载已有运行环境。

全新电脑需要显式提供干净的 PowerShell 和 SDK 目录。请按 [第三方依赖说明](DEPENDENCIES.md) 获取原始依赖，保留许可和通知文件，然后从源码目录安装：

```powershell
pwsh -NoProfile -File .\build\Install-App.ps1 `
  -FreshInstall -SourceDirectory .\app `
  -InstallDirectory "$env:LOCALAPPDATA\Programs\DeltaResolveAccelerator" `
  -PreparedRuntimeDirectory .\app\runtime `
  -PreparedSdkDirectory .\app\backend\vendor_inspection\sdk_v0.23.1
```

首次安装仅复制明确列出的自有后台脚本，以及调用者提供的干净依赖。输入中的私有目录、设备身份、生成的配置和日志会被拒绝；不会导入其他电脑的密钥。已有后台目录不能使用 `-FreshInstall` 覆盖。

## 发布者：签名更新

当前可用的更新源是本仓库 `updates` 分支：

- 清单：`https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/stable/delta-ui-manifest.json`
- 签名：同目录的 `delta-ui-manifest.sig`
- 版本包：`updates/packages/1.1.0/delta-ui-1.1.0.zip`

客户端使用内置公钥验证清单的 RSA-SHA256 签名，再核对 ZIP 和每个文件的长度与 SHA-256。更新包只包含 `Accelerator.exe` 和 `Accelerator.exe.config`；不携带启动器、SDK、运行时、后台脚本和本地配置。启动器变更通过新的轻量安装包升级。

源码提交本身不是更新包。发布流程需要完成编译、测试、签名，再将版本包、清单和签名作为同一次 Git 提交发布到 `updates` 分支，最后才会被客户端识别。此方式不依赖 GitHub Release API 权限；同样的签名协议也支持 GitHub Releases。

只需创建一次签名密钥，私钥必须放在源码目录之外：

```powershell
.\build\New-UpdateSigningKey.ps1 `
  -PrivateKeyPath C:\PrivateRelease\update-signing-key.dpapi `
  -PublicKeyPath C:\PrivateRelease\update-public-key.xml
```

私钥是 UTF-8 RSA XML 经 Windows DPAPI `CurrentUser` 加密的文件，默认 RSA 3072 位。保留原私钥以便客户端继续验证未来更新；不要每次发布重新生成密钥。公钥写入 `src/UpdatePublicKey.cs`，私钥不能提交、上传或放入安装包。

```powershell
.\build\New-UpdatePackage.ps1 `
  -PrivateKeyPath C:\PrivateRelease\update-signing-key.dpapi `
  -OutputDirectory .\dist\1.1.0 `
  -Version 1.1.0 -Channel SignedGitFeed -IncludeBootstrap
```

输出目录必须尚不存在。ZIP 固定条目顺序、时间戳和压缩参数，同一输入产生相同哈希。清单使用无 BOM 的 UTF-8 精确字节，分离签名为原始 RSA PKCS#1 SHA-256 签名字节。脚本会重新读取 ZIP 验证条目，并在输出前自行验证签名。`-Channel GitHubRelease` 将包地址改为官方仓库的 `releases/download/v1.1.0/`。

## 离线验证

```powershell
pwsh -NoProfile -File .\tests\Test-Installation.ps1
```

测试在 `Documents\DeltaResolveAcceleratorInstallTests` 的独立目录内运行，使用测试注册表 JSON 和测试桌面/开始菜单目录。它验证路径拒绝、重复安装、独立图标、快捷方式修复、已运行程序拦截、失败回滚、配置保留、依赖排除、确定性打包和签名篡改检测，不改真实注册表、真实快捷方式或网络。

快捷方式标志依据 Microsoft 的 [MS-SHLLINK LinkFlags 规范](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-shllink/ae350202-3ba9-4790-9e9e-98935f4ee5af)。
