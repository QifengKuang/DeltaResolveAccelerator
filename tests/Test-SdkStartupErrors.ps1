#requires -Version 7.0
<# SDK launch diagnostics only. Synthetic exceptions and a guaranteed nonexistent
   executable verify errors; no real SDK, credentials or network settings are used. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'SDK launch diagnostics require Windows.' }
$repository=Split-Path $PSScriptRoot -Parent
$commonPath=Join-Path $repository 'app/backend/Mna-UI.Common.ps1'
$workerPath=Join-Path $repository 'app/backend/Run-Accelerator.ps1'
$checks=[Collections.Generic.List[string]]::new()
function Assert-SdkStartup([bool]$Passed,[string]$Name) {
    if (-not $Passed) { throw ('SDK startup diagnostic check failed: '+$Name) }
    $checks.Add($Name)
}
foreach ($path in @($commonPath,$workerPath)) {
    $tokens=$null;$parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    Assert-SdkStartup (@($parseErrors).Count -eq 0) ('PowerShell syntax: '+[IO.Path]::GetFileName($path))
}
. $commonPath
$trialSensitiveStrings=[Collections.Generic.List[string]]::new()
$fakeSecret='synthetic-sdk-key-do-not-log'
$trialSensitiveStrings.Add($fakeSecret)
$fakeDirectory=Join-Path $PSScriptRoot ('中文 SDK (fixture) '+('long-path-'*35))
$fakeExecutable=Join-Path $fakeDirectory 'linkboost.exe'
$start=New-MnaSdkProcessStartInfo -ExecutablePath $fakeExecutable -WorkingDirectory $fakeDirectory
Assert-SdkStartup ($start.FileName -ceq $fakeExecutable -and $start.WorkingDirectory -ceq $fakeDirectory) 'Exact executable and working directory are preserved as data'
Assert-SdkStartup ($start.UseShellExecute -and $start.WindowStyle -eq [Diagnostics.ProcessWindowStyle]::Hidden) 'Shell execution and hidden window match the previous launch'
Assert-SdkStartup ($start.Arguments -eq '' -and $start.ArgumentList.Count -eq 0 -and $start.Verb -eq '') 'SDK launch adds no arguments, credentials or elevation verb'
Assert-SdkStartup (-not $start.RedirectStandardOutput -and -not $start.RedirectStandardError -and -not $start.RedirectStandardInput) 'SDK standard streams remain unchanged'

$unsafeMessage="Failed to launch '$fakeExecutable' in '$fakeDirectory'; token=$fakeSecret; https://fixture.invalid/?password=$fakeSecret"
foreach ($case in @(
    @{Code=2;Reason='找不到程序文件'},
    @{Code=3;Reason='找不到程序目录'},
    @{Code=5;Reason='Windows 拒绝访问'},
    @{Code=577;Reason='无法验证程序的数字签名'},
    @{Code=1260;Reason='系统组策略禁止'},
    @{Code=4551;Reason='Windows 应用控制策略阻止'}
)) {
    $native=[ComponentModel.Win32Exception]::new($case.Code,$unsafeMessage)
    $wrapped=[InvalidOperationException]::new($unsafeMessage,$native)
    $outer=[Exception]::new($unsafeMessage,$wrapped)
    $message=Get-MnaSdkStartFailureMessage -Exception $outer
    Assert-SdkStartup ($message.Contains(('Windows 错误码 '+$case.Code)) -and $message.Contains($case.Reason)) ('Native code '+$case.Code+' and actionable reason survive nested wrappers')
    Assert-SdkStartup ($message.Length -lt 190 -and -not $message.Contains($fakeDirectory) -and -not $message.Contains($fakeSecret) -and -not $message.Contains('fixture.invalid')) ('Native code '+$case.Code+' stays visible without raw paths or credentials')
}
$fallbackCode=1114
$fallback=Get-MnaSdkStartFailureMessage -Exception ([ComponentModel.Win32Exception]::new($fallbackCode,$unsafeMessage))
$systemReason=Protect-MnaTrialMessage ([ComponentModel.Win32Exception]::new($fallbackCode).Message)
Assert-SdkStartup ($fallback.Contains('Windows 错误码 1114') -and $fallback.Contains($systemReason) -and -not $fallback.Contains($fakeSecret)) 'Other native failures use the real system reason without the raw exception message'
$unknown=Get-MnaSdkStartFailureMessage -Exception ([InvalidOperationException]::new($unsafeMessage+' native code 4551'))
Assert-SdkStartup ($unknown.Contains('InvalidOperationException') -and -not $unknown.Contains('4551') -and -not $unknown.Contains($fakeSecret) -and -not $unknown.Contains($fakeDirectory)) 'Unknown exceptions do not guess native codes or expose their message'
$trialSensitiveStrings.Add('linkboost.exe')
$redacted=Get-MnaSdkStartFailureMessage -Exception ([ComponentModel.Win32Exception]::new(5))
Assert-SdkStartup ($redacted.Contains('[redacted]') -and -not $redacted.Contains('linkboost.exe')) 'Existing sensitive-string redaction still runs on the concise diagnostic'
$null=$trialSensitiveStrings.Remove('linkboost.exe')

# Exercise the actual Process.Start exception path without creating or executing a file.
$missingExecutable=Join-Path $PSScriptRoot ('missing-sdk-'+[guid]::NewGuid().ToString('N')+'.exe')
if (Test-Path -LiteralPath $missingExecutable) { throw 'The missing-executable fixture unexpectedly exists.' }
$failure=$null
try { $null=Start-MnaSdkProcess -ExecutablePath $missingExecutable -WorkingDirectory $PSScriptRoot }
catch { $failure=$_.Exception }
Assert-SdkStartup ($null -ne $failure -and $failure.Message.Contains('Windows 错误码 2') -and $failure.Message.Contains('找不到程序文件')) 'Real missing-file failure retains Win32 code 2 through PowerShell invocation'
Assert-SdkStartup (-not $failure.Message.Contains($missingExecutable) -and $null -eq $failure.InnerException) 'The worker-facing exception contains only the concise safe diagnostic'
$worker=[IO.File]::ReadAllText($workerPath)
Assert-SdkStartup ($worker.Contains('$trialProcess=Start-MnaSdkProcess -ExecutablePath $trialExecutable -WorkingDirectory $trialRuntimeDirectory') -and -not $worker.Contains('Start-Process -FilePath $trialExecutable')) 'The SDK worker uses the diagnostic launcher with the original paths'
$report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;NetworkStarted=$false;SdkStarted=$false;RealAppSettingsRead=$false;ChecksPerformed=$checks.ToArray()}
$report | ConvertTo-Json -Depth 4
