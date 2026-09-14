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
$sessionOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-SessionState.ps1')
if($LASTEXITCODE -ne 0){throw 'Session-state regression failed.'}
$session=$sessionOutput|Out-String|ConvertFrom-Json
if($session.Failed -ne 0 -or $session.Passed -ne $session.Total){throw 'Unexpected session-state test result.'}
$controlOutput=& $pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'Test-ControlSessionOffline.ps1')
if($LASTEXITCODE -ne 0){throw 'Control-session regression failed.'}
$control=$controlOutput|Out-String|ConvertFrom-Json
if(-not $control.Passed -or $control.NetworkStarted -or $control.SdkStarted){throw 'Unexpected controller test result.'}
$summary=[pscustomobject]@{
    Passed=$true
    BackendChecks=$backend.Checks
    AtomicStateChecks=$atomic.CheckCount
    UiChecks=$uiChecks
    SessionStateChecks=$session.Total
    ControlSessionChecks=$control.Checks
    NetworkStarted=$false
    RealAppSettingsRead=$false
    OfficialHelperParserChecked=$false
}
[IO.File]::WriteAllText((Join-Path $output 'summary.json'),($summary | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json
