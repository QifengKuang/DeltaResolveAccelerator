#requires -Version 7.0
<# Offline control-flow regression. Copies the real Control and SessionRecovery
   scripts into a new fixture, imports only reviewed file/status helpers, and
   replaces process, network, SDK and reboot classification dependencies.
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
$commonParts.Add('$script:MnaUiRoot=$PSScriptRoot')
foreach ($name in @('Get-MnaUiPaths','Get-MnaRunFile','Read-MnaUiJson','Write-MnaUiJson','Write-MnaUiStatus','Get-MnaUiStatus','ConvertTo-MnaUiOperationTime','Protect-MnaTrialMessage','Initialize-MnaUiRuntimeVariables','Assert-MnaUiPreviousRunClear')) {
    $definitions=@($commonAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name)
    if ($definitions.Count -ne 1) { throw ('后端函数未唯一找到：'+$name) }
    $commonParts.Add($definitions[0].Extent.Text)
}
$commonParts.Add(@'
function Test-MnaUiWorker { param($Record) return $fixtureScenario.WorkerAlive }
function Test-MnaFreeTrialExpired { return $false }
function Assert-MnaReleaseConfiguration { $fixtureScenario.Events.Add('configuration'); return [pscustomobject]@{} }
function New-MnaHexSecret { param($ByteCount) return 'bbbbbbbbbbbbbbbbbbbbbbbb' }
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
    $fixtureScenario.Events.Add('start-worker')
    $fixtureScenario.PhaseAtStart=(Read-MnaUiJson (Get-MnaUiPaths).Status).phase
    $fixtureScenario.WorkerAlive=$true
    [pscustomobject]@{Id=12345;StartTime=[datetime]'2026-09-17T00:00:00Z';Path=$FilePath}
}
function Get-Process { param($Name,$Id,$ErrorAction) return $null }
function Stop-Process { throw '离线验证禁止停止真实进程' }
function Get-CimInstance {
    param($ClassName,$Property,$Filter,$ErrorAction)
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=[datetime]'2026-09-17T00:00:00Z'} }
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
    return $fixtureScenario.Network
}
function Save-TrialNetworkState {
    param($State,$Label)
    $fixtureScenario.Events.Add('save-'+$Label)
    $path=Join-Path (Get-MnaUiPaths).Root ('results/'+$Label+'.json')
    Write-MnaUiJson $path $State
    return $path
}
function Compare-TrialNetworkState {
    param($BaselineState,$CurrentState)
    $fixtureScenario.Events.Add('compare')
    return [pscustomobject]@{Fixture=$true;Complete=$true}
}
'@
$gameRouteMock=@'
function Stop-MnaGameRouteRecovery {
    param($RunId,$OwnedProcesses)
    $fixtureScenario.Events.Add('cleanup-route')
    if ($fixtureScenario.RouteThrows) { throw 'fixture game route cleanup failure' }
    return $fixtureScenario.GameRouteCleanup
}
'@
$rebootMock=@'
function Test-MnaRebootNetworkRestored {
    param($RunId,$Owner,$BaselineState,$CurrentState,$BootTime)
    $fixtureScenario.Events.Add('classify-reboot')
    return $fixtureScenario.RebootRestored
}
'@

function New-RecoveryFixture([string]$Name,[switch]$Owner,[switch]$NoWorker,[string]$Phase='error') {
    $root=Join-Path $fixtureRoot $Name
    $null=[IO.Directory]::CreateDirectory($root)
    foreach ($file in @('Control-Accelerator.ps1','Mna-SessionRecovery.ps1')) { Copy-Item -LiteralPath (Join-Path $backend $file) -Destination (Join-Path $root $file) }
    [IO.File]::WriteAllText((Join-Path $root 'Mna-UI.Common.ps1'),($commonParts -join "`n"))
    [IO.File]::WriteAllText((Join-Path $root 'Trial-NetworkState.ps1'),$networkMock)
    [IO.File]::WriteAllText((Join-Path $root 'Mna-GameRoute.ps1'),$gameRouteMock)
    [IO.File]::WriteAllText((Join-Path $root 'Mna-RebootRecovery.ps1'),$rebootMock)
    [IO.File]::WriteAllText((Join-Path $root 'Run-Accelerator.ps1'),"throw 'fixture must never execute worker'")
    $runId='aaaaaaaaaaaaaaaaaaaaaaaa'
    $scenario=[pscustomobject]@{
        Root=$root;RunId=$runId;Worker=(Join-Path $root 'private/ui-worker.json')
        Status=(Join-Path $root 'results/ui-status.json');Owner=(Join-Path $root ('private/ui-ownership-'+$runId+'.json'))
        Baseline=(Join-Path $root 'results/before.json');StopRequest=(Join-Path $root ('private/ui-stop-'+$runId+'.json'))
        Events=[Collections.Generic.List[string]]::new();WorkerAlive=$false;Restored=$true;RebootRestored=$false;RouteThrows=$false;PhaseAtStart=$null
        Network=[pscustomobject]@{SchemaVersion=1;Complete=$true;ReadErrors=@();Data=[pscustomobject]@{
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
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('compare')) '第一次恢复清理并比较'
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
    foreach ($damage in @('worker-json','worker-run-id','owner-json','owner-run-id','owner-runtime','owner-root-pid','owner-root-created','owner-owned-empty','owner-owned-pid','owner-owned-created','baseline-json','baseline-missing','baseline-outside')) {
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
    foreach ($failure in @('route-errors','route-process-live','route-throws','sdk-errors','sdk-process-live','sdk-count-unknown','inventory-incomplete','network-difference')) {
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
                'network-difference' { $case.Restored=$false }
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
    Test-RecoveryCase '普通比较失败但重启判定通过后持久化成功状态' {
        $case=New-RecoveryFixture 'reboot-success' -Owner;$case.Restored=$false;$case.RebootRestored=$true
        $baseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case
        Assert-Recovery ($result.phase -eq 'stopped' -and $case.Events.Contains('classify-reboot')) '重启判定成功允许恢复'
        Assert-Recovery ($result.message -match '重启') '状态说明重启后恢复'
        $evidence=Read-FixtureJson (Join-Path $case.Root 'results/ui_recovery_reboot.json')
        Assert-Recovery ($evidence.Recovered -eq $true -and $evidence.OriginalDifferencesPreserved -eq $true) '保存重启判定记录'
        Assert-Recovery ((Get-FixtureText $case.Baseline) -ceq $baseline) '重启恢复不重置基线'
    }
    Test-RecoveryCase 'Start 成功恢复后才创建新 worker pointer' {
        $case=New-RecoveryFixture 'start-after-recovery' -Owner
        $oldOwner=Get-FixtureText $case.Owner;$oldBaseline=Get-FixtureText $case.Baseline
        $result=Invoke-RecoveryControl $case Start
        Assert-Recovery ($result.phase -eq 'starting' -and $case.PhaseAtStart -eq 'starting') '新 worker 启动时状态已切换'
        Assert-Recovery ($case.Events.IndexOf('compare') -lt $case.Events.IndexOf('configuration') -and $case.Events.IndexOf('configuration') -lt $case.Events.IndexOf('start-worker')) '恢复、预检、启动按顺序执行'
        Assert-Recovery ((Read-FixtureJson $case.Worker).RunId -eq 'bbbbbbbbbbbbbbbbbbbbbbbb') '恢复后写入新 pointer'
        Assert-Recovery ((Get-FixtureText $case.Owner) -ceq $oldOwner -and (Get-FixtureText $case.Baseline) -ceq $oldBaseline) '新启动保留上次证据'
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
