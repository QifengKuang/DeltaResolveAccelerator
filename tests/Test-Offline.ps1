#requires -Version 7.0
[CmdletBinding()]
param()
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'The offline suite requires Windows.' }
$repository=Split-Path $PSScriptRoot -Parent
$output=Join-Path $PSScriptRoot 'output'
$null=New-Item -ItemType Directory -Path $output -Force
$pwsh=Join-Path $PSHOME 'pwsh.exe'

& (Join-Path $repository 'build/Compile-App.ps1') -PreviewBuild | Out-Null

$backendOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-BackendOffline.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Backend offline tests failed.' }
$backend=$backendOutput | Out-String | ConvertFrom-Json
if (-not $backend.Passed -or $backend.NetworkStarted) { throw 'Unexpected backend test result.' }
[IO.File]::WriteAllText((Join-Path $output 'backend.json'),($backend | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

$rebootOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-RebootRecovery.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Reboot network recovery tests failed.' }
[IO.File]::WriteAllText((Join-Path $output 'reboot-recovery.txt'),($rebootOutput | Out-String),[Text.UTF8Encoding]::new($false))
$routeOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-RouterAdvertisementRecovery.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Router advertisement recovery tests failed.' }
$route=$routeOutput | Out-String | ConvertFrom-Json
if (-not $route.Passed -or $route.NetworkStarted -or $route.SdkStarted -or -not $route.InputsUnmodified) { throw 'Unexpected route recovery test result.' }
[IO.File]::WriteAllText((Join-Path $output 'route-origin-recovery.json'),($route | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$releaseOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-ReleasedResources.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Released resource tests failed.' }
$release=$releaseOutput | Out-String | ConvertFrom-Json
if (-not $release.Passed -or $release.NetworkStarted) { throw 'Unexpected resource release test result.' }
[IO.File]::WriteAllText((Join-Path $output 'released-resources.json'),($release | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$sessionOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-SessionRecovery.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Session recovery flow tests failed.' }
$session=$sessionOutput | Out-String | ConvertFrom-Json
if (-not $session.Passed -or $session.NetworkStarted -or $session.SdkStarted -or -not $session.FixtureCleanupVerified) { throw 'Unexpected recovery test result.' }
[IO.File]::WriteAllText((Join-Path $output 'session-recovery.json'),($session | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

$atomicOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-AtomicRuntimeState.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Atomic runtime state tests failed.' }
$reportLine=@($atomicOutput | Where-Object { $_ -like 'ReportPath: *' })
if ($reportLine.Count -ne 1) { throw 'Atomic test report was not produced.' }
$atomic=Get-Content -LiteralPath $reportLine[0].Substring('ReportPath: '.Length) -Raw | ConvertFrom-Json
if (-not $atomic.Passed -or $atomic.NetworkStarted -or $atomic.SdkStarted) { throw 'Unexpected atomic test result.' }
[IO.File]::WriteAllText((Join-Path $output 'atomic.json'),($atomic | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

$uiWork=Join-Path (Join-Path $PSScriptRoot 'ui-work') ([guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $uiWork -Force
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path $repository 'build/AcceleratorPreview.exe'
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$info.ArgumentList.Add('--self-test')
$info.ArgumentList.Add($uiWork)
$process=[Diagnostics.Process]::Start($info)
try {
    if (-not $process.WaitForExit(30000)) { throw 'UI offline tests timed out; inspect the test process.' }
    if ($process.ExitCode -ne 0) { throw 'UI offline tests failed.' }
} finally { $process.Dispose() }
$uiReports=@(Get-ChildItem -LiteralPath $uiWork -Recurse -File -Filter 'self-test-result.json')
if ($uiReports.Count -ne 1) { throw 'UI test report was not produced.' }
$ui=Get-Content -LiteralPath $uiReports[0].FullName -Raw | ConvertFrom-Json
if (-not $ui.passed -or $ui.networkStarted -or $ui.realAppSettingsRead) { throw 'Unexpected UI test result.' }
$uiChecks=@($ui.PSObject.Properties | Where-Object { $_.Name -notin @('passed','networkStarted','realAppSettingsRead','testDirectory') }).Count
$summary=[pscustomobject]@{
    Passed=$true
    BackendChecks=$backend.Checks
    RebootRecoveryPassed=$true
    RouterAdvertisementChecks=$route.CheckCount
    ReleasedResourceChecks=$release.CheckCount
    SessionRecoveryChecks=$session.CheckCount
    AtomicStateChecks=$atomic.CheckCount
    UiChecks=$uiChecks
    NetworkStarted=$false
    RealAppSettingsRead=$false
    OfficialHelperParserChecked=$false
}
[IO.File]::WriteAllText((Join-Path $output 'summary.json'),($summary | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json
