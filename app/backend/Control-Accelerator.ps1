[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Start','Stop','Status','Recover')][string]$Action)
$ErrorActionPreference='Stop'
# The desktop UI decodes redirected JSON as UTF-8, including without a console.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用分享包随附的 PowerShell 7 启动' }
. (Join-Path $PSScriptRoot 'Mna-UI.Common.ps1')
. Initialize-MnaUiRuntimeVariables
. (Join-Path $PSScriptRoot 'Mna-SessionRecovery.ps1')
if ($Action -eq 'Status') { Get-MnaUiStatus | ConvertTo-Json -Depth 5; exit }
$uiPaths=Get-MnaUiPaths
$uiLock=$null
$uiRunId=$null
$uiOperationStartedAt=[DateTimeOffset]::Now.ToString('o')
try {
    $null=[IO.Directory]::CreateDirectory($uiPaths.Private)
    try { $uiLock=[IO.File]::Open($uiPaths.ControlLock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { Get-MnaUiStatus | ConvertTo-Json -Depth 5; exit }
    $record=Read-MnaUiJson $uiPaths.WorkerRecord
    if ($Action -eq 'Start' -and (Test-MnaFreeTrialExpired)) { throw '本次免费试用已到期，请先核对腾讯云服务状态' }
    $workerAlive=Test-MnaUiWorker $record
    if ($workerAlive) {
        if ($Action -eq 'Stop') {
            Write-MnaUiJson -Path (Get-MnaRunFile $record.RunId stop) -Value ([pscustomobject]@{RunId=$record.RunId;RequestedAt=Get-Date -Format o})
            Write-MnaUiStatus -Phase stopping -Message '正在关闭本次连接并检查网络恢复情况' -RunId $record.RunId -ProgressStage '请求关闭加速' -OperationStartedAt $uiOperationStartedAt
        }
    } elseif ($Action -eq 'Start') {
        Invoke-MnaUiRecovery -Record $record
        Assert-MnaUiPreviousRunClear $record
        if (-not (Test-Path -LiteralPath $uiPaths.WorkerScript -PathType Leaf)) { throw '后台脚本缺失' }
        $settings=Assert-MnaReleaseConfiguration
        $selectedMode='ResolveOnly'
        $uiRunId=New-MnaHexSecret 12
        $shellPath=$uiPaths.PowerShell
        $record=[pscustomobject]@{RunId=$uiRunId;WorkerPid=0;WorkerCreatedUtc=$null;WorkerExecutable=$shellPath;WorkerScript=$uiPaths.WorkerScript;RoutingMode=$selectedMode}
        Write-MnaUiJson -Path $uiPaths.WorkerRecord -Value $record
        Write-MnaUiStatus -Phase starting -Message '正在准备本地服务…' -RunId $uiRunId -RoutingMode $selectedMode -ProgressStage '准备本地服务' -OperationStartedAt $uiOperationStartedAt
        $workerArguments=@('-NoProfile','-NonInteractive','-File',('"'+$uiPaths.WorkerScript+'"'),'-RunId',$uiRunId)
        $worker=Start-Process -FilePath $shellPath -ArgumentList $workerArguments -WorkingDirectory $uiPaths.Root -WindowStyle Hidden -PassThru
        $record.WorkerPid=$worker.Id
        $record.WorkerCreatedUtc=$worker.StartTime.ToUniversalTime().ToString('o')
        $record.WorkerExecutable=$worker.Path
        Write-MnaUiJson -Path $uiPaths.WorkerRecord -Value $record
    } else {
        Invoke-MnaUiRecovery -Record $record -Force:($Action -eq 'Stop')
    }
} catch {
    Write-MnaUiStatus -Phase error -Message (Protect-MnaTrialMessage $_.Exception.Message) -RunId $uiRunId
} finally { if ($uiLock) { $uiLock.Dispose() } }
Get-MnaUiStatus | ConvertTo-Json -Depth 5
