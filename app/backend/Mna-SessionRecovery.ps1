# Recovery is called only while Control-Accelerator holds its exclusive lock.
# Status remains read-only; Recover never stops a live worker.
function Test-MnaUiRecoveryInventoryClear {
    param([object]$State)
    if (-not $State -or $State.Complete -ne $true -or $State.SchemaVersion -ne 1 -or @($State.ReadErrors).Count) { return $false }
    foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','RelatedProcesses','RelatedServices','RelatedDrivers','WinINETProxy','WinHTTPProxy')) {
        if ($section -notin @($State.Data.PSObject.Properties.Name)) { return $false }
    }
    if (@($State.Data.RelatedProcesses).Count) { return $false }
    foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS')) {
        foreach ($item in @($State.Data.$section)) {
            $name=if ($section -eq 'Adapters') { $item.Name } else { $item.InterfaceAlias }
            if ($name -match '^(mna_game_|mp_tun)') { return $false }
        }
    }
    return $true
}

function Invoke-MnaUiRecovery {
    param([AllowNull()][object]$Record, [switch]$Force)
    $paths=Get-MnaUiPaths
    $status=Read-MnaUiJson $paths.Status
    if (Test-MnaUiWorker $Record) { return }
    if (-not $Record -and (Test-Path -LiteralPath $paths.WorkerRecord)) {
        throw '上次运行记录损坏，无法确认资源归属；已保留记录，请查看本地检查记录'
    }
    if ($Record -and $Record.RunId -notmatch '^[a-f0-9]{24}$') { throw '上次运行标识无效，已保留恢复记录' }
    # A completed recovery is durable. Do not compare its old baseline on every launch.
    if (-not $Force -and $status -and $status.phase -eq 'stopped' -and
        (-not $Record -or $status.runId -eq $Record.RunId)) { return }
    if (-not $Record -and -not (Test-Path -LiteralPath $paths.Status)) { return }
    . (Join-Path $PSScriptRoot 'Trial-NetworkState.ps1')
    . (Join-Path $PSScriptRoot 'Mna-RebootRecovery.ps1')
    $owner=$null
    if ($Record) {
        $ownerPath=Get-MnaRunFile $Record.RunId ownership
        $owner=Read-MnaUiJson $ownerPath
        if (-not $owner -and (Test-Path -LiteralPath $ownerPath)) { throw '上次归属记录损坏，已保留记录；未操作无法确认归属的资源' }
    }
    if ($owner -and ($owner.RunId -ne $Record.RunId -or
        -not [string]::Equals($owner.Runtime,$trialRuntimeDirectory,[StringComparison]::OrdinalIgnoreCase))) {
        throw '上次归属记录无法确认，未操作任何无归属的进程'
    }
    if ($owner) {
        if ($owner.RootPid -le 0 -or -not (ConvertTo-MnaUiOperationTime $owner.RootCreated) -or -not @($owner.Owned).Count) {
            throw '上次归属记录不完整，已保留记录'
        }
        foreach ($item in @($owner.Owned)) {
            if ($item.Pid -le 0 -or -not (ConvertTo-MnaUiOperationTime $item.Created)) { throw '上次进程身份记录不完整，已保留记录' }
        }
    }
    Write-MnaUiStatus -Phase stopping -Message '正在自动检查并恢复上次连接…' -RunId $Record.RunId -AllowTerminalTransition -ProgressStage '恢复上次连接'
    $rebootRecovered=$false
    if ($owner) {
        $trialProcess=[pscustomobject]@{Id=[int]$owner.RootPid}
        $trialStartTime=[datetime]$owner.RootCreated
        $trialOwned=@{}
        foreach ($item in @($owner.Owned)) {
            $trialOwned[[int]$item.Pid]=[pscustomobject]@{Pid=[int]$item.Pid;Created=[datetime]$item.Created;Depth=[int]$item.Depth;Kind=$item.Kind;ExecutablePath=$item.ExecutablePath}
        }
        . (Join-Path $PSScriptRoot 'Mna-GameRoute.ps1')
        $gameRouteCleanup=$null
        try { $gameRouteCleanup=Stop-MnaGameRouteRecovery -RunId $Record.RunId -OwnedProcesses $trialOwned }
        catch { $gameRouteCleanup=[pscustomobject]@{ProcessStopped=$false;Errors=@((Protect-MnaTrialMessage $_.Exception.Message))} }
        $cleanup=Stop-MnaUiOwnedRuntime
        if (-not $gameRouteCleanup.ProcessStopped -or @($gameRouteCleanup.Errors).Count) {
            try { $gameRouteCleanup=Stop-MnaGameRouteRecovery -RunId $Record.RunId -OwnedProcesses $trialOwned } catch { }
        }
        $after=Get-TrialNetworkState
        $null=Save-TrialNetworkState -State $after -Label ui_recovery_after
        $null=Save-TrialNetworkState -State $cleanup -Label ui_recovery_cleanup
        $null=Save-TrialNetworkState -State $gameRouteCleanup -Label ui_recovery_game_route
        if (-not (Test-MnaUiRecoveryInventoryClear $after) -or $null -eq $cleanup.RemainingOwnedProcessCount -or
            $cleanup.RemainingOwnedProcessCount -gt 0 -or @($cleanup.Errors).Count -or
            -not $gameRouteCleanup.ProcessStopped -or @($gameRouteCleanup.Errors).Count) {
            throw '清理尚未完全确认；请查看本地检查记录'
        }
        $baselineValid=$owner.BeforePath -and [IO.Path]::GetFullPath($owner.BeforePath).StartsWith((Join-Path $paths.Root 'results')+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $owner.BeforePath -PathType Leaf)
        if (-not $baselineValid) { throw '上次网络基线缺失，已保留恢复记录，不能确认恢复完成' }
        $before=Read-MnaUiJson $owner.BeforePath
        if (-not $before) { throw '上次网络基线损坏，已保留恢复记录，不能确认恢复完成' }
        $comparison=Compare-TrialNetworkState -BaselineState $before -CurrentState $after
        $null=Save-TrialNetworkState -State $comparison -Label ui_recovery_comparison
        $restored=Test-MnaUiConfigurationRestored $comparison -BaselineState $before -CurrentState $after
        if (-not $restored) {
            $bootTime=$null
            try { $bootTime=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime } catch { }
            if ($bootTime) {
                $rebootRecovered=Test-MnaRebootNetworkRestored -RunId $Record.RunId -Owner $owner -BaselineState $before -CurrentState $after -BootTime $bootTime
            }
            $null=Save-TrialNetworkState -State ([pscustomobject]@{RunId=$Record.RunId;Recovered=$rebootRecovered;BootTime=$bootTime;Reason='Reboot interface identity and automatic IPv6 comparison';OriginalDifferencesPreserved=$true}) -Label ui_recovery_reboot
            if (-not $rebootRecovered) { throw '已停止本次进程；网络配置仍有差异或未完整读取，请查看本地记录' }
        }
    } else {
        # A failed start before SDK ownership exists may still leave stale UI JSON.
        # Repair it only after a complete inventory proves no accelerator resources exist.
        $after=Get-TrialNetworkState
        $null=Save-TrialNetworkState -State $after -Label ui_recovery_after
        if (-not (Test-MnaUiRecoveryInventoryClear $after)) {
            throw '缺少上次归属记录且未能确认资源已释放，请查看本地检查记录'
        }
    }
    Write-MnaUiStatus -Phase stopped -Message $(if ($rebootRecovered) {'重启后的连接状态已自动恢复，可以重新开启'} else {'加速器已关闭'}) -RunId $Record.RunId
}
