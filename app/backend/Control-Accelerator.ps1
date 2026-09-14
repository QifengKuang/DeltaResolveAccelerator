[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Start','Stop','Status')][string]$Action)
$ErrorActionPreference='Stop'
# The desktop UI decodes redirected JSON as UTF-8, including without a console.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用分享包随附的 PowerShell 7 启动' }
. (Join-Path $PSScriptRoot 'Mna-UI.Common.ps1')
. Initialize-MnaUiRuntimeVariables
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
    $owner=if($record -and $record.RunId -match '^[a-f0-9]{24}$'){Read-MnaUiJson (Get-MnaRunFile $record.RunId ownership)}else{$null}
    $previousStatus=Read-MnaUiJson $uiPaths.Status
    $disposition=Get-MnaUiSessionDisposition -Record $record -Owner $owner -Status $previousStatus
    if($disposition.Kind -eq 'foreign'){throw $disposition.Reason}
    if(Complete-MnaUiPreviousBootSession -Record $record -Owner $owner -Status $previousStatus) {
        $record=Read-MnaUiJson $uiPaths.WorkerRecord
    }
    $workerAlive=Test-MnaUiWorker $record
    if ($workerAlive) {
        if ($Action -eq 'Stop') {
            Write-MnaUiJson -Path (Get-MnaRunFile $record.RunId stop) -Value ([pscustomobject]@{RunId=$record.RunId;RequestedAt=Get-Date -Format o})
            Write-MnaUiStatus -Phase stopping -Message '正在关闭本次连接并检查网络恢复情况' -RunId $record.RunId -ProgressStage '请求关闭加速' -OperationStartedAt $uiOperationStartedAt
        }
    } elseif ($Action -eq 'Start') {
        Assert-MnaUiPreviousRunClear $record
        if (-not (Test-Path -LiteralPath $uiPaths.WorkerScript -PathType Leaf)) { throw '后台脚本缺失' }
        $settings=Assert-MnaReleaseConfiguration
        $selectedMode='ResolveOnly'
        $uiRunId=New-MnaHexSecret 12
        $shellPath=$uiPaths.PowerShell
        $record=[pscustomobject]@{RunId=$uiRunId;WorkerPid=0;WorkerCreatedUtc=$null;WorkerExecutable=$shellPath;WorkerScript=$uiPaths.WorkerScript;RoutingMode=$selectedMode;BootIdentity=Get-MnaUiBootIdentity}
        Write-MnaUiJson -Path $uiPaths.WorkerRecord -Value $record
        Write-MnaUiStatus -Phase starting -Message '正在准备本地服务…' -RunId $uiRunId -RoutingMode $selectedMode -ProgressStage '准备本地服务' -OperationStartedAt $uiOperationStartedAt
        $workerArguments=@('-NoProfile','-NonInteractive','-File',('"'+$uiPaths.WorkerScript+'"'),'-RunId',$uiRunId)
        $worker=Start-Process -FilePath $shellPath -ArgumentList $workerArguments -WorkingDirectory $uiPaths.Root -WindowStyle Hidden -PassThru
        $record.WorkerPid=$worker.Id
        $record.WorkerCreatedUtc=$worker.StartTime.ToUniversalTime().ToString('o')
        $record.WorkerExecutable=$worker.Path
        Write-MnaUiJson -Path $uiPaths.WorkerRecord -Value $record
    } else {
        # Recover only ownership recorded for this exact previous run if its worker exited.
        $remaining=0
        if ($record -and $record.RunId -match '^[a-f0-9]{24}$') {
            $owner=Read-MnaUiJson (Get-MnaRunFile $record.RunId ownership)
            if ($owner -and ($owner.RunId -ne $record.RunId -or -not (Test-MnaUiSamePath $owner.Runtime $trialRuntimeDirectory))) { throw '上次归属记录无法确认，未操作任何无归属的进程' }
            if ($owner -and -not $owner.RetiredPreviousBoot -and $owner.RunId -eq $record.RunId -and (Test-MnaUiSamePath $owner.Runtime $trialRuntimeDirectory)) {
                $trialProcess=[pscustomobject]@{Id=[int]$owner.RootPid}
                $trialStartTime=[datetime]$owner.RootCreated
                foreach ($item in @($owner.Owned)) {
                    $trialOwned[[int]$item.Pid]=[pscustomobject]@{Pid=[int]$item.Pid;Created=[datetime]$item.Created;Depth=[int]$item.Depth;Kind=$item.Kind;ExecutablePath=$item.ExecutablePath}
                }
                try { Write-MnaUiStatus -Phase stopping -Message '正在核对上次连接并清理本次拥有的进程' -RunId $record.RunId -AllowTerminalTransition -ProgressStage '清理上次连接' -OperationStartedAt $uiOperationStartedAt } catch { }
                $gameRouteCleanup=$null
                try {
                    . (Join-Path $uiPaths.Root 'Mna-GameRoute.ps1')
                    $gameRouteCleanup=Stop-MnaGameRouteRecovery -RunId $record.RunId -OwnedProcesses $trialOwned
                } catch { $gameRouteCleanup=[pscustomobject]@{ProcessStopped=$false;Errors=@((Protect-MnaTrialMessage $_.Exception.Message))} }
                $cleanup=Stop-MnaUiOwnedRuntime
                if ($gameRouteCleanup -and (-not $gameRouteCleanup.ProcessStopped -or @($gameRouteCleanup.Errors).Count)) {
                    try { $gameRouteCleanup=Stop-MnaGameRouteRecovery -RunId $record.RunId -OwnedProcesses $trialOwned } catch { }
                }
                $remaining=$cleanup.RemainingOwnedProcessCount
                . (Join-Path $uiPaths.Root 'Trial-NetworkState.ps1')
                $after=Get-TrialNetworkState
                $null=Save-TrialNetworkState -State $after -Label ui_recovery_after
                $null=Save-TrialNetworkState -State $cleanup -Label ui_recovery_cleanup
                $null=Save-TrialNetworkState -State $gameRouteCleanup -Label ui_recovery_game_route
                $baselineValid=$owner.BeforePath -and [IO.Path]::GetFullPath($owner.BeforePath).StartsWith((Join-Path $uiPaths.Root 'results')+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $owner.BeforePath -PathType Leaf)
                if ($baselineValid) {
                    $comparison=Compare-TrialNetworkState -BaselinePath $owner.BeforePath -CurrentState $after
                    $null=Save-TrialNetworkState -State $comparison -Label ui_recovery_comparison
                    if (-not (Test-MnaUiConfigurationRestored $comparison)) { throw '已停止本次进程；网络配置仍有差异或未完整读取，请查看本地记录' }
                }
                if (-not $after.Complete -or $null -eq $remaining -or $remaining -gt 0 -or $cleanup.Errors.Count) {
                    throw '清理尚未完全确认；请查看本地检查记录'
                }
            }
        }
        Write-MnaUiStatus -Phase stopped -Message '加速器已关闭'
    }
} catch {
    Write-MnaUiStatus -Phase error -Message (Protect-MnaTrialMessage $_.Exception.Message) -RunId $uiRunId
} finally { if ($uiLock) { $uiLock.Dispose() } }
Get-MnaUiStatus | ConvertTo-Json -Depth 5
