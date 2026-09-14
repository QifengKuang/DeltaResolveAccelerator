#requires -Version 7.0
# Exercise the real Start/Stop entry point with isolated synthetic files. Only
# the OS/process/network boundaries are replaced, after loading fixture code.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $PSScriptRoot ('offline-work/control-'+[guid]::NewGuid().ToString('N'))
$backend=Join-Path $fixture 'backend'
$null=[IO.Directory]::CreateDirectory($backend)
foreach($name in @('Control-Accelerator.ps1','Mna-UI.Common.ps1','Mna-SessionState.ps1')){
    Copy-Item -LiteralPath (Join-Path $repository ('app/backend/'+$name)) -Destination (Join-Path $backend $name)
}
$overrides=@'

# Fixture-only boundaries; never start or stop a real process/network service.
$script:FixtureBoot='2026-01-02T00:00:00.0000000Z'
function Get-MnaUiBootIdentity { $script:FixtureBoot }
function Test-MnaUiWorker { param($Record) $Record.WorkerPid -eq 4242 }
function Test-MnaUiSamePath { param($Left,$Right) [string]::Equals($Left,$Right,[StringComparison]::OrdinalIgnoreCase) }
function Get-Process { param($Name) if($env:MNA_FIXTURE_RESIDUAL -eq 'process'){[pscustomobject]@{Id=9876}} }
function Get-NetAdapter { param([switch]$IncludeHidden) if($env:MNA_FIXTURE_RESIDUAL -eq 'tun'){[pscustomobject]@{Name='mna_game_fixture'}} }
function Get-NetTCPConnection { param($State) if($env:MNA_FIXTURE_RESIDUAL -eq 'port'){[pscustomobject]@{LocalPort=9801}} }
function Get-NetUDPEndpoint { @() }
function Get-CimInstance { throw 'Unexpected process query in previous-boot recovery' }
function Stop-Process { throw 'Offline controller must not stop any process' }
function Invoke-WebRequest { throw 'Offline controller must not access the network' }
function Assert-MnaReleaseConfiguration { [pscustomobject]@{RoutingMode='ResolveOnly'} }
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
    [IO.File]::WriteAllText((Join-Path $WorkingDirectory 'launch.marker'),'simulated')
    [pscustomobject]@{Id=4242;StartTime=Get-Date;Path=$FilePath}
}
'@
[IO.File]::AppendAllText((Join-Path $backend 'Mna-UI.Common.ps1'),$overrides,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $backend 'Run-Accelerator.ps1'),'throw "Fixture worker must not execute"')
$private=Join-Path $backend 'private'
$null=[IO.Directory]::CreateDirectory($private)
$null=[IO.Directory]::CreateDirectory((Join-Path $backend 'results'))
$runId='111111111111111111111111'
$recordPath=Join-Path $private 'ui-worker.json'
$ownerPath=Join-Path $private ('ui-ownership-'+$runId+'.json')
$statusPath=Join-Path $backend 'results/ui-status.json'
$checks=[Collections.Generic.List[object]]::new()
function Write-Fixture($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
function Reset-Fixture {
    Write-Fixture $recordPath ([pscustomobject]@{RunId=$runId;WorkerPid=9876;WorkerCreatedUtc='2026-01-01T12:00:00Z';WorkerExecutable='C:\Moved\runtime\pwsh.exe';WorkerScript='C:\Moved\backend\Run-Accelerator.ps1'})
    Write-Fixture $ownerPath ([pscustomobject]@{RunId=$runId;RootPid=9877;RootCreated='2026-01-01T12:00:01Z';Runtime='C:\Moved\sdk';Owned=@([pscustomobject]@{Pid=9877;Created='2026-01-01T12:00:01Z'})})
    Write-Fixture $statusPath ([pscustomobject]@{runId=$runId;phase='connected';ready=$true;updatedAt='2026-01-01T12:00:02Z';progressStage='Old stage';operationStartedAt='2026-01-01T12:00:00Z'})
    $marker=Join-Path $backend 'launch.marker'
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
}
function Invoke-Control([string]$Action){
    $text=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $backend 'Control-Accelerator.ps1') -Action $Action
    if($LASTEXITCODE -ne 0){throw 'Fixture controller failed'}
    ($text|Out-String)|ConvertFrom-Json
}
function Assert-Check([string]$Name,[bool]$Success){
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Success})
    if(-not $Success){throw $Name}
}
$originalResidual=$env:MNA_FIXTURE_RESIDUAL
try {
    $env:MNA_FIXTURE_RESIDUAL=''
    Reset-Fixture
    $before=Invoke-Control Status
    Assert-Check 'Status rejects old connected state and hides its progress' ($before.phase -eq 'stopped' -and -not $before.ready -and -not $before.progressStage)
    $started=Invoke-Control Start
    $worker=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
    $owner=Get-Content -LiteralPath $ownerPath -Raw|ConvertFrom-Json
    Assert-Check 'Start retires an old moved installation before path validation' ($started.phase -eq 'starting' -and $worker.RunId -ne $runId -and $owner.RetiredPreviousBoot)
    Assert-Check 'Start retains 1.0.4 stage and operation start' ($started.progressStage -eq '准备本地服务' -and $started.operationStartedAt -and -not $started.ready)
    Assert-Check 'Start publishes current boot on the new worker' (([datetime]$worker.BootIdentity).ToUniversalTime() -eq ([datetime]'2026-01-02T00:00:00Z').ToUniversalTime() -and $worker.WorkerPid -eq 4242)
    Assert-Check 'Start uses only the simulated launch boundary' (Test-Path -LiteralPath (Join-Path $backend 'launch.marker'))
    Reset-Fixture
    $stopped=Invoke-Control Stop
    Assert-Check 'Stop retires the same previous boot with no simulated launch' ($stopped.phase -eq 'stopped' -and -not (Test-Path -LiteralPath (Join-Path $backend 'launch.marker')))
    foreach($residual in @('process','tun','port')) {
        Reset-Fixture;$env:MNA_FIXTURE_RESIDUAL=$residual
        $blocked=Invoke-Control Start
        $worker=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
        Assert-Check ('Residual '+$residual+' blocks Start and retains the current failure') ($blocked.phase -eq 'error' -and -not $blocked.ready -and $worker.RunId -eq $runId -and -not (Test-Path -LiteralPath (Join-Path $backend 'launch.marker')))
    }
}finally{$env:MNA_FIXTURE_RESIDUAL=$originalResidual}
$report=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Cases=@($checks.ToArray());NetworkStarted=$false;SdkStarted=$false}
$output=Join-Path $PSScriptRoot 'output'
$null=[IO.Directory]::CreateDirectory($output)
Write-Fixture (Join-Path $output 'control-session.json') $report
$report|ConvertTo-Json -Depth 5
