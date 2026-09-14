# Session identity is shared by Status, Start and Stop. Previous-boot records
# are evidence to archive, never authority to terminate a possibly reused PID.
function Get-MnaUiRuntimeProcesses {
    # Get-Process -Name can omit elevated processes in a packaged caller even
    # when the same PID is visible individually. Use the OS process inventory;
    # inability to read it must block recovery rather than mean "no processes".
    Get-CimInstance Win32_Process -Filter "Name='linkboost.exe' OR Name='linkboost-core.exe' OR Name='multipath-helper.exe' OR Name='mp-speeder.exe'" -Property Name,ProcessId -ErrorAction Stop
}

function Get-MnaUiBootIdentity {
    if (-not $script:MnaUiBootIdentity) {
        $boot=(Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
        if (-not $boot) { throw '无法确认本次系统启动时间，请稍后重试' }
        $script:MnaUiBootIdentity=([datetime]$boot).ToUniversalTime().ToString('o')
    }
    return $script:MnaUiBootIdentity
}

function Test-MnaUiSamePath {
    param([AllowNull()][string]$Left,[AllowNull()][string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    try {
        # Resolve actual handles, including files, rather than substituting path
        # prefixes. A missing or inaccessible identity must fail closed.
        $a=Resolve-MnaUiDirectoryPath -Path $Left
        $b=Resolve-MnaUiDirectoryPath -Path $Right
        return [string]::Equals($a,$b,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-MnaUiSessionDisposition {
    param([AllowNull()][object]$Record,[AllowNull()][object]$Owner,[AllowNull()][object]$Status,
        [datetime]$BootTime=([datetime](Get-MnaUiBootIdentity)))
    $kind='recoveryRequired';$ready=$false;$reason='后台进程已退出；请点击关闭以核对并清理本次连接'
    if (-not $Record) {
        $kind=if ($Owner -or ($Status -and $Status.phase -notin @('stopped','error'))) {'recoveryRequired'} else {'empty'}
        $reason=if($kind -eq 'empty'){'加速器已关闭'}else{'运行记录不完整，请点击关闭以检查恢复'}
    } elseif ($Record.RunId -notmatch '^[a-f0-9]{24}$' -or ($Owner -and $Owner.RunId -ne $Record.RunId)) {
        $kind='foreign';$reason='运行记录不匹配，已保留记录供检查'
    } else {
        $bootUtc=$BootTime.ToUniversalTime()
        $oldBoot=$false;$badTime=$false
        $times=@($Record.WorkerCreatedUtc,$Owner.RootCreated) | Where-Object { $_ }
        $bootIds=@($Record.BootIdentity,$Owner.BootIdentity) | Where-Object { $_ }
        try {
            foreach($value in $bootIds) {
                $stamp=([datetime]$value).ToUniversalTime()
                if($stamp -lt $bootUtc){$oldBoot=$true}
                elseif($stamp -gt $bootUtc){$badTime=$true}
            }
            foreach($value in $times) {
                $stamp=([datetime]$value).ToUniversalTime()
                if($stamp -lt $bootUtc){$oldBoot=$true}
                elseif($stamp -gt [datetime]::UtcNow.AddSeconds(5)){$badTime=$true}
            }
            # Mixed generations are invalid except for an interrupted retirement:
            # its terminal owner has no process authority and is safe to finish.
            if($oldBoot -and -not $Owner.RetiredPreviousBoot) {
                foreach($value in $times){if(([datetime]$value).ToUniversalTime() -ge $bootUtc){$badTime=$true}}
                foreach($value in $bootIds){if(([datetime]$value).ToUniversalTime() -ge $bootUtc){$badTime=$true}}
            }
        } catch {$badTime=$true}
        if($badTime) {$kind='foreign';$reason='运行记录的系统启动时间不一致，已保留记录'}
        elseif($oldBoot) {
            # Deliberately precedes path and live-PID checks: old paths can cease
            # to exist after reboot, and old PIDs can belong to unrelated apps.
            $kind='previousBoot';$reason='重启前的连接已结束；开启时将自动检查并恢复'
        } else {
            $paths=Get-MnaUiPaths
            $pendingPublication=$false
            if($Record.WorkerPid -eq 0 -and -not $Owner -and $Record.BootIdentity -and
                $Status -and $Status.runId -eq $Record.RunId -and $Status.phase -eq 'starting' -and $Status.BootIdentity) {
                try {
                    $age=([datetime]::UtcNow-([datetime]$Status.updatedAt).ToUniversalTime()).TotalSeconds
                    $pendingPublication=([datetime]$Status.BootIdentity).ToUniversalTime() -eq $bootUtc -and $age -ge -1 -and $age -le 5
                } catch {}
            }
            if(-not (Test-MnaUiSamePath $Record.WorkerExecutable $paths.PowerShell) -or
                -not (Test-MnaUiSamePath $Record.WorkerScript $paths.WorkerScript) -or
                ($Owner -and -not (Test-MnaUiSamePath $Owner.Runtime $paths.Runtime))) {
                $kind='foreign';$reason='本次运行路径无法确认，已保留归属记录'
            } elseif($Record.RetiredPreviousBoot -and $Record.WorkerPid -eq 0) {
                $kind='stopped';$reason='重启前的连接已安全归档，加速器已关闭'
            } elseif($pendingPublication) {
                # Control commits the PID only after Start-Process succeeds.
                # This bounded publication window has no process authority.
                $kind='pendingStart';$reason='正在启动连接后台…'
            } elseif(Test-MnaUiWorker $Record) {
                $kind='live';$reason='正在确认当前连接状态'
                if($Status -and $Status.runId -eq $Record.RunId) {
                    $fresh=$false
                    try {
                        $age=([datetime]::UtcNow-([datetime]$Status.updatedAt).ToUniversalTime()).TotalSeconds
                        $fresh=$age -ge -5 -and $age -le 30
                        if($Status.BootIdentity -and ([datetime]$Status.BootIdentity).ToUniversalTime() -ne $bootUtc){$fresh=$false}
                    } catch {}
                    $ready=$fresh -and $Status.phase -eq 'connected' -and $Status.ready -eq $true -and
                        $Status.gameRoutingConfigured -eq $true -and $Status.udpRoutingVerified -eq $true
                    $reason=if($Status.phase -eq 'connected' -and -not $fresh){'连接状态更新超时，正在等待后台确认'}else{[string]$Status.message}
                }
            } elseif($Status -and $Status.runId -eq $Record.RunId -and $Status.phase -eq 'stopped') {
                $kind='stopped';$reason=[string]$Status.message
            }
        }
    }
    [pscustomobject]@{Kind=$kind;Ready=[bool]$ready;Reason=$reason}
}

function Complete-MnaUiPreviousBootSession {
    param([AllowNull()][object]$Record,[AllowNull()][object]$Owner,[AllowNull()][object]$Status)
    $disposition=Get-MnaUiSessionDisposition -Record $Record -Owner $Owner -Status $Status
    if($disposition.Kind -ne 'previousBoot'){return $false}
    # Called under ui-control.lock. These are independent observations; no old
    # PID, interface index or saved baseline is used to change the machine.
    if(Get-MnaUiRuntimeProcesses){throw '重启后的恢复检查发现 SDK 进程，未接管其他连接'}
    if(@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {$_.Name -like 'mna_game_*' -or $_.Name -eq 'mp_tun0'}).Count){throw '重启后仍有加速虚拟网卡，已保留记录等待核对'}
    if(@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalPort -in @(9801,12345,9803)}).Count -or
       @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object {$_.LocalPort -in @(9801,12345,9803)}).Count){throw '加速控制端口仍被占用，已保留记录等待核对'}
    $paths=Get-MnaUiPaths
    $boot=Get-MnaUiBootIdentity
    $archive=Join-Path $paths.Root ('results\session-retired-'+$Record.RunId+'-'+(Get-Date -Format yyyyMMddHHmmssfff)+'.json')
    # Only known, non-secret metadata is archived. Never follow BeforePath or
    # copy the private directory (which also contains the encrypted device key).
    Write-MnaUiJson -Path $archive -Value ([pscustomobject]@{
        ArchivedAt=Get-Date -Format o;Reason='previousBoot';CurrentBoot=$boot
        Worker=($Record | Select-Object RunId,WorkerPid,WorkerCreatedUtc,WorkerExecutable,WorkerScript,BootIdentity)
        Owner=($Owner | Select-Object RunId,RootPid,RootCreated,Runtime,BeforePath,BootIdentity,Owned)
        Status=($Status | Select-Object runId,phase,ready,updatedAt,BootIdentity)
    })
    # Commit terminal owner first, then the current pointer. If interrupted,
    # classification recognizes this idempotent retirement on the next action.
    Write-MnaUiJson -Path (Get-MnaRunFile $Record.RunId ownership) -Value ([pscustomobject]@{
        RunId=$Record.RunId;RootPid=0;RootCreated=$null;Runtime=$paths.Runtime;BeforePath=$null;Owned=@()
        BootIdentity=$boot;RetiredPreviousBoot=$true;ArchivePath=$archive
    })
    Write-MnaUiJson -Path $paths.WorkerRecord -Value ([pscustomobject]@{
        RunId=$Record.RunId;WorkerPid=0;WorkerCreatedUtc=$null;WorkerExecutable=$paths.PowerShell
        WorkerScript=$paths.WorkerScript;RoutingMode='ResolveOnly';BootIdentity=$boot;RetiredPreviousBoot=$true;ArchivePath=$archive
    })
    Write-MnaUiStatus -Phase stopped -Message '重启前的连接已安全归档，加速器已关闭' -RunId $Record.RunId
    return $true
}
