# Persistent worker. Control-Accelerator.ps1 is the supported entry point.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{24}$')][string]$RunId)
$ErrorActionPreference='Stop'
$RoutingMode='ResolveOnly'
. (Join-Path $PSScriptRoot 'Mna-UI.Common.ps1')
. (Join-Path $PSScriptRoot 'Trial-NetworkState.ps1')
. (Join-Path $PSScriptRoot 'Mna-ReleasedResources.ps1')
. (Join-Path $PSScriptRoot 'Mna-GameRoute.ps1')
. Initialize-MnaUiRuntimeVariables
$uiPaths=Get-MnaUiPaths
$uiBefore=$null
$uiBeforePath=$null
$uiClearKey=$null
$uiStartClient=$null
$uiStartTask=$null
$uiStartRecorded=$false
$uiStartMessage=$null
$uiFailure=$null
$uiGateway=$null
$uiExitIp=$null
$uiRunAccepted=$false
$uiStopRequested=$false
$uiExpired=$false
$uiGameRouteSession=$null
$uiGameVerified=$false
$uiRecord=[ordered]@{StartedAt=Get-Date -Format o;RoutingMode=$RoutingMode;ReadyObserved=$false;SocksVerified=$false;UdpRoutingVerified=$false;GameRoutingVerified=$false;FreeTrialDeadline='2026-11-13T00:00:00+11:00';BeforePath=$null;AfterPath=$null;ComparisonPath=$null;Failure=$null}
function Test-MnaUiStopRequested {
    if (Test-MnaFreeTrialExpired) { $script:uiExpired=$true;return $true }
    return Test-Path -LiteralPath (Get-MnaRunFile $RunId stop) -PathType Leaf
}
try {
    $identityClock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $record=Read-MnaUiJson $uiPaths.WorkerRecord
        if ($record -and $record.RunId -eq $RunId -and $record.WorkerPid -eq $PID -and (Test-MnaUiWorker $record)) { $uiRunAccepted=$true;break }
        Start-Sleep -Milliseconds 100
    } while ($identityClock.Elapsed.TotalSeconds -lt 3)
    if (-not $uiRunAccepted) { throw '后台启动身份核验失败，未启动 SDK' }
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    $uiSettings=Assert-MnaReleaseConfiguration
    $uiRecord.FreeTrialDeadline=$uiSettings.TrialDeadline
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '游戏引流需要管理员权限，请从界面允许 Windows 权限提示后启动' }
    $uiBefore=Get-TrialNetworkState
    $uiBeforePath=Save-TrialNetworkState -State $uiBefore -Label ui_before
    $uiRecord.BeforePath=$uiBeforePath
    if (-not $uiBefore.Complete) { throw '无法完整读取网络基线，未启动连接' }
    $preflight=Get-MnaReleasedResourceAssessment -CurrentState $uiBefore
    if (-not $preflight.Released) { throw '开启前检查发现加速资源残留或读取未完成，未启动连接' }
    if (Get-Process -Name linkboost,linkboost-core,multipath-helper,mp-speeder -ErrorAction SilentlyContinue) { throw '已有 SDK 进程运行，本次未接管；请先结束现有测试' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalPort -in @(9801,12345,9803)}).Count -or
        @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object {$_.LocalPort -in @(9801,12345,9803)}).Count) { throw '本地测试端口已被占用，本次未启动' }
    if (-not (Test-Path -LiteralPath $trialExecutable -PathType Leaf)) { throw '官方 SDK 文件缺失' }
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop
    $encrypted=[IO.File]::ReadAllBytes((Join-Path $uiPaths.Private 'device-key.dpapi.bin'))
    try {
        $uiClearKey=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $uiDataKey=[Text.UTF8Encoding]::new($false,$true).GetString($uiClearKey).Trim()
    } catch { throw '无法读取本机设备密钥，请在当前 Windows 账户重新导入后重试' }
    if (-not $uiDataKey -or $uiDataKey.Length -gt 8192) { throw '本机设备密钥格式无效' }
    $trialSensitiveStrings.Add($uiDataKey)
    $trialSocksUser=New-MnaHexSecret 8
    $trialSocksPassword=New-MnaHexSecret 24
    $trialSensitiveStrings.Add($trialSocksUser)
    $trialSensitiveStrings.Add($trialSocksPassword)
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    Write-MnaUiStatus -Phase starting -Message '正在启动本地服务…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '启动本地服务'
    $trialProcess=Start-Process -FilePath $trialExecutable -WorkingDirectory $trialRuntimeDirectory -WindowStyle Hidden -PassThru
    $trialStartTime=$trialProcess.StartTime
    Update-MnaOwnedProcesses
    Save-MnaUiOwnership $RunId
    $localClock=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-MnaOwnedApi) -and $localClock.Elapsed.TotalSeconds -lt 8) {
        if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
        $trialProcess.Refresh()
        if ($trialProcess.HasExited) { throw 'SDK 在本地接口就绪前退出' }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-MnaOwnedApi)) { throw '本地 SDK 接口未就绪' }
    Write-MnaUiStatus -Phase starting -Message '正在连接香港线路…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '连接香港线路'
    foreach ($step in @(
        @{Step='configure_device';Route='/api/v2/client/mp-speeder';Body=@{serviceMode=0;dataKey=$uiDataKey;scheduleMode='rtc';tunInterfaceName='mp_tun0';t2Probe=$true}},
        @{Step='configure_hongkong';Route='/api/v2/client/multi-mode';Body=@{area='hongkong';speedMode=35}},
        @{Step='configure_socks';Route='/api/v2/client/socks5';Body=@{enable=$true;port=12345;userName=$trialSocksUser;passWord=$trialSocksPassword}}
    )) {
        if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
        $response=Invoke-MnaTrialApi -Step $step.Step -Method Post -Route $step.Route -Body $step.Body -TimeoutSeconds 5
        if (-not $response.HttpSucceeded) {
            $last=$trialEvents[$trialEvents.Count-1]
            throw ('SDK 配置失败：'+$step.Step+'；HTTP '+$last.HttpStatus+'；'+$last.Message)
        }
    }
    $step=$null;$response=$null;$uiDataKey=$null
    # Start is asynchronous: a slow HTTP call must not prevent the 30-second ready checks.
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.UseProxy=$false
    $uiStartClient=[Net.Http.HttpClient]::new($handler)
    $uiStartClient.Timeout=[TimeSpan]::FromSeconds(35)
    $readyClock=[Diagnostics.Stopwatch]::StartNew()
    $uiStartTask=$uiStartClient.PostAsync(($trialApiBase+'/api/v2/client/mp-speeder/start'),$null)
    do {
        if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
        Update-MnaOwnedProcesses
        Save-MnaUiOwnership $RunId
        if ($uiStartTask.IsCompleted -and -not $uiStartRecorded) {
            $uiStartRecorded=$true
            try {
                $startHttp=$uiStartTask.GetAwaiter().GetResult()
                $startText=$startHttp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $startPayload=$null
                try { $startPayload=$startText | ConvertFrom-Json -Depth 30 -ErrorAction Stop } catch { }
                $safe=Get-MnaSafeResponse $startPayload
                $startMessage=$null
                foreach ($name in @('message','msg','errorMessage','error')) {
                    $candidate=Find-MnaResponseValue $startPayload $name
                    if ($candidate -is [string]) { $startMessage=Protect-MnaTrialMessage $candidate;break }
                }
                $trialEvents.Add([pscustomobject]@{At=Get-Date -Format o;Step='start';HttpStatus=[int]$startHttp.StatusCode;Fields=$safe.Fields;FieldNames=$safe.FieldNames;Message=$startMessage})
                if (-not $startHttp.IsSuccessStatusCode) { $uiStartMessage='启动接口 HTTP '+[int]$startHttp.StatusCode+'；'+$startMessage }
                $startText=$null;$startPayload=$null;$startHttp.Dispose()
            } catch { $trialEvents.Add([pscustomobject]@{At=Get-Date -Format o;Step='start_request';Message=(Protect-MnaTrialMessage $_.Exception.Message)}) }
        }
        $state=Invoke-MnaTrialApi -Step state -Method Get -Route '/api/v2/client/mp-speeder' -TimeoutSeconds 3
        $ready=Find-MnaResponseValue $state.Raw ready
        if ($state.HttpSucceeded -and ($ready -eq $true -or [string]$ready -eq 'true' -or [string]$ready -eq '1')) {
            $uiRecord.ReadyObserved=$true
            $uiGateway=Protect-MnaTrialMessage (Find-MnaResponseValue $state.Raw accGateway)
            $state=$null
            break
        }
        $state=$null
        Start-Sleep -Milliseconds 500
    } while ($readyClock.Elapsed.TotalSeconds -lt 30)
    if (-not $uiRecord.ReadyObserved) { throw ('30 秒内未确认云端连接就绪；'+$uiStartMessage+'；正在停止并清理，请查看本地测试记录') }
    Write-MnaUiStatus -Phase starting -Message '正在验证线路连接…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '验证线路连接'
    Update-MnaOwnedProcesses
    Save-MnaUiOwnership $RunId
    $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {$_.LocalPort -eq 12345 -and $_.LocalAddress -eq '127.0.0.1' -and $trialOwned.ContainsKey([int]$_.OwningProcess)})
    if (-not $listeners.Count) { throw 'SDK 已就绪，但本次拥有的本地 SOCKS 端口未就绪' }
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    $flowBefore=Invoke-MnaTrialApi -Step flow_before -Method Get -Route '/api/v2/client/flowStatistics' -Headers @{all='true'} -TimeoutSeconds 3
    $flowBefore=$null
    $trace=Invoke-MnaSocksTrace -TimeoutSeconds 10
    $uiRecord.Trace=$trace
    if (-not $trace.Succeeded) { throw ('连接认证成功，但测试请求失败：'+$trace.Message) }
    $uiRecord.SocksVerified=$true
    $uiExitIp=$trace.EgressIP
    $flowAfter=Invoke-MnaTrialApi -Step flow_after -Method Get -Route '/api/v2/client/flowStatistics' -Headers @{all='true'} -TimeoutSeconds 3
    $flowAfter=$null
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    Write-MnaUiStatus -Phase starting -Message '正在验证本机连接…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '验证线路连接'
    $nativeBefore=Invoke-MnaUiNativeStun
    $uiRecord.NativeUdpBefore=$nativeBefore
    if (-not $nativeBefore.Success) { throw ('原生 UDP 基线未通过：'+$nativeBefore.Message) }
    $plainBefore=Invoke-MnaSocksTrace -Direct -TimeoutSeconds 8
    $uiRecord.PlainHttpsBefore=$plainBefore
    if (-not $plainBefore.Succeeded) { throw '开启前普通网页连接检查未通过，请检查网络后重试' }
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    $uiRecord.GameTargetCount=1
    $uiRecord.GameExecutableCount=@($uiSettings.GameExecutables).Count
    Write-MnaUiStatus -Phase starting -Message '正在建立游戏解析路由…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '建立游戏解析路由'
    $uiGameRouteSession=New-MnaGameRouteSession -RunId $RunId -SocksUser $trialSocksUser -SocksPassword $trialSocksPassword -GameExecutable $uiSettings.GameExecutable -GameExecutables $uiSettings.GameExecutables
    $gameRoute=Start-MnaGameRoute -Session $uiGameRouteSession -OwnedProcesses $trialOwned
    Save-MnaUiOwnership $RunId
    $uiRecord.GameRouteConfigured=$gameRoute.GameRoutingConfigured
    $uiRecord.VirtualDns=$gameRoute.VirtualDns
    if (-not $gameRoute.GameRoutingConfigured) { throw '游戏引流配置未确认生效' }
    # The release only forwards this game's confirmed HTTPDNS entry, plus its
    # two process-scoped health probes. No battle endpoint is added to the TUN.
    $actualRoutes=@(Get-NetRoute -InterfaceAlias $uiGameRouteSession.TunName -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object DestinationPrefix)
    $allowedPrefixes=@('182.254.116.117/32','162.159.207.0/32','1.1.1.1/32','198.18.0.0/30','198.18.0.1/32','198.18.0.3/32','224.0.0.0/4','255.255.255.255/32')
    $unexpected=@($actualRoutes | Where-Object { $_ -notin $allowedPrefixes })
    if ($unexpected.Count -or '182.254.116.117/32' -notin $actualRoutes) { throw '解析优化模式路由范围不符，已自动关闭' }
    $uiRecord.BattleDirectPolicyVerified=$true
    $uiRecord.ForwardedService='182.254.116.117:80/TCP'
    Write-MnaUiStatus -Phase starting -Message '正在验证解析路由…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '验证解析路由'
    $plainAfter=Invoke-MnaSocksTrace -Direct -TimeoutSeconds 8
    $uiRecord.PlainHttpsAfter=$plainAfter
    if (-not $plainAfter.Succeeded -or $plainAfter.EgressIP -ne $plainBefore.EgressIP) { throw '游戏接管影响了普通网页连接，已自动关闭；请查看本地检测记录' }
    $tcpProbe=Invoke-MnaSocksTrace -Direct -ProbeTcp -TimeoutSeconds 8
    $uiRecord.TransparentTcp=$tcpProbe
    if (-not $tcpProbe.Succeeded -or $tcpProbe.EgressIP -eq $plainBefore.EgressIP) { throw '游戏 TCP 线路检测未通过，本次连接已关闭' }
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    $nativeAfter=Invoke-MnaUiNativeStun
    $uiRecord.NativeUdpAfter=$nativeAfter
    if (-not $nativeAfter.Success -or $nativeAfter.MappedIP -eq $nativeBefore.MappedIP) { throw '透明 UDP 测试未证明出口发生变化，本次不标记连接成功' }
    $uiRecord.UdpRoutingVerified=$true
    $uiExitIp=$nativeAfter.MappedIP
    if (Test-MnaUiStopRequested) { $uiStopRequested=$true;throw '用户已请求关闭' }
    Write-MnaUiStatus -Phase connected -Message '主入口优化已开启' -Ready $true -Gateway $uiGateway -ExitIp $uiExitIp -RunId $RunId -GameRoutingConfigured $true -UdpRoutingVerified $true -RoutingMode $RoutingMode
    $healthFailures=0
    while (-not (Test-MnaUiStopRequested)) {
        for ($tick=0;$tick -lt 2 -and -not (Test-MnaUiStopRequested);$tick++) { Start-Sleep -Milliseconds 500 }
        if (Test-MnaUiStopRequested) { break }
        Update-MnaOwnedProcesses
        Save-MnaUiOwnership $RunId
        $state=Invoke-MnaTrialApi -Step health -Method Get -Route '/api/v2/client/mp-speeder' -TimeoutSeconds 3
        $ready=Find-MnaResponseValue $state.Raw ready
        $gameRoute=Get-MnaGameRouteStatus -Session $uiGameRouteSession -IncludeConnections
        if (-not $gameRoute.GameRoutingConfigured) { throw '游戏引流不再处于就绪状态，正在关闭本次连接' }
        if ($gameRoute.GameRoutingVerified) {
            $uiGameVerified=$true
            $uiRecord.GameRoutingEvidence=[pscustomobject]@{At=Get-Date -Format o;RoutedGameUdpConnections=$gameRoute.RoutedGameUdpConnections;Source='exact_process_path_proxy_chain_udp'}
        }
        $uiRecord.GameRoutingVerified=$uiGameVerified
        $uiRecord.LastGameConnectionCounts=[pscustomobject]@{Game=$gameRoute.GameConnections;Routed=$gameRoute.RoutedGameConnections;RoutedUdp=$gameRoute.RoutedGameUdpConnections}
        if ($state.HttpSucceeded -and ($ready -eq $true -or [string]$ready -eq 'true' -or [string]$ready -eq '1')) {
            $healthFailures=0
            Write-MnaUiStatus -Phase connected -Message '主入口优化已开启' -Ready $true -Gateway $uiGateway -ExitIp $uiExitIp -RunId $RunId -GameRoutingConfigured $true -UdpRoutingVerified $true -GameRoutingVerified $uiGameVerified -RoutingMode $RoutingMode
        } else {
            $healthFailures++
            Write-MnaUiStatus -Phase starting -Message '正在检查线路状态…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '检查线路状态'
        }
        $state=$null
        while ($trialEvents.Count -gt 200) { $trialEvents.RemoveAt(0) }
        if ($healthFailures -ge 3) { throw '连续检查未确认连接仍然就绪，正在关闭本次连接' }
    }
    $uiStopRequested=$true
} catch {
    if (-not $uiStopRequested) { $uiFailure=Protect-MnaTrialMessage $_.Exception.Message }
} finally {
    try {
        if ($uiRunAccepted) {
            # Status/report I/O must never prevent the actual cleanup below.
            try { Write-MnaUiStatus -Phase stopping -Message $(if ($uiFailure) { $uiFailure+'；正在清理本次连接' } else { '正在关闭本次连接并检查网络恢复情况' }) -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '关闭游戏解析路由' }
            catch { $uiFailure=($uiFailure+'；状态文件写入失败').Trim('；') }
            # Stop transparent TUN first; the SDK's SOCKS endpoint is its dependency.
            if ($uiGameRouteSession) {
                try { $uiRecord.GameRouteCleanup=Stop-MnaGameRoute -Session $uiGameRouteSession -OwnedProcesses $trialOwned }
                catch { $uiRecord.GameRouteCleanup=[pscustomobject]@{ProcessStopped=$false;Errors=@((Protect-MnaTrialMessage $_.Exception.Message))} }
            }
            try { Write-MnaUiStatus -Phase stopping -Message '正在关闭香港线路…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '关闭香港线路' } catch { }
            try { $cleanup=Stop-MnaUiOwnedRuntime }
            catch { $cleanup=[pscustomobject]@{RemainingOwnedProcessCount=$null;Errors=@([pscustomobject]@{Step='cleanup';Message=(Protect-MnaTrialMessage $_.Exception.Message)})} }
            if ($uiGameRouteSession -and (-not $uiRecord.GameRouteCleanup.ProcessStopped -or @($uiRecord.GameRouteCleanup.Errors).Count)) {
                try { $uiRecord.GameRouteCleanupAfterFallback=Stop-MnaGameRoute -Session $uiGameRouteSession -OwnedProcesses $trialOwned } catch { }
            }
            $uiRecord.Cleanup=$cleanup
            if ($uiStartClient) { try { $uiStartClient.Dispose() } catch { };$uiStartClient=$null }
            try { Write-MnaUiStatus -Phase stopping -Message '正在检查网络恢复情况…' -RunId $RunId -RoutingMode $RoutingMode -ProgressStage '检查网络恢复情况' } catch { }
            try {
                $release=Get-MnaUiReleasedResourceState -BaselineState $uiBefore
                $after=$release.State
                $uiRecord.ResourceRelease=$release.Assessment
                $uiRecord.SettlingChecks=$release.Attempts-1
                $uiRecord.NetworkResourcesReleased=$release.Assessment.Released
                if (-not $release.Assessment.Released) { $uiFailure=($uiFailure+'；本次加速资源尚未完全释放或读取未完成，请稍后重试').Trim('；') }
                if ($uiBefore) {
                    $diff=Compare-TrialNetworkState -BaselineState $uiBefore -CurrentState $after
                    $uiRecord.ComparisonPath=Save-TrialNetworkState -State $diff -Label ui_comparison
                    $uiRecord.NetworkFullyComparable=$diff.FullyComparable
                    $uiRecord.NetworkEqual=$diff.Equal
                    # Equality is diagnostic only. External applications and
                    # Windows own their network state throughout this session.
                    $uiRecord.NetworkConfigurationEqual=$diff.Equal
                }
                $uiRecord.AfterPath=Save-TrialNetworkState -State $after -Label ui_after
            } catch { $uiFailure=($uiFailure+'；结束后的网络检查失败').Trim('；') }
            if ($null -eq $cleanup.RemainingOwnedProcessCount -or $cleanup.RemainingOwnedProcessCount -gt 0 -or $cleanup.Errors.Count) { $uiFailure=($uiFailure+'；本次进程清理尚未完全确认').Trim('；') }
            if ($uiGameRouteSession) {
                $finalGameCleanup=if ($uiRecord.GameRouteCleanupAfterFallback) { $uiRecord.GameRouteCleanupAfterFallback } else { $uiRecord.GameRouteCleanup }
                if (-not $finalGameCleanup.ProcessStopped -or @($finalGameCleanup.Errors).Count) { $uiFailure=($uiFailure+'；游戏解析路由清理尚未完全确认').Trim('；') }
            }
            $uiRecord.Failure=$uiFailure
            $uiRecord.Events=@($trialEvents.ToArray())
            $uiRecord.FinishedAt=Get-Date -Format o
            try { $null=Save-TrialNetworkState -State ([pscustomobject]$uiRecord) -Label ui_connection }
            catch { $uiFailure=($uiFailure+'；报告写入失败').Trim('；') }
            try {
                if ($uiFailure) { Write-MnaUiStatus -Phase error -Message $uiFailure -RunId $RunId -RoutingMode $RoutingMode }
                else { Write-MnaUiStatus -Phase stopped -Message $(if ($uiExpired) {'本次免费试用已到期，本机加速已关闭；请核对腾讯云服务状态'} elseif ($uiRecord.NetworkEqual -eq $false) {'加速器已关闭；当前网络变化已记录'} else {'加速器已关闭'}) -RunId $RunId -RoutingMode $RoutingMode }
            } catch { } # A subsequent read-only Status reports the exited worker as an error.
        }
    } finally {
        if ($uiStartClient) { try { $uiStartClient.Dispose() } catch { } }
        if ($uiClearKey) { [Array]::Clear($uiClearKey,0,$uiClearKey.Length) }
        $uiDataKey=$null;$trialSocksUser=$null;$trialSocksPassword=$null
        $trialSensitiveStrings.Clear()
    }
}
