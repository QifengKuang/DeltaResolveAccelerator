# 三角洲 · 主入口优化

Windows x64 轻量客户端，当前版本 **1.1.0**。使用腾讯云聚通 MNA 香港线路处理指定入口解析请求，对局流量保持本机直连。

设置中分开管理 Steam 与 WeGame 路径，支持自动查找、选择程序或安装文件夹、替换和移除，并显示路径是否有效。保存后根据实际运行进程匹配规则，切换平台不需要重新配置。已有单路径和双路径配置会保留；查找失败不会清空原设置。

## 安装与自动更新

桌面与开始菜单始终指向安装目录中的 `DeltaLauncher.exe`。图标使用独立的 `DeltaResolve.ico`，不再依赖更新中被替换的主程序文件。设置 → 软件可以检查更新、关闭自动检查，以及修复快捷方式。

已装好运行环境的电脑可使用轻量安装器：

- [下载 1.1.0 安装／修复程序](https://raw.githubusercontent.com/QifengKuang/DeltaResolveAccelerator/updates/installers/DeltaResolveSetup-1.1.0.exe)
- 安装器只携带本项目自己的界面、启动器和图标；复用既有 PowerShell 与 SDK，不重复下载大型运行环境。
- 首次从源码安装仍需要准备下文中的官方运行依赖和独立设备密钥。安装、目录选择、干净依赖导入见 [安装说明](docs/INSTALLATION.md)。

自动检查默认开启。客户端启动及运行期间定期检查官方签名更新源，成功检查间隔为六小时；也可以手动立即检查。新版本在后台下载，在下次启动且加速服务停止时自动安装。断网或下载失败时继续使用现有版本；替换失败或中途中断时尝试恢复原文件。日常更新仅包含主程序和配置文件，保留游戏路径、设备密钥、后台修复及运行环境。

更新使用固定公钥验证 RSA-SHA256 签名、清单和文件哈希。发布到 GitHub 的 `updates` 分支后，两台已安装 1.1.0 启动器的电脑使用相同更新通道，之后无需逐台手工复制文件。签名只能证明更新来源和完整性，不是 Windows Authenticode 签名。

此仓库包含自有界面、后端脚本和离线测试。官方 SDK、PowerShell 运行时、安装包、设备密钥、个人设置、网络状态和日志均不随仓库发布。

## 克隆后编译与离线测试

使用 Windows 10/11 x64、.NET Framework 4.8，以及 PowerShell 7 x64。界面使用 Windows 自带的 .NET Framework C# 编译器，不需要 NuGet、腾讯 SDK、设备密钥或网络连接。

在 PowerShell 7 中克隆仓库并进入目录：

```powershell
git clone https://github.com/QifengKuang/DeltaResolveAccelerator.git
cd DeltaResolveAccelerator

# 编译需要管理员权限运行的正式客户端；编译过程本身无需提权。
./build/Compile-App.ps1
./build/Compile-Launcher.ps1
./build/Compile-Setup.ps1

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

## 浅绿界面与显示缩放

界面采用暖白背景、浅薄荷绿连接卡片和深绿操作按钮，顶部使用与页面连续的自绘窗口栏；顶部空白区域可拖动，右上角可最小化或关闭。关闭仍会等待现有安全停止流程完成。

可拖动窗口四边或四角调整大小。内容区域范围为 720×556 至 1280×960 个逻辑像素（另加边缘拖拽区域），最大窗口同时受当前屏幕工作区限制。文字、按钮、图标按同一比例缩放，卡片适应剩余空间。拖拽从原始布局计算，不累积放大误差。字体只有在没有控件引用时才释放，避免反复缩放时的“参数无效”错误。

1.0.6 完整绘制圆角按钮背景，修复黑色边角；移除系统标题栏和粗边框样式，使用独立边缘控件实现缩放，避免旧式蓝灰标题栏重新出现。系统支持时使用原生圆角，不再裁切窗口 Region。

文字、控件尺寸与自绘图形统一按系统 DPI 缩放。预览程序使用与正式客户端相同的 DPI manifest，但无需管理员权限。可用 `--preview-scale 1.5` 模拟 150% 布局；预览同时生成 `.layout.json`，记录文字尺寸与控件边界检查。

```powershell
# 100%、125%、150%、200% × 9 种状态，共 36 组离线布局检查。
./tests/Test-UiLayout.ps1

# 100 组大小/状态/DPI 检查：每组反复缩放、字体有效性、边缘命中与尺寸限制。
# 同时通过后台原生 PrintWindow 绘制检查标题栏及按钮边角。
./tests/Test-UiResize.ps1
```

结果及截图位于 `tests/output/design/` 与 `tests/output/resize/`，不会读取真实设备配置或启动加速。预览发生异常时写入 `.error.txt` 并退出，不显示反复弹出的异常对话框。检查不移动鼠标、不改变 Windows 显示设置，也不替代跨显示器实测。

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

轻量安装器与签名更新包只包含自有文件，不含 SDK、PowerShell 运行时、密钥、用户设置或运行日志。旧现场修复脚本继续保留在本地。

## 发布新版

修改版本号并提交源码后，在包含最新 `main` 的干净工作树执行一次发布命令：

```powershell
./build/Publish-Release.ps1 -Version '1.1.1' -PrivateKeyPath 'C:\MyPrivateKeys\update-signing-key.dpapi'
```

命令编译并检查客户端，生成小型签名更新包，先推送源码，再原子更新 GitHub 上的签名发布目录。远端下载并在安全的下一次启动时应用更新；普通未发布的源码提交不会把未完成版本送到用户电脑。需要 Git 推送权限和对应公钥的本机签名密钥；密钥使用 Windows CurrentUser DPAPI 保存于仓库之外，不能提交。`-PrepareOnly` 可生成同样的本地发布树供已授权连接器推送。

协议和回归验证覆盖篡改签名／哈希、旧版本、危险归档路径、连接期间禁止替换、更新中断恢复、快捷方式固定路径及个人文件保留。Shell Link 跟踪标志依据 [Microsoft 官方文档](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ne-shlobj_core-shell_link_data_flags)。

## 排查与协作

另一台电脑首次接入、重启后出现旧运行记录、移动安装目录后的恢复问题，见 [本机与远程排查流程](docs/TROUBLESHOOTING.md)。这些恢复场景仍需要在对应电脑验证，不能据此宣称已经彻底修复。当前 1.0.4 不包含其他电脑上仍在进行的会话／重启恢复补丁；已有本地修复时先保留改动并逐项合并，避免用本仓库覆盖尚未提交的补丁。

提交问题时请描述版本、启动平台、问题时刻及脱敏后的错误文字。不要上传 `private`、`results`、SDK 运行目录、设备密钥或原始网络日志。
