#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows) { throw 'The UI layout suite requires Windows.' }

$repository = Split-Path $PSScriptRoot -Parent
$executable = Join-Path $repository 'build/AcceleratorPreview.exe'
if (-not $SkipBuild) {
    & (Join-Path $repository 'build/Compile-App.ps1') -PreviewBuild | Out-Null
}
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'Preview executable missing. Run without -SkipBuild to compile it.'
}

$outputDirectory = Join-Path $PSScriptRoot 'output/design'
$runName = 'run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runDirectory = Join-Path $outputDirectory $runName
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$summaryPath = Join-Path $outputDirectory 'layout-summary.json'
$states = @('stopped', 'starting', 'connected', 'error', 'settings', 'setup', 'software', 'checking', 'stopping')
$scales = @(1.0, 1.25, 1.5, 2.0)
$cases = [Collections.Generic.List[object]]::new()
$suiteStartedAt = [DateTimeOffset]::UtcNow

foreach ($scale in $scales) {
    foreach ($state in $states) {
        $percentage = [int][Math]::Round($scale * 100)
        $imagePath = Join-Path $runDirectory ('{0}-{1}.png' -f $state, $percentage)
        $layoutPath = $imagePath + '.layout.json'
        $issues = [Collections.Generic.List[string]]::new()
        $labelCount = 0
        $ellipsisCount = 0
        $process = $null
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        try {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $executable
            $startInfo.WorkingDirectory = Split-Path $executable -Parent
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $startInfo.ArgumentList.Add('--preview')
            $startInfo.ArgumentList.Add($imagePath)
            $startInfo.ArgumentList.Add('--preview-state')
            $startInfo.ArgumentList.Add($state)
            $startInfo.ArgumentList.Add('--preview-scale')
            $startInfo.ArgumentList.Add($scale.ToString([Globalization.CultureInfo]::InvariantCulture))
            $process = [Diagnostics.Process]::Start($startInfo)
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                $process.Kill($true)
                $null = $process.WaitForExit(5000)
                throw "Preview timed out after $TimeoutSeconds seconds."
            }
            if ($process.ExitCode -ne 0) { throw "Preview exited with code $($process.ExitCode)." }
            if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf) -or (Get-Item -LiteralPath $imagePath).Length -eq 0) {
                throw 'Preview image was not produced.'
            }
            if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) {
                throw 'Preview layout report was not produced.'
            }

            $layout = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
            if ($layout.passed -isnot [bool] -or -not $layout.passed) {
                $issues.Add('Layout report did not pass.')
            }
            foreach ($issue in $layout.issues) { $issues.Add([string]$issue) }
            if ([Math]::Abs([double]$layout.scale - $scale) -gt 0.0001) {
                $issues.Add('Preview did not use the requested scale.')
            }
            if ($layout.networkStarted -ne $false) {
                $issues.Add('Preview report did not confirm that networking remained stopped.')
            }
            $expectedSettings = $state -in @('settings', 'setup', 'software')
            if ($layout.settings -ne $expectedSettings) {
                $issues.Add('Preview did not show the requested dashboard or settings view.')
            }
            $expectedPhase = if ($state -in @('settings', 'setup', 'software', 'checking')) { 'stopped' } else { $state }
            if ($layout.state -ne $expectedPhase) {
                $issues.Add('Preview did not show the requested connection phase.')
            }
            $labelCount = @($layout.labels).Count
            if ($labelCount -eq 0) { $issues.Add('Layout report contained no visible text labels.') }
            $ellipsisCount = @($layout.labels | Where-Object { -not $_.fits -and $_.ellipsis }).Count
        }
        catch {
            $issues.Add($_.Exception.Message)
        }
        finally {
            $elapsed.Stop()
            if ($null -ne $process) { $process.Dispose() }
        }
        $cases.Add([pscustomobject]@{
            state = $state
            scale = $scale
            percentage = $percentage
            passed = $issues.Count -eq 0
            labelCount = $labelCount
            intentionalEllipsisCount = $ellipsisCount
            durationMs = $elapsed.ElapsedMilliseconds
            imagePath = $imagePath
            layoutPath = $layoutPath
            issues = $issues.ToArray()
        })
    }
}

$failedCases = @($cases | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    passed = $failedCases.Count -eq 0
    caseCount = $cases.Count
    passedCount = $cases.Count - $failedCases.Count
    failedCount = $failedCases.Count
    scales = $scales
    states = $states
    networkStarted = $false
    physicalDisplaySettingsChanged = $false
    verification = 'Explicit preview-scale layout simulation; not a physical multi-monitor DPI test.'
    startedAtUtc = $suiteStartedAt.ToString('o')
    finishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    runDirectory = $runDirectory
    cases = $cases.ToArray()
}
[IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Passed = $summary.passed
    CaseCount = $summary.caseCount
    PassedCount = $summary.passedCount
    FailedCount = $summary.failedCount
    ReportPath = $summaryPath
} | ConvertTo-Json
if (-not $summary.passed) {
    throw "UI layout checks failed in $($failedCases.Count) of $($cases.Count) cases. Inspect $summaryPath"
}
