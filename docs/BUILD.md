# 完整自有程序包构建

后端恢复修复必须与界面一起部署。既有 `New-UpdatePackage.ps1` / `Publish-Release.ps1` 的签名更新协议只更新两个界面文件；运行它们不会把新的后端脚本送到电脑。本构建入口生成包含全部自有后端的独立本机程序包，不更改既有安装器或在线更新协议，不发布网络更新。

已整理的完整版本为 **1.1.1**，下载和校验清单见 [项目主页](https://github.com/QifengKuang/DeltaResolveAccelerator)。发布包从最终 Git 源码提交重新构建，清单记录该提交且 `workingTreeDirty=false`；不会直接使用源码 `app/` 里可能遗留的旧 EXE。`updates/packages/1.1.1/` 中的完整包与旧 `stable/delta-ui-manifest.json` 是不同交付范围，旧客户端不会自动安装此完整包。

## 构建和验证

在 Windows x64、PowerShell 7、已安装 .NET Framework 4.8 的 Git 源码目录运行：

```powershell
$bundle = ./build/Build-ApplicationBundle.ps1
$bundle | Format-List
./tests/Test-ApplicationBundle.ps1 -BundleDirectory $bundle.Directory
```

也可以显式传入尚不存在的 `dist` 子目录：

```powershell
./build/Build-ApplicationBundle.ps1 -OutputDirectory (Join-Path $PWD 'dist/local-review-01')
```

每次都在隔离源码副本上实际调用现有 `Compile-App.ps1` 和 `Compile-Launcher.ps1`。不复用以前编译的 EXE，不提供跳过编译开关，不改写当前 `app` 或已安装程序。缺源码、编译失败、输出目录已存在、文件在构建中变化或路径穿过链接时立即失败。构建完成后才将暂存包整体移入目标目录。

目录结构：

```text
dist/application-<version>-<unique-id>/
  application-manifest.json
  LICENSE
  app/
    Accelerator.exe
    Accelerator.exe.config
    DeltaLauncher.exe
    DeltaResolve.ico
    backend/                     # 12 个显式列出的自有脚本
  build/Prepare-Dependencies.ps1
  docs/BUILD.md
  docs/DEPENDENCIES.md
```

`application-manifest.json` 记录版本、Git revision、工作树是否有未提交修改、每个输入源码与输出文件的 SHA-256 和大小、编译器版本与 SHA-256。即使版本号尚未提升，也能区分本地后端补丁。它用于本机构建核对，不是数字签名或在线更新授权。现有 .NET Framework 编译器会写入构建相关信息，因此这是可重复执行、可审计的构建流程，不承诺不同次编译的 EXE 字节完全相同。

构建仅按脚本中的明确白名单取源码，不从旧安装、运行目录或整个 `app` 递归打包。不会携带设备密钥、签名私钥、`private`、`results`、`vendor_inspection`、`runtime`、用户设置、网络状态或日志。公用运行配置来自 `src/Accelerator.exe.config`；更新验证公钥编入程序。发现输入中常见的私钥标记会拒绝构建；该检查不能替代对源码的保密审查。

## 运行依赖和本机部署

完整包包含本项目自有程序，PowerShell、腾讯 SDK 和设备授权仍需单独准备。按照 [第三方依赖说明](DEPENDENCIES.md) 从官方来源取得原始归档并独立核对 SHA-256；包中的 `build/Prepare-Dependencies.ps1` 可将它们准备到本包的 `app` 目录，不会启动 SDK。不要复制运行过的第三方目录或其他电脑的设备密钥。构建和离线验证通过不代表云线路已经连接。

本包供完整部署和审查使用；更新既有安装时，应在停止连接并退出程序后，由完整部署流程一起核对和替换清单中的自有界面与全部后端文件，并保留本机独立身份和恢复记录。旧 `Install-App.ps1` 的普通更新模式只更新界面，不能用来声称本包里的后端修复已经安装。不要在运行中的目录直接批量覆盖文件。

## 回归覆盖

`Test-ApplicationBundle.ps1` 不传参数时先构建真实程序包，再核对全部文件、哈希、版本、后端 PowerShell 语法和本地模块依赖。测试另建隔离 Git 源码树，放入模拟密钥、设置、SDK 状态和运行时文件，再实际构建以确认全部被排除；还覆盖后端缺失、内容篡改、清单重复／越界／遗漏、错误版本、私钥标记、覆盖现有目录和越界输出拒绝。

测试只调用编译器和本地 Git，不启动界面、游戏或 SDK，不读真实密钥，不改安装目录或网络配置。测试证据保留在 `tests/output/application-bundle/`，供本机检查。
