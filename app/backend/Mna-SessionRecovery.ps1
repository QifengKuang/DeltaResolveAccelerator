# Recovery is called only while Control-Accelerator holds its exclusive lock.
# Status remains read-only; Recover never stops a live worker.
function Test-MnaUiRecoveryInventoryClear {
    param([object]$State)
    return Test-MnaReleasedSessionInventory -State $State
}

function Save-MnaUiRecoveryComparison {
    param([object]$Owner,[object]$CurrentState,[switch]$PreviousBoot)
    $paths=Get-MnaUiPaths
    $before=$null
    try {
        $valid=$Owner.BeforePath -and [IO.Path]::GetFullPath($Owner.BeforePath).StartsWith((Join-Path $paths.Root 'results')+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $Owner.BeforePath -PathType Leaf)
        if ($valid) { $before=Read-MnaUiJson $Owner.BeforePath }
    } catch { }
    if (-not $before) {
        if (-not $PreviousBoot) { throw '上次网络基线缺失或损坏，已保留恢复记录，不能确认恢复完成' }
        # An old snapshot is diagnostic evidence, not a configuration target for
        # a different Windows boot. Do not overwrite or fabricate it.
        $null=Save-TrialNetworkState -State ([pscustomobject]@{RunId=$Owner.RunId;Classification='PreviousBootBaselineUnavailable';OriginalRecordsPreserved=$true}) -Label ui_recovery_comparison
        return $null
    }
    try { $comparison=Compare-TrialNetworkState -BaselineState $before -CurrentState $CurrentState }
    catch {
        if (-not $PreviousBoot) { throw }
        $comparison=[pscustomobject]@{RunId=$Owner.RunId;Classification='PreviousBootBaselineUnreadable';OriginalRecordsPreserved=$true}
    }
    $null=Save-TrialNetworkState -State $comparison -Label ui_recovery_comparison
    return [pscustomobject]@{Baseline=$before;Comparison=$comparison}
}

function Remove-MnaPreviousBootCredentials {
    param([ValidatePattern('^[a-f0-9]{24}$')][string]$RunId)
    # No process/controller access: only the exact expired session's two files.
    $directory=Join-Path (Get-MnaUiPaths).Private ('game-route-'+$RunId)
    for ($part=$directory;$part;$part=[IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '上次私有配置路径存在重定向，未删除'
        }
    }
    foreach ($name in @('game-route.yaml','recovery.json')) {
        $file=Join-Path $directory $name
        if (Test-Path -LiteralPath $file) {
            $item=Get-Item -LiteralPath $file -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '上次私有配置文件身份异常，未删除' }
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
        }
    }
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
        if (-not (Test-MnaSessionProcessIdentity -RunId $Record.RunId -Record $Record -Owner $owner)) {
            throw '上次进程身份或创建时间记录不一致，已保留记录；未操作旧进程编号'
        }
    }
    Write-MnaUiStatus -Phase stopping -Message '正在自动检查并恢复上次连接…' -RunId $Record.RunId -AllowTerminalTransition -ProgressStage '恢复上次连接'
    $rebootRecovered=$false
    if ($owner) {
        # Decide the boot boundary BEFORE inspecting old PIDs or expanding the
        # old SDK process tree. Windows can reuse those PIDs after a reboot.
        $bootTime=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
        $boot=ConvertTo-MnaRecoveryInstant $bootTime
        $workerCreated=ConvertTo-MnaRecoveryInstant $Record.WorkerCreatedUtc
        $rootCreated=ConvertTo-MnaRecoveryInstant $owner.RootCreated
        if (-not $boot -or -not $workerCreated -or -not $rootCreated) { throw '无法确认上次连接所属的开机时间，已保留记录，稍后可重试' }
        $previousBoot=($workerCreated -lt $boot -or $rootCreated -lt $boot)
        foreach ($item in @($owner.Owned)) {
            $created=ConvertTo-MnaRecoveryInstant $item.Created
            if (-not $created) { throw '上次进程时间记录不完整，已保留记录' }
            if ($created -lt $boot) { $previousBoot=$true }
        }
        if ($previousBoot) {
            if (-not (Test-MnaPreviousBootSession -RunId $Record.RunId -Record $Record -Owner $owner -BootTime $bootTime)) {
                throw '上次连接的开机归属记录不一致，已保留记录；未操作旧进程编号'
            }
            # Readiness of Windows network providers can lag behind boot. Give
            # transient inventory failures a bounded retry without changing NICs.
            for ($attempt=0;$attempt -lt 3;$attempt++) {
                $after=Get-TrialNetworkState
                $rebootRecovered=Test-MnaRebootSessionReleased -RunId $Record.RunId -Record $Record -Owner $owner -CurrentState $after -BootTime $bootTime
                if ($rebootRecovered) { break }
                if ($attempt -lt 2) { Start-Sleep -Milliseconds 500 }
            }
            $reportErrors=[Collections.Generic.List[string]]::new()
            $afterPath=$null
            try { $afterPath=Save-TrialNetworkState -State $after -Label ui_recovery_after }
            catch { $reportErrors.Add('current_snapshot') }
            try { $null=Save-MnaUiRecoveryComparison -Owner $owner -CurrentState $after -PreviousBoot }
            catch { $reportErrors.Add('baseline_comparison') }
            if ($rebootRecovered) {
                # Discard expired local secrets without passing an old PID to
                # the same-boot cleanup routines. Leave all diagnostic evidence.
                Remove-MnaPreviousBootCredentials -RunId $Record.RunId
            }
            $assessment=[pscustomobject]@{
                RunId=$Record.RunId;Recovered=$rebootRecovered;BootTime=$bootTime
                Classification=$(if ($rebootRecovered) {'PreviousBootSessionReleased'} else {'PreviousBootSessionPending'});CurrentSnapshotPath=$afterPath
                InventoryAttempts=[Math]::Min(($attempt+1),3);OriginalDifferencesPreserved=$true
                OldProcessIdsUsedForCleanup=$false;FreshBaselineOnNextStart=$true
                ReportErrors=@($reportErrors.ToArray())
            }
            try { $null=Save-TrialNetworkState -State $assessment -Label ui_recovery_reboot }
            catch { $reportErrors.Add('reboot_assessment') }
            if (-not $rebootRecovered) { throw '重启后的检查尚未完成，或仍有加速器资源；请稍后重试，记录已保留' }
            $message='上次连接已随重启结束，可以重新开启'
            if ($reportErrors.Count) { $message+='；部分检查记录未能保存' }
            Write-MnaUiStatus -Phase stopped -Message $message -RunId $Record.RunId
            return
        }
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
        $evidence=Save-MnaUiRecoveryComparison -Owner $owner -CurrentState $after
        $before=$evidence.Baseline;$comparison=$evidence.Comparison
        $restored=Test-MnaUiConfigurationRestored $comparison -BaselineState $before -CurrentState $after
        if ($restored -and -not $comparison.Equal) {
            . (Join-Path $PSScriptRoot 'Mna-RouterAdvertisementRecovery.ps1')
            $routeAssessment=Get-MnaUiRouterAdvertisementChanges -Comparison $comparison -BaselineState $before -CurrentState $after
            if ($routeAssessment -and (@($routeAssessment.RemovedRoutes).Count -or @($routeAssessment.AddedRoutes).Count)) {
                $null=Save-TrialNetworkState -State ([pscustomobject]@{RunId=$Record.RunId;Classification='RouterAdvertisementRouteChange';LegacyReplacementCount=$routeAssessment.LegacyReplacementCount;OriginalDifferencesPreserved=$true}) -Label ui_recovery_route_origin
            }
        }
        if (-not $restored) { throw '已停止本次进程；网络配置仍有差异或未完整读取，请查看本地记录' }
    } else {
        # A failed start before SDK ownership exists may still leave stale UI JSON.
        # Repair it only after a complete inventory proves no accelerator resources exist.
        $after=Get-TrialNetworkState
        $null=Save-TrialNetworkState -State $after -Label ui_recovery_after
        if (-not (Test-MnaUiRecoveryInventoryClear $after)) {
            throw '缺少上次归属记录且未能确认资源已释放，请查看本地检查记录'
        }
    }
    Write-MnaUiStatus -Phase stopped -Message '加速器已关闭' -RunId $Record.RunId
}
