# Windows 代码签名准备

现有 RSA 更新清单签名只保证更新来自项目发布者且内容没有被篡改，不是 Windows Authenticode 发布者证书。当前构建未接入公开信任的代码签名服务；不要把已签更新清单描述为已获 Windows 信任。

## 个人证书

个人开发者可申请身份验证型代码签名证书，发布者名称对应核验后的真实姓名。需要本人在证书机构官方渠道完成身份与地址核验，并选择受支持的硬件密钥或云签名服务。不能用自签证书、修改本机根证书或修改系统保护策略代替公开信任的证书。

- [SSL.com IV Code Signing](https://www.ssl.com/products/software-integrity/code-signing/iv/)支持个人；证书费与硬件／云签名费用分别计算，申请资格与价格以机构当前审核和报价为准。
- [微软 Artifact Signing 申请条件](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)目前将公开信任的个人身份限定在美国、加拿大；不能把组织适用地区当成个人适用地区。
- [微软签名要求](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control)与[智能应用控制说明](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions)。代码签名验证发布者及文件完整性，不是产品合规认证，也不承诺取消所有 SmartScreen、杀毒或管理员权限提示。

## 待接入的发布顺序

1. 在独立构建目录编译 `Accelerator.exe`、`DeltaLauncher.exe`，签名并加可信时间戳。后端 12 个 PowerShell 脚本及安装载荷 `Install-App.ps1` 也需要核验脚本签名。
2. 完整包采用“复制 → 签名 → 计算载荷哈希”的顺序；源码哈希和签名后文件哈希分别记录。不要在生成清单后再改动文件。
3. 用已签载荷编译 `DeltaResolveSetup-<version>.exe`，再签安装器自身。`Compile-Setup.ps1` 会把载荷哈希嵌入安装器，不能在此前使用未签载荷。
4. 最后生成更新 ZIP、SHA-256 和现有 RSA 更新清单签名。`Publish-Release.ps1` 自动重编译可能覆盖已有 Authenticode 签名，需在对应构建阶段正式接入签名与校验；当前尚未实现该接入。
5. 在开启智能应用控制的 Windows 环境验证安装、更新、自启动、连接和退出。检查进程加载的全部代码与依赖；自启动设置目前使用动态 PowerShell 命令，不能假定它会继承宿主 EXE 的信任。

现有在线通道仅分发 `Accelerator.exe` 和配置，无法同时更新启动器、后端或第三方 SDK。完整签名迁移需要配套交付方案，不能向旧更新器塞入额外文件。

## 腾讯 SDK 是独立依赖

本次核对腾讯[官方 SDK 下载页](https://cloud.tencent.com/document/product/1385/126032)的 Windows `0.23.1_e012851` 原始包，`linkboost.exe`、`linkboost-core.exe`、`multipath-helper.exe` 均未签名。给项目自己的 EXE 签名不能让这些子进程自动获得信任。

应向腾讯申请具有有效 Authenticode 签名且兼容智能应用控制的完整 Windows x64 SDK，或先核对其授权是否允许由本项目签名分发。现有包保持原样；不擅自为第三方文件添加发布者身份。微软 PowerShell 运行时继续使用其官方签名发行文件。
