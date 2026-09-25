#requires -Version 7.0
<# Offline control-flow regression. Copies the real Control and SessionRecovery
   scripts into a new fixture, imports only reviewed file/status helpers, and
   replaces process/network/SDK effects. Cross-boot identity and release use the
   real production classifier and real snapshot comparison, never boolean mocks.
   No real installation, settings, keys, adapters or processes are accessed. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw '此恢复流程回归需要 Windows' }
$backend=Join-Path (Split-Path $PSScriptRoot -Parent) 'app/backend'
$fixtureBase=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'session-recovery-work'))
$runToken=[guid]::NewGuid().ToString('N')
$fixtureRoot=Join-Path $fixtureBase $runToken
$checks=[Collections.Generic.List[object]]::new()
$cleanupVerified=$false

function Assert-Recovery([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('恢复流程断言失败：'+$Message) }
}
function Write-FixtureJson([string]$Path,$Value) {
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
}
function Read-FixtureJson([string]$Path) {
    [IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 20
}
function Get-FixtureText([string]$Path) { [IO.File]::ReadAllText($Path) }
function Test-RecoveryCase([string]$Name,[scriptblock]$Action) {
    try { $null=& $Action; $checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Failure=$null}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Failure=$_.Exception.Message.Replace($fixtureRoot,'[fixture]')}) }
}

# These production functions only read/write fixture files. The actual control
# script is executed unchanged, including its lock, catch and Start ordering.
$tokens=$null;$parseErrors=$null
$commonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $backend 'Mna-UI.Common.ps1'),[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw '后端公共函数语法检查失败' }
$commonParts=[Collections.Generic.List[string]]::new()
$commonParts.Add('$script:MnaUiRoot=$PSScriptRoot; $script:MnaUiOwnershipSaved=@{}')
foreach ($name in @('Get-MnaUiPaths','Get-MnaRunFile','Read-MnaUiJson','Write-MnaUiJson','Write-MnaUiStatus','Get-MnaUiStatus','Save-MnaUiOwnership','ConvertTo-MnaUiOperationTime','Protect-MnaTrialMessage','Initialize-MnaUiRuntimeVariables','Assert-MnaUiPreviousRunClear','Get-MnaUiReleasedResourceState')) {
    $definitions=@($commonAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name)
    if ($definitions.Count -ne 1) { throw ('后端函数未唯一找到：'+$name) }
    $commonParts.Add($definitions[0].Extent.Text)
}
$commonParts.Add(@'
function Test-MnaUiWorker { param($Record) return $fixtureScenario.WorkerAlive }
function Test-MnaFreeTrialExpired { return $false }
function Assert-MnaReleaseConfiguration { $fixtureScenario.Events.Add('configuration'); return [pscustomobject]@{} }
function New-MnaHexSecret { param($ByteCount) $fixtureScenario.RunCounter++; return ([string][char](97+$fixtureScenario.RunCounter))*24 }
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
    $fixtureScenario.Events.Add('start-worker')
    $fixtureScenario.PhaseAtStart=(Read-MnaUiJson (Get-MnaUiPaths).Status).phase
    $fixtureScenario.WorkerAlive=$true
    if ($fixtureScenario.RunCheckpoint) { throw 'fixture Run crossed the SDK checkpoint' }
    [pscustomobject]@{Id=$PID;StartTime=$fixtureScenario.WorkerStartTime;Path=$FilePath}
}
function Get-Process {
    param($Name,$Id,$ErrorAction)
    if ($fixtureScenario.RunCheckpoint -and $Name) { throw 'fixture stopped before SDK startup' }
    return $null
}
function Stop-Process { throw '离线验证禁止停止真实进程' }
function Start-Sleep { param($Milliseconds) $fixtureScenario.Events.Add('wait-'+$Milliseconds) }
function Get-CimInstance {
    param($ClassName,$Property,$Filter,$ErrorAction)
    if ($ClassName -eq 'Win32_OperatingSystem') {
        $fixtureScenario.Events.Add('read-boot')
        if ($fixtureScenario.BootReadThrows) { throw 'fixture boot time unavailable' }
        return [pscustomobject]@{LastBootUpTime=$fixtureScenario.BootTime}
    }
    if ($ClassName -eq 'Win32_Process') { return $null }
    throw '离线验证禁止读取其他系统状态'
}
function Stop-MnaUiOwnedRuntime {
    $fixtureScenario.Events.Add('cleanup-sdk')
    return $fixtureScenario.Cleanup
}
function Test-MnaUiConfigurationRestored {
    param($Comparison,$BaselineState,$CurrentState)
    $fixtureScenario.Events.Add('classify-normal')
    return $fixtureScenario.Restored
}
function Invoke-WebRequest { throw '离线验证禁止网络请求' }
function Invoke-RestMethod { throw '离线验证禁止网络请求' }
function Get-NetAdapter { throw '离线验证禁止访问网卡' }
function Get-NetRoute { throw '离线验证禁止访问路由' }
function New-NetRoute { throw '离线验证禁止修改路由' }
function Remove-NetRoute { throw '离线验证禁止修改路由' }
function Set-DnsClientServerAddress { throw '离线验证禁止修改 DNS' }
'@)
$networkMock=@'
function Get-TrialNetworkState {
    $fixtureScenario.Events.Add('inventory')
    if ($fixtureScenario.InventoryQueue.Count) { return $fixtureScenario.InventoryQueue.Dequeue() }
    return $fixtureScenario.Network
}
function Save-TrialNetworkState {
    param($State,$Label)
    $fixtureScenario.Events.Add('save-'+$Label)
    if ($Label -in $fixtureScenario.SaveFailureLabels) { throw [IO.IOException]::new('fixture diagnostic report write failed') }
    $fixtureScenario.SaveCounter++
    $path=Join-Path (Get-MnaUiPaths).Root ('results/'+$Label+'-'+$fixtureScenario.SaveCounter+'.json')
    Write-MnaUiJson $path $State
    $fixtureScenario.SavedPaths[$Label]=$path
    return $path
}
'@
# Preserve real diff semantics, including incomplete snapshots and timestamps.
$networkAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $backend 'Trial-NetworkState.ps1'),[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw '网络比较函数语法检查失败' }
$comparisonDefinition=@($networkAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq 'Compare-TrialNetworkState')
if ($comparisonDefinition.Count -ne 1) { throw '真实网络比较函数未唯一找到' }
$networkMock+="`n"+$comparisonDefinition[0].Extent.Text
$gameRouteMock=@'
function Stop-MnaGameRouteRecovery {
    param($RunId,$OwnedProcesses)
    $fixtureScenario.Events.Add('cleanup-route')
    if ($fixtureScenario.RouteThrows) { throw 'fixture game route cleanup failure' }
    return $fixtureScenario.GameRouteCleanup
}
'@

function New-RecoveryFixture([string]$Name,[switch]$Owner,[switch]$NoWorker,[string]$Phase='error') {
    $root=Join-Path $fixtureRoot $Name
    $null=[IO.Directory]::CreateDirectory($root)
    foreach ($file in @('Control-Accelerator.ps1','Mna-SessionRecovery.ps1','Mna-RebootRecovery.ps1','Mna-ReleasedResources.ps1','Mna-RouterAdvertisementRecovery.ps1')) { Copy-Item -LiteralPath (Join-Path $backend $file) -Destination (Join-Path $root $file) }
    [IO.File]::WriteAllText((Join-Path $root 'Mna-UI.Common.ps1'),($commonParts -join "`n"))
    [IO.File]::WriteAllText((Join-Path $root 'Trial-NetworkState.ps1'),$networkMock)
    [IO.File]::WriteAllText((Join-Path $root 'Mna-GameRoute.ps1'),$gameRouteMock)
    [IO.File]::WriteAllText((Join-Path $root 'Run-Accelerator.ps1'),"throw 'fixture must never execute worker'")
    $runId='aaaaaaaaaaaaaaaaaaaaaaaa'
    $scenario=[pscustomobject]@{
        Root=$root;RunId=$runId;Worker=(Join-Path $root 'private/ui-worker.json')
        Status=(Join-Path $root 'results/ui-status.json');Owner=(Join-Path $root ('private/ui-ownership-'+$runId+'.json'))
        Baseline=(Join-Path $root 'results/before.json');StopRequest=(Join-Path $root ('private/ui-stop-'+$runId+'.json'))
        Events=[Collections.Generic.List[string]]::new();WorkerAlive=$false;Restored=$true;RouteThrows=$false;PhaseAtStart=$null
        BootTime=[datetime]'2026-09-15T00:00:00Z';BootReadThrows=$false;WorkerStartTime=[datetime]'2026-09-16T00:00:00Z';RunCounter=0;RunCheckpoint=$false;SaveCounter=0;SavedPaths=@{};SaveFailureLabels=@();InventoryQueue=[Collections.Generic.Queue[object]]::new()
        Network=[pscustomobject]@{SchemaVersion=1;Complete=$true;ReadErrors=@();StartedAt='2026-09-17T02:00:00Z';FinishedAt='2026-09-17T02:00:02Z';Data=[pscustomobject]@{
            RelatedProcesses=@();Adapters=@();Interfaces=@();IPAddresses=@();ActiveRoutes=@();PersistentRoutes=@();DNS=@()
            RelatedServices=@();RelatedDrivers=@();WinINETProxy=@();WinHTTPProxy=@()
        }}
        Cleanup=[pscustomobject]@{RemainingOwnedProcessCount=0;Errors=@()}
        GameRouteCleanup=[pscustomobject]@{ProcessStopped=$true;Errors=@()}
    }
    if (-not $NoWorker) {
        Write-FixtureJson $scenario.Worker ([pscustomobject]@{RunId=$runId;WorkerPid=98765;WorkerCreatedUtc='2026-09-16T00:00:00Z';WorkerExecutable='fixture';WorkerScript=(Join-Path $root 'Run-Accelerator.ps1')})
    }
    Write-FixtureJson $scenario.Status ([pscustomobject]@{phase=$Phase;message='fixture previous state';runId=$runId;ready=($Phase -eq 'connected');gameRoutingConfigured=$true;udpRoutingVerified=$true})
    if ($Owner) {
        Write-FixtureJson $scenario.Baseline $scenario.Network
        Write-FixtureJson $scenario.Owner ([pscustomobject]@{
            RunId=$runId;RootPid=98766;RootCreated='2026-09-16T00:00:00Z'
            Runtime=(Join-Path $root 'vendor_inspection/sdk_v0.23.1/linkboost');BeforePath=$scenario.Baseline
            Owned=@([pscustomobject]@{Pid=98766;Created='2026-09-16T00:00:00Z';Depth=0;Kind='SDK';ExecutablePath=(Join-Path $root 'vendor_inspection/sdk_v0.23.1/linkboost/linkboost.exe')})
        })
    }
    return $scenario
}
function Invoke-RecoveryControl($Scenario,[string]$Action='Recover') {
    # Object mutations survive the child script scope; no global mocks are used.
    $fixtureScenario=$Scenario
    $output=& (Join-Path $Scenario.Root 'Control-Accelerator.ps1') -Action $Action
    $output -join "`n" | ConvertFrom-Json -Depth 12
}
function Assert-RecoveryRejected($Scenario,[string]$Action='Recover') {
    $pointer=Get-FixtureText $Scenario.Worker
    $owner=if (Test-Path -LiteralPath $Scenario.Owner) { Get-FixtureText $Scenario.Owner } else { $null }
    $baseline=if (Test-Path -LiteralPath $Scenario.Baseline) { Get-FixtureText $Scenario.Baseline } else { $null }
    $result=Invoke-RecoveryControl $Scenario $Action
    Assert-Recovery ($result.phase -eq 'error') '恢复失败必须显示 error'
    Assert-Recovery ((Get-FixtureText $Scenario.Worker) -ceq $pointer) '失败不得覆盖旧 worker pointer'
    if ($null -ne $owner) { Assert-Recovery ((Get-FixtureText $Scenario.Owner) -ceq $owner) '保留原归属证据' }
    if ($null -ne $baseline) { Assert-Recovery ((Get-FixtureText $Scenario.Baseline) -ceq $baseline) '保留原基线证据' }
    Assert-Recovery (-not $Scenario.Events.Contains('start-worker')) '恢复失败不得启动新 worker'
}

function Set-PreviousBootFixture($Scenario) {
    $Scenario.BootTime=[datetime]'2026-09-17T00:00:00Z'
    $Scenario.Restored=$false
    # Independent host changes must not prevent release of an extinct session.
    $Scenario.Network.Data.Adapters=@([pscustomobject]@{Name='New Wi-Fi';ifIndex=17;InterfaceDescription='Fixture changed hardware';HardwareInterface=$true;Virtual=$false})
    $Scenario.Network.Data.Interfaces=@([pscustomobject]@{InterfaceAlias='New Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';InterfaceMetric=45})
    $Scenario.Network.Data.IPAddresses=@([pscustomobject]@{InterfaceAlias='New Wi-Fi';InterfaceIndex=17;IPAddress='169.254.20.30';AddressFamily='IPv4';PrefixLength=16})
    $Scenario.Network.Data.ActiveRoutes=@([pscustomobject]@{InterfaceAlias='New Wi-Fi';InterfaceIndex=17;AddressFamily='IPv4';DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=55})
    $Scenario.Network.Data.DNS=@([pscustomobject]@{InterfaceAlias='New Wi-Fi';InterfaceIndex=17;ServerAddresses=@('192.0.2.99')})
    $Scenario.Network.Data.WinINETProxy=@([pscustomobject]@{ProxyEnable=1;ProxyServer='fixture-proxy:8080';CurrentUserConfiguration=[pscustomobject]@{Proxy='fixture-proxy:8080';AutoConfigURL=$null}})
    $Scenario.Network.Data.WinHTTPProxy=@([pscustomobject]@{AccessType=3;Proxy='fixture-proxy:8081'})
}
function Assert-NoOldProcessCleanup($Scenario) {
    Assert-Recovery (-not $Scenario.Events.Contains('cleanup-sdk') -and -not $Scenario.Events.Contains('cleanup-route')) '旧 boot 会话不得操作旧 PID 或旧 REST endpoint'
    Assert-Recovery (-not $Scenario.Events.Contains('classify-normal')) '跨 boot 释放不要求旧主机网络相等'
}
function Invoke-FixtureRunBeforeSdk($Scenario,[string]$ExpectedFailure='fixture stopped before SDK startup') {
    # Execute the production worker through its real fresh-baseline checkpoint.
    # Only the two Windows elevation prerequisite statements are omitted from
    # this fixture copy. Get-Process then deliberately stops it before SDK,
    # ports, key access, DPAPI or HTTP. The real catch/finally still execute.
    $sourcePath=Join-Path $backend 'Run-Accelerator.ps1'
    $t=$null;$e=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$t,[ref]$e)
    Assert-Recovery (@($e).Count -eq 0) 'Run 源码语法正确'
    $guards=@($ast.FindAll({param($n)
        ($n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$principal') -or
        ($n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.Contains('$principal.IsInRole('))
    },$true))
    Assert-Recovery ($guards.Count -eq 2) '只替换 Windows 权限前置条件，未改业务控制流'
    $source=$ast.Extent.Text
    foreach ($guard in @($guards | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $source=$source.Remove($guard.Extent.StartOffset,$guard.Extent.EndOffset-$guard.Extent.StartOffset)
    }
    [IO.File]::WriteAllText((Join-Path $Scenario.Root 'Run-Accelerator.ps1'),$source)
    $fixtureScenario=$Scenario
    $Scenario.RunCheckpoint=$true
    try { $null=& (Join-Path $Scenario.Root 'Run-Accelerator.ps1') -RunId (Read-FixtureJson $Scenario.Worker).RunId }
    finally { $Scenario.RunCheckpoint=$false }
    Assert-Recovery ($Scenario.SavedPaths.ContainsKey('ui_before')) '真实 Run 在 SDK 前持久化全新基线'
    $connection=Read-FixtureJson $Scenario.SavedPaths.ui_connection
    Assert-Recovery ($connection.Failure.Contains($ExpectedFailure)) '真实 Run 确实停在 SDK、设备密钥和网络访问之前'
}
function Save-FixtureConnectedSession($Scenario) {
    $fixtureScenario=$Scenario
    . (Join-Path $Scenario.Root 'Mna-UI.Common.ps1')
    . Initialize-MnaUiRuntimeVariables
    $record=Read-MnaUiJson $Scenario.Worker
    $Scenario.RunId=$record.RunId
    $Scenario.Owner=Get-MnaRunFile $record.RunId ownership
    $Scenario.StopRequest=Get-MnaRunFile $record.RunId stop
    $Scenario.Baseline=$Scenario.SavedPaths.ui_before
    $trialProcess=[pscustomobject]@{Id=98766}
    $trialStartTime=$Scenario.WorkerStartTime.AddSeconds(1)
    $trialOwned=@{98766=[pscustomobject]@{Pid=98766;Created=$trialStartTime;Depth=0;Kind='SDK';ExecutablePath=$trialExecutable}}
    $uiBeforePath=$Scenario.Baseline
    Save-MnaUiOwnership $record.RunId
    Write-MnaUiStatus -Phase connected -Message 'fixture connected' -RunId $record.RunId -Ready $true -GameRoutingConfigured $true -UdpRoutingVerified $true
}
function New-FixtureExpiredCredentials($Scenario) {
    $directory=Join-Path $Scenario.Root ('private/game-route-'+$Scenario.RunId)
    $neighbor=Join-Path $Scenario.Root 'private/game-route-dddddddddddddddddddddddd'
    $null=[IO.Directory]::CreateDirectory($directory)
    $null=[IO.Directory]::CreateDirectory($neighbor)
    $files=[pscustomobject]@{Configuration=(Join-Path $directory 'game-route.yaml');Recovery=(Join-Path $directory 'recovery.json');Log=(Join-Path $directory 'helper.stdout.log');Neighbor=(Join-Path $neighbor 'game-route.yaml')}
    foreach ($path in @($files.Configuration,$files.Recovery,$files.Log,$files.Neighbor)) { [IO.File]::WriteAllText($path,'fixture only, no credentials') }
    return $files
}

try {
    Test-RecoveryCase 'Recover 遇到活跃 worker 不关闭、不扫描、不改状态' {
        $case=New-RecoveryFixture 'live' -Owner -Phase connected;$case.WorkerAlive=$true
        $status=Get-FixtureText $case.Status;$pointer=Get-FixtureText $case.Worker
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'connected' -and $case.Events.Count -eq 0) '活跃连接保持原状'
        Assert-Recovery (-not (Test-Path -LiteralPath $case.StopRequest)) 'Recover 不发送 Stop'
        Assert-Recovery ((Get-FixtureText $case.Status) -ceq $status -and (Get-FixtureText $case.Worker) -ceq $pointer) '状态与 pointer 不变'
    }
    Test-RecoveryCase 'Status 对已退出 worker 只返回错误视图、不执行恢复' {
        $case=New-RecoveryFixture 'status-read-only' -Owner -Phase connected
        $status=Get-FixtureText $case.Status
        $result=Invoke-RecoveryControl $case Status
        Assert-Recovery ($result.phase -eq 'error' -and $case.Events.Count -eq 0) '只读 Status 不扫描、不清理'
        Assert-Recovery ((Get-FixtureText $case.Status) -ceq $status) 'Status 不持久化错误或恢复结果'
        Assert-Recovery (-not (Test-Path -LiteralPath (Join-Path $case.Root 'private/ui-control.lock'))) 'Status 不获取写锁'
    }
    foreach ($phase in @('starting','connected','stopping','error')) {
        Test-RecoveryCase ('无 owner 的 stale '+$phase+' 状态可自动恢复') {
            $case=New-RecoveryFixture ('stale-'+$phase) -Phase $phase
            $result=Invoke-RecoveryControl $case
            Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('inventory')) '完整无残留清单允许恢复'
            Assert-Recovery (-not $case.Events.Contains('cleanup-sdk') -and -not $case.Events.Contains('cleanup-route')) '无 owner 不尝试清理进程'
        }
    }
    Test-RecoveryCase '无 worker pointer 的损坏状态可在完整无残留清单后恢复' {
        $case=New-RecoveryFixture 'status-corrupt' -NoWorker
        [IO.File]::WriteAllText($case.Status,'{broken')
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('inventory')) '修复孤立损坏状态'
        Assert-Recovery (-not (Test-Path -LiteralPath $case.Worker)) '恢复不伪造 worker pointer'
    }
    Test-RecoveryCase '成功恢复后重复 Recover 幂等，保留原基线和证据' {
        $case=New-RecoveryFixture 'idempotent' -Owner
        $baseline=Get-FixtureText $case.Baseline;$owner=Get-FixtureText $case.Owner
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('save-ui_recovery_comparison')) '第一次恢复清理并比较'
        $eventCount=$case.Events.Count;$status=Get-FixtureText $case.Status
        $case.Restored=$false;$case.Network.Complete=$false
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Count -eq $eventCount) '完成后不重复比较旧基线'
        Assert-Recovery ((Get-FixtureText $case.Status) -ceq $status) '幂等恢复不改状态时间'
        Assert-Recovery ((Get-FixtureText $case.Baseline) -ceq $baseline -and (Get-FixtureText $case.Owner) -ceq $owner) '原始证据保持不变'
    }
    Test-RecoveryCase '显式 Stop 对已完成状态仍重新检查' {
        $case=New-RecoveryFixture 'force-stop' -Owner -Phase stopped
        $result=Invoke-RecoveryControl $case Stop
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('inventory')) 'Force Stop 不走幂等快速返回'
    }
    Test-RecoveryCase '已完成记录后新出现残留，Start 不覆盖旧 pointer' {
        $case=New-RecoveryFixture 'stopped-new-residue' -Owner -Phase stopped
        $case.Network.Data.Adapters=@([pscustomobject]@{Name='mna_game_aaaaaa';ifIndex=99})
        Assert-RecoveryRejected $case Start
        Assert-Recovery (-not $case.Events.Contains('configuration')) '资源检查先于启动配置与新 pointer'
    }
    Test-RecoveryCase 'worker 在控制预检后再次检查残留，未读取密钥或启动 SDK' {
        $case=New-RecoveryFixture 'worker-preflight-residue' -NoWorker
        Remove-Item -LiteralPath $case.Status
        $started=Invoke-RecoveryControl $case Start
        Assert-Recovery ($started.phase -eq 'starting') '控制预检时清单为空'
        $case.Network.Data.Adapters=@([pscustomobject]@{Name='mna_game_aaaaaa';ifIndex=99})
        Invoke-FixtureRunBeforeSdk $case '开启前检查发现加速资源残留'
        Assert-Recovery ((Read-FixtureJson $case.Status).phase -eq 'error') 'worker 二次预检拦截残留'
    }
    Test-RecoveryCase '跨重启 PAC 指向旧 SDK 端口不能放行' {
        $case=New-RecoveryFixture 'reboot-proxy-pac' -Owner
        Set-PreviousBootFixture $case
        $case.Network.Data.WinINETProxy[0].CurrentUserConfiguration.AutoConfigURL='http://127.0.0.1:9801/proxy.pac'
        Assert-RecoveryRejected $case
        Assert-NoOldProcessCleanup $case
    }
    foreach ($damage in @('worker-json','worker-run-id','owner-json','owner-run-id','owner-runtime','owner-root-pid','owner-root-created','owner-owned-empty','owner-owned-pid','owner-owned-created')) {
        Test-RecoveryCase ('损坏 '+$damage+' 拒绝且保留证据') {
            $case=New-RecoveryFixture $damage -Owner
            switch ($damage) {
                'worker-json' { [IO.File]::WriteAllText($case.Worker,'{broken') }
                'worker-run-id' { $value=Read-FixtureJson $case.Worker;$value.RunId='../invalid';Write-FixtureJson $case.Worker $value }
                'owner-json' { [IO.File]::WriteAllText($case.Owner,'{broken') }
                'owner-run-id' { $value=Read-FixtureJson $case.Owner;$value.RunId='cccccccccccccccccccccccc';Write-FixtureJson $case.Owner $value }
                'owner-runtime' { $value=Read-FixtureJson $case.Owner;$value.Runtime=Join-Path $case.Root 'unowned-runtime';Write-FixtureJson $case.Owner $value }
                'owner-root-pid' { $value=Read-FixtureJson $case.Owner;$value.RootPid=0;Write-FixtureJson $case.Owner $value }
                'owner-root-created' { $value=Read-FixtureJson $case.Owner;$value.RootCreated='invalid-date';Write-FixtureJson $case.Owner $value }
                'owner-owned-empty' { $value=Read-FixtureJson $case.Owner;$value.Owned=@();Write-FixtureJson $case.Owner $value }
                'owner-owned-pid' { $value=Read-FixtureJson $case.Owner;$value.Owned[0].Pid=0;Write-FixtureJson $case.Owner $value }
                'owner-owned-created' { $value=Read-FixtureJson $case.Owner;$value.Owned[0].Created='invalid-date';Write-FixtureJson $case.Owner $value }
                'baseline-json' { [IO.File]::WriteAllText($case.Baseline,'{broken') }
                'baseline-missing' { Remove-Item -LiteralPath $case.Baseline }
                'baseline-outside' { $value=Read-FixtureJson $case.Owner;$value.BeforePath=Join-Path $case.Root 'other-baseline.json';Write-FixtureJson $value.BeforePath $case.Network;Write-FixtureJson $case.Owner $value }
            }
            Assert-RecoveryRejected $case
            if ($damage -match '^(worker|owner)-') { Assert-Recovery (-not $case.Events.Contains('cleanup-sdk') -and -not $case.Events.Contains('cleanup-route')) '归属损坏不清理资源' }
        }
    }
    foreach ($failure in @('route-errors','route-process-live','route-throws','sdk-errors','sdk-process-live','sdk-count-unknown','inventory-incomplete','owned-resources')) {
        Test-RecoveryCase ('Start 遇 '+$failure+' 不成功、不覆写旧 pointer') {
            $case=New-RecoveryFixture $failure -Owner
            switch ($failure) {
                'route-errors' { $case.GameRouteCleanup.Errors=@('fixture cleanup failure') }
                'route-process-live' { $case.GameRouteCleanup.ProcessStopped=$false }
                'route-throws' { $case.RouteThrows=$true }
                'sdk-errors' { $case.Cleanup.Errors=@('fixture cleanup failure') }
                'sdk-process-live' { $case.Cleanup.RemainingOwnedProcessCount=1 }
                'sdk-count-unknown' { $case.Cleanup.RemainingOwnedProcessCount=$null }
                'inventory-incomplete' { $case.Network.Complete=$false }
                'owned-resources' { $case.Network.Data.Adapters=@([pscustomobject]@{Name='mna_game_aaaaaa';ifIndex=99}) }
            }
            Assert-RecoveryRejected $case Start
            Assert-Recovery (-not $case.Events.Contains('configuration')) '恢复失败先于新连接配置检查'
            if ($failure -match '^route-') { Assert-Recovery (@($case.Events | Where-Object { $_ -eq 'cleanup-route' }).Count -eq 2) '线路清理失败会有界重试一次' }
        }
    }
    foreach ($remaining in @('process','adapter','interface','address','active-route','persistent-route','dns','incomplete','missing-section','read-error','wrong-schema')) {
        Test-RecoveryCase ('无 owner 但有 '+$remaining+' 不能报告恢复') {
            $case=New-RecoveryFixture ('unowned-'+$remaining)
            switch ($remaining) {
                'process' { $case.Network.Data.RelatedProcesses=@([pscustomobject]@{Name='linkboost'}) }
                'adapter' { $case.Network.Data.Adapters=@([pscustomobject]@{Name='mna_game_fixture'}) }
                'interface' { $case.Network.Data.Interfaces=@([pscustomobject]@{InterfaceAlias='mp_tun_fixture'}) }
                'address' { $case.Network.Data.IPAddresses=@([pscustomobject]@{InterfaceAlias='mp_tun_fixture'}) }
                'active-route' { $case.Network.Data.ActiveRoutes=@([pscustomobject]@{InterfaceAlias='mp_tun_fixture'}) }
                'persistent-route' { $case.Network.Data.PersistentRoutes=@([pscustomobject]@{InterfaceAlias='mp_tun_fixture'}) }
                'dns' { $case.Network.Data.DNS=@([pscustomobject]@{InterfaceAlias='mp_tun_fixture'}) }
                'incomplete' { $case.Network.Complete=$false }
                'missing-section' { $case.Network.Data.PSObject.Properties.Remove('WinHTTPProxy') }
                'read-error' { $case.Network.ReadErrors=@('fixture inventory failure') }
                'wrong-schema' { $case.Network.SchemaVersion=99 }
            }
            Assert-RecoveryRejected $case
            Assert-Recovery (-not $case.Events.Contains('cleanup-sdk')) '不清理无归属资源'
        }
    }
    Test-RecoveryCase '同一 boot 外部网络变化不阻止释放，下一 Start 使用新基线' {
        $case=New-RecoveryFixture 'same-boot-dynamic' -Owner
        $boot=$case.BootTime
        Set-PreviousBootFixture $case
        $case.BootTime=$boot
        $oldBaseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped') '同一 boot 外部地址、路由、网卡、DNS、代理变化允许结束'
        Assert-Recovery ($case.Events.Contains('cleanup-sdk') -and $case.Events.Contains('cleanup-route')) '仍执行本会话清理'
        $diff=Read-FixtureJson $case.SavedPaths.ui_recovery_comparison
        $release=Read-FixtureJson $case.SavedPaths.ui_recovery_resources
        Assert-Recovery ($diff.Equal -eq $false -and $release.Assessment.Released -eq $true) '差异真实保留，资源释放独立判定'
        Assert-Recovery ((Get-FixtureText $case.Baseline) -ceq $oldBaseline) '原始快照不被改写'
        $started=Invoke-RecoveryControl $case Start
        Assert-Recovery ($started.phase -eq 'starting') '动态恢复后能再次开启'
        Invoke-FixtureRunBeforeSdk $case
        $fresh=Read-FixtureJson $case.SavedPaths.ui_before
        Assert-Recovery ($fresh.Data.DNS[0].ServerAddresses[0] -eq '192.0.2.99') '真实 worker 采集当前 DNS 作为新基线'
    }
    Test-RecoveryCase '同一 boot 暂态清单不完整会重读当前状态' {
        $case=New-RecoveryFixture 'same-boot-retry' -Owner
        $pending=($case.Network | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        $pending.Complete=$false
        $case.InventoryQueue.Enqueue($pending)
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('wait-250')) '短暂失败重试后恢复'
        $release=Read-FixtureJson $case.SavedPaths.ui_recovery_resources
        Assert-Recovery ($release.InventoryAttempts -eq 2) '保存重读次数'
    }
    foreach ($damage in @('missing','corrupt','outside')) {
        Test-RecoveryCase ('同一 boot 旧诊断快照 '+$damage+' 不阻止当前资源释放') {
            $case=New-RecoveryFixture ('diagnostic-'+$damage) -Owner
            switch ($damage) {
                'missing' { Remove-Item -LiteralPath $case.Baseline }
                'corrupt' { [IO.File]::WriteAllText($case.Baseline,'{broken') }
                'outside' { $owner=Read-FixtureJson $case.Owner;$owner.BeforePath=Join-Path $case.Root 'not-a-baseline.json';Write-FixtureJson $case.Owner $owner }
            }
            $result=Invoke-RecoveryControl $case
            Assert-Recovery ($result.phase -eq 'stopped') '仅依靠当前清单和清理结果结束会话'
            $diagnostic=Read-FixtureJson $case.SavedPaths.ui_recovery_comparison
            Assert-Recovery ($diagnostic.Classification -eq 'BaselineUnavailable') '诊断缺失明确记录'
        }
    }
    Test-RecoveryCase '真实旧 boot 身份及当次全量快照可释放会话，独立网络变化仅留诊断' {
        $case=New-RecoveryFixture 'reboot-success' -Owner
        Set-PreviousBootFixture $case
        $baseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('inventory')) '真实重启判定成功允许恢复'
        Assert-Recovery ($result.message -match '重启') '状态说明重启后恢复'
        Assert-NoOldProcessCleanup $case
        $count=$case.Events.Count;$status=Get-FixtureText $case.Status
        $again=Invoke-RecoveryControl $case
        Assert-Recovery ($again.phase -eq 'stopped' -and $case.Events.Count -eq $count -and (Get-FixtureText $case.Status) -ceq $status) '释放成功后 Recover 幂等'
        Assert-Recovery ((Get-FixtureText $case.Baseline) -ceq $baseline) '重启恢复不重置基线'
    }
    Test-RecoveryCase 'Start 成功恢复后才创建新 worker pointer' {
        $case=New-RecoveryFixture 'start-after-recovery' -Owner
        $oldOwner=Get-FixtureText $case.Owner;$oldBaseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case Start
        Assert-Recovery ($result.phase -eq 'starting' -and $case.PhaseAtStart -eq 'starting') '新 worker 启动时状态已切换'
        Assert-Recovery ($case.Events.IndexOf('save-ui_recovery_comparison') -lt $case.Events.IndexOf('configuration') -and $case.Events.IndexOf('configuration') -lt $case.Events.IndexOf('start-worker')) '恢复、预检、启动按顺序执行'
        Assert-Recovery ((Read-FixtureJson $case.Worker).RunId -eq 'bbbbbbbbbbbbbbbbbbbbbbbb') '恢复后写入新 pointer'
        Assert-Recovery ((Get-FixtureText $case.Owner) -ceq $oldOwner -and (Get-FixtureText $case.Baseline) -ceq $oldBaseline) '新启动保留上次证据'
    }
    Test-RecoveryCase 'Start → 持久化连接 → 模拟重启 → Recover → Start → 真实 Run 重新采集基线' {
        $case=New-RecoveryFixture 'full-boot-cycle' -NoWorker
        Remove-Item -LiteralPath $case.Status
        $first=Invoke-RecoveryControl $case Start
        Assert-Recovery ($first.phase -eq 'starting') '第一次真实 Control Start 成功'
        Invoke-FixtureRunBeforeSdk $case
        Save-FixtureConnectedSession $case
        $oldPointer=Get-FixtureText $case.Worker;$oldOwner=Get-FixtureText $case.Owner;$oldBaseline=Get-FixtureText $case.Baseline
        $oldBaselinePath=$case.Baseline
        Assert-Recovery ((Read-FixtureJson $case.Status).phase -eq 'connected') '断电前磁盘上留下连接状态及真实持久化归属'
        # Simulated power loss: retain every file; no Stop and no worker finally.
        $case.WorkerAlive=$false
        Set-PreviousBootFixture $case
        $case.Events.Clear()
        $recovered=Invoke-RecoveryControl $case
        Assert-Recovery ($recovered.phase -eq 'stopped') '下一 boot 从持久化记录释放旧会话'
        Assert-NoOldProcessCleanup $case
        Assert-Recovery ((Get-FixtureText $case.Worker) -ceq $oldPointer -and (Get-FixtureText $case.Owner) -ceq $oldOwner) 'Recover 不覆盖旧 pointer 或 ownership'
        $case.WorkerStartTime=[datetime]'2026-09-17T03:00:00Z'
        $second=Invoke-RecoveryControl $case Start
        Assert-Recovery ($second.phase -eq 'starting' -and (Read-FixtureJson $case.Worker).RunId -eq 'cccccccccccccccccccccccc') '释放成功后才生成不同的新 run'
        $case.Network.StartedAt='2026-09-17T03:00:01Z';$case.Network.FinishedAt='2026-09-17T03:00:02Z'
        $case.Network.Data.DNS[0].ServerAddresses=@('192.0.2.100')
        $case.Restored=$true
        Invoke-FixtureRunBeforeSdk $case
        $newBaseline=Read-FixtureJson $case.SavedPaths.ui_before
        Assert-Recovery ($case.SavedPaths.ui_before -ne $oldBaselinePath -and $newBaseline.Data.DNS[0].ServerAddresses[0] -eq '192.0.2.100') '新 Run 使用本次新读状态作为基线'
        Assert-Recovery ((Get-FixtureText $oldBaselinePath) -ceq $oldBaseline -and (Get-FixtureText $case.Owner) -ceq $oldOwner) '新 Run 未覆盖旧归属或旧网络证据'
    }
    Test-RecoveryCase '跨 boot 网络提供程序尚未就绪时重读，第二次完整清单可恢复' {
        $case=New-RecoveryFixture 'boot-transient-inventory' -Owner
        Set-PreviousBootFixture $case
        $incomplete=$case.Network | ConvertTo-Json -Depth 16 | ConvertFrom-Json -Depth 16
        $incomplete.Complete=$false;$incomplete.ReadErrors=@('fixture provider not ready')
        $case.InventoryQueue.Enqueue($incomplete)
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and @($case.Events | Where-Object { $_ -eq 'inventory' }).Count -eq 2) '第一次不完整，第二次完整才成功'
        Assert-Recovery (@($case.Events | Where-Object { $_ -eq 'wait-500' }).Count -eq 1) '重读间只有一次有界等待'
        $evidence=Read-FixtureJson $case.SavedPaths.ui_recovery_reboot
        Assert-Recovery ($evidence.InventoryAttempts -eq 2 -and $evidence.Recovered -eq $true -and $evidence.OldProcessIdsUsedForCleanup -eq $false) '持久化真实重读与无旧PID操作证据'
        Assert-NoOldProcessCleanup $case
    }
    foreach ($diagnostic in @('missing','broken','outside-results')) {
        Test-RecoveryCase ('跨 boot 旧基线仅诊断：'+$diagnostic) {
            $case=New-RecoveryFixture ('boot-baseline-'+$diagnostic) -Owner
            Set-PreviousBootFixture $case
            switch ($diagnostic) {
                'missing' { Remove-Item -LiteralPath $case.Baseline }
                'broken' { [IO.File]::WriteAllText($case.Baseline,'{broken') }
                'outside-results' { $owner=Read-FixtureJson $case.Owner;$owner.BeforePath=Join-Path $case.Root 'untrusted-baseline.json';Write-FixtureJson $case.Owner $owner }
            }
            $pointer=Get-FixtureText $case.Worker;$ownerText=Get-FixtureText $case.Owner
            $result=Invoke-RecoveryControl $case
            Assert-Recovery ($result.phase -eq 'stopped') '旧基线不可用不阻塞已验证的旧会话释放'
            Assert-NoOldProcessCleanup $case
            Assert-Recovery ((Get-FixtureText $case.Worker) -ceq $pointer -and (Get-FixtureText $case.Owner) -ceq $ownerText -and $case.SavedPaths.Count -gt 0) '保留原始归属并记录本次诊断'
        }
    }
    foreach ($failure in @('Incomplete','ReadError','OldSnapshot','NoSnapshotTime','FinishedBeforeStarted','Process','Adapter','Interface','Address','ActiveRoute','PersistentRoute','DNS','Service','Driver')) {
        Test-RecoveryCase ('跨 boot 拒绝释放并保留旧 pointer：'+$failure) {
            $case=New-RecoveryFixture ('boot-reject-'+$failure) -Owner
            Set-PreviousBootFixture $case
            switch ($failure) {
                'Incomplete' { $case.Network.Complete=$false }
                'ReadError' { $case.Network.ReadErrors=@('fixture failed inventory') }
                'OldSnapshot' { $case.Network.StartedAt='2026-09-16T23:59:59Z' }
                'NoSnapshotTime' { $case.Network.PSObject.Properties.Remove('StartedAt') }
                'FinishedBeforeStarted' { $case.Network.FinishedAt='2026-09-17T01:00:00Z' }
                'Process' { $case.Network.Data.RelatedProcesses=@([pscustomobject]@{Name='linkboost.exe';ProcessId=98766;CreationDate='2026-09-17T01:00:00Z'}) }
                'Adapter' { $case.Network.Data.Adapters+= [pscustomobject]@{Name='mp_tun0'} }
                'Interface' { $case.Network.Data.Interfaces+= [pscustomobject]@{InterfaceAlias='mna_game_abcdef'} }
                'Address' { $case.Network.Data.IPAddresses+= [pscustomobject]@{InterfaceAlias='mna_game_abcdef'} }
                'ActiveRoute' { $case.Network.Data.ActiveRoutes+= [pscustomobject]@{InterfaceAlias='mp_tun0'} }
                'PersistentRoute' { $case.Network.Data.PersistentRoutes=@([pscustomobject]@{InterfaceAlias='mp_tun0'}) }
                'DNS' { $case.Network.Data.DNS+= [pscustomobject]@{InterfaceAlias='mna_game_abcdef'} }
                'Service' { $case.Network.Data.RelatedServices=@([pscustomobject]@{Name='linkboost';DisplayName='Fixture SDK service'}) }
                'Driver' { $case.Network.Data.RelatedDrivers=@([pscustomobject]@{Name='multipath';DisplayName='Fixture SDK driver'}) }
            }
            Assert-RecoveryRejected $case Start
            Assert-NoOldProcessCleanup $case
            Assert-Recovery (-not $case.Events.Contains('configuration')) '释放失败先于新启动配置读取'
            Assert-Recovery (@($case.Events | Where-Object { $_ -eq 'inventory' }).Count -eq 3 -and @($case.Events | Where-Object { $_ -eq 'wait-500' }).Count -eq 2) '持续失败最多读三次，等待两次'
        }
    }
    foreach ($section in @('Adapters','Interfaces','IPAddresses','ActiveRoutes','PersistentRoutes','DNS','RelatedProcesses','RelatedServices','RelatedDrivers','WinINETProxy','WinHTTPProxy')) {
        Test-RecoveryCase ('跨 boot 不接受 null section：'+$section) {
            $case=New-RecoveryFixture ('boot-null-'+$section) -Owner
            Set-PreviousBootFixture $case
            $case.Network.Data.$section=$null
            Assert-RecoveryRejected $case Start
            Assert-NoOldProcessCleanup $case
        }
    }
    foreach ($identity in @('WorkerAtBoot','WorkerWithoutTimezone','WorkerPidZero','RootAtBoot','OwnedAfterBoot','RootMissingFromOwned','WrongRootCreation','BootUnknown')) {
        Test-RecoveryCase ('旧 boot 身份不合格不得绕过原恢复限制：'+$identity) {
            $case=New-RecoveryFixture ('boot-identity-'+$identity) -Owner
            Set-PreviousBootFixture $case
            $record=Read-FixtureJson $case.Worker;$owner=Read-FixtureJson $case.Owner
            switch ($identity) {
                'WorkerAtBoot' { $record.WorkerCreatedUtc='2026-09-17T00:00:00Z' }
                'WorkerWithoutTimezone' { $record.WorkerCreatedUtc='2026-09-16T00:00:00' }
                'WorkerPidZero' { $record.WorkerPid=0 }
                'RootAtBoot' { $owner.RootCreated='2026-09-17T00:00:00Z';$owner.Owned[0].Created=$owner.RootCreated }
                'OwnedAfterBoot' { $owner.Owned+= [pscustomobject]@{Pid=98767;Created='2026-09-17T00:00:01Z';Depth=1;Kind='SDK'} }
                'RootMissingFromOwned' { $owner.Owned[0].Pid=98767 }
                'WrongRootCreation' { $owner.Owned[0].Created='2026-09-16T00:00:01Z' }
                'BootUnknown' { $case.BootReadThrows=$true }
            }
            Write-FixtureJson $case.Worker $record;Write-FixtureJson $case.Owner $owner
            Assert-RecoveryRejected $case Start
            Assert-Recovery (-not $case.Events.Contains('configuration')) '身份未证实不得作为跨 boot 已释放处理'
        }
    }
    Test-RecoveryCase '跨 boot 确认无残留后只移除该 run 的两个过期凭据文件' {
        $case=New-RecoveryFixture 'boot-exact-credential-cleanup' -Owner
        Set-PreviousBootFixture $case
        $files=New-FixtureExpiredCredentials $case
        $owner=Get-FixtureText $case.Owner;$baseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and -not (Test-Path -LiteralPath $files.Configuration) -and -not (Test-Path -LiteralPath $files.Recovery)) '两个过期凭据被准确移除'
        Assert-Recovery ((Get-FixtureText $files.Log) -eq 'fixture only, no credentials' -and (Get-FixtureText $files.Neighbor) -eq 'fixture only, no credentials') '同目录日志与其他 run 文件均保留'
        Assert-Recovery ((Get-FixtureText $case.Owner) -ceq $owner -and (Get-FixtureText $case.Baseline) -ceq $baseline) '归属和基线诊断证据保留'
        Assert-NoOldProcessCleanup $case
    }
    Test-RecoveryCase '跨 boot 仍有资源时保留凭据，不让删除掩盖未释放状态' {
        $case=New-RecoveryFixture 'boot-keep-pending-credentials' -Owner
        Set-PreviousBootFixture $case
        $files=New-FixtureExpiredCredentials $case
        $case.Network.Data.RelatedProcesses=@([pscustomobject]@{Name='linkboost.exe';ProcessId=98766})
        Assert-RecoveryRejected $case Start
        foreach ($path in @($files.Configuration,$files.Recovery,$files.Log,$files.Neighbor)) { Assert-Recovery ((Get-FixtureText $path) -eq 'fixture only, no credentials') '释放未确认前所有文件不变' }
        Assert-NoOldProcessCleanup $case
    }
    Test-RecoveryCase '过期凭据路径变成目录时拒绝删除，保留其他文件' {
        $case=New-RecoveryFixture 'boot-credential-is-directory' -Owner
        Set-PreviousBootFixture $case
        $files=New-FixtureExpiredCredentials $case
        Remove-Item -LiteralPath $files.Configuration
        $null=[IO.Directory]::CreateDirectory($files.Configuration)
        Assert-RecoveryRejected $case Start
        Assert-Recovery ((Test-Path -LiteralPath $files.Configuration -PathType Container) -and (Get-FixtureText $files.Recovery) -eq 'fixture only, no credentials') '异常目标没有被递归删除或跳过'
        Assert-Recovery ((Get-FixtureText $files.Neighbor) -eq 'fixture only, no credentials') '邻居未受影响'
        Assert-NoOldProcessCleanup $case
    }
    foreach ($label in @('ui_recovery_after','ui_recovery_comparison','ui_recovery_reboot','all')) {
        Test-RecoveryCase ('跨 boot 诊断落盘失败仍允许已验证释放：'+$label) {
            $case=New-RecoveryFixture ('boot-report-failure-'+$label) -Owner
            Set-PreviousBootFixture $case
            $case.SaveFailureLabels=if ($label -eq 'all') {@('ui_recovery_after','ui_recovery_comparison','ui_recovery_reboot')} else {@($label)}
            $pointer=Get-FixtureText $case.Worker;$owner=Get-FixtureText $case.Owner
            $result=Invoke-RecoveryControl $case
            Assert-Recovery ($result.phase -eq 'stopped' -and $result.message -match '部分检查记录未能保存') '状态准确报告已释放以及诊断未保存'
            Assert-Recovery ((Read-FixtureJson $case.Status).phase -eq 'stopped' -and (Get-FixtureText $case.Worker) -ceq $pointer -and (Get-FixtureText $case.Owner) -ceq $owner) 'Status 自身正常持久化且不覆盖身份'
            Assert-NoOldProcessCleanup $case
        }
    }
    foreach ($identity in @('WorkerAfterRoot','OwnedBeforeRoot','FutureRoot','DuplicateOwnedPid')) {
        Test-RecoveryCase ('同 boot 也拒绝矛盾的进程身份：'+$identity) {
            $case=New-RecoveryFixture ('same-boot-bad-identity-'+$identity) -Owner
            $record=Read-FixtureJson $case.Worker;$owner=Read-FixtureJson $case.Owner
            switch ($identity) {
                'WorkerAfterRoot' { $record.WorkerCreatedUtc='2026-09-16T00:00:01Z' }
                'OwnedBeforeRoot' { $owner.Owned+= [pscustomobject]@{Pid=98767;Created='2026-09-15T23:59:59Z';Depth=1;Kind='SDK'} }
                'FutureRoot' { $record.WorkerCreatedUtc=[DateTimeOffset]::UtcNow.AddDays(1).ToString('o');$owner.RootCreated=$record.WorkerCreatedUtc;$owner.Owned[0].Created=$record.WorkerCreatedUtc }
                'DuplicateOwnedPid' { $owner.Owned+=($owner.Owned[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json -Depth 8) }
            }
            Write-FixtureJson $case.Worker $record;Write-FixtureJson $case.Owner $owner
            Assert-RecoveryRejected $case Start
            Assert-NoOldProcessCleanup $case
        }
    }
} finally {
    # Delete only the freshly created, resolved fixture, without following links.
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolved.StartsWith($fixtureBase+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cne $runToken) { throw '测试清理路径越界，未删除' }
    if ([IO.Directory]::Exists($resolved)) {
        $items=@(Get-Item -LiteralPath $resolved -Force)+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw '测试目录出现链接，未删除' }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) { Remove-Item -LiteralPath $file.FullName -Force }
        foreach ($directory in @($items | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) { Remove-Item -LiteralPath $directory.FullName -Force }
    }
    $cleanupVerified=-not [IO.Directory]::Exists($resolved)
}
$passed=$checks.Count -gt 0 -and @($checks | Where-Object { -not $_.Passed }).Count -eq 0 -and $cleanupVerified
[pscustomobject]@{Passed=$passed;CheckCount=$checks.Count;NetworkStarted=$false;SdkStarted=$false;RealUserStateAccessed=$false;FixtureCleanupVerified=$cleanupVerified;Checks=$checks.ToArray()} | ConvertTo-Json -Depth 6
if (-not $passed) { exit 1 }
