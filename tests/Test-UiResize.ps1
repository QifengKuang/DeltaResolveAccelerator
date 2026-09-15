#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows) { throw 'The UI resize suite requires Windows.' }

$repository = Split-Path $PSScriptRoot -Parent
$executable = Join-Path $repository 'build/AcceleratorPreview.exe'
if (-not $SkipBuild) {
    & (Join-Path $repository 'build/Compile-App.ps1') -PreviewBuild | Out-Null
}
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw 'Preview executable missing. Run without -SkipBuild to compile it.'
}

$outputDirectory = Join-Path $PSScriptRoot 'output/resize'
$runName = 'run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runDirectory = Join-Path $outputDirectory $runName
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$summaryPath = Join-Path $outputDirectory 'resize-summary.json'
$states = @('stopped', 'starting', 'error', 'settings')
$displayScales = @(1.0, 1.25, 1.5, 2.0)
$sizes = @('default', 'minimum', 'wide', 'tall', 'maximum')
$expectedResizeChecks = 23
$cases = [Collections.Generic.List[object]]::new()
$suiteStartedAt = [DateTimeOffset]::UtcNow

foreach ($displayScale in $displayScales) {
    foreach ($state in $states) {
        foreach ($size in $sizes) {
            $percentage = [int][Math]::Round($displayScale * 100)
            $imagePath = Join-Path $runDirectory ('{0}-{1}-{2}.png' -f $state, $percentage, $size)
            $layoutPath = $imagePath + '.layout.json'
            $issues = [Collections.Generic.List[string]]::new()
            $process = $null
            $layout = $null
            $effectiveScale = $null
            $resizeChecks = 0
            $width = $null
            $height = $null
            $labelCount = 0
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
                $startInfo.ArgumentList.Add($displayScale.ToString([Globalization.CultureInfo]::InvariantCulture))
                if ($size -ne 'default') {
                    $startInfo.ArgumentList.Add('--preview-size')
                    $startInfo.ArgumentList.Add($size)
                }
                $startInfo.ArgumentList.Add('--preview-resize-test')
                $startInfo.ArgumentList.Add('--preview-native')
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
                if ([Math]::Abs([double]$layout.displayScale - $displayScale) -gt 0.0001) {
                    $issues.Add('Preview did not use the requested display scale.')
                }
                $effectiveScale = [double]$layout.scale
                if ([double]::IsNaN($effectiveScale) -or [double]::IsInfinity($effectiveScale) -or $effectiveScale -le 0) {
                    $issues.Add('Effective content scale must be positive and finite.')
                }
                $resizeChecks = [int]$layout.resizeChecks
                if ($resizeChecks -ne $expectedResizeChecks) {
                    $issues.Add("Expected $expectedResizeChecks repeated-resize and native edge checks; received $resizeChecks.")
                }

                $width = [int]$layout.width
                $height = [int]$layout.height
                $minimumWidth = [int]$layout.minimumWidth
                $minimumHeight = [int]$layout.minimumHeight
                $maximumWidth = [int]$layout.maximumWidth
                $maximumHeight = [int]$layout.maximumHeight
                if ($minimumWidth -le 0 -or $minimumHeight -le 0 -or $minimumWidth -ge $maximumWidth -or $minimumHeight -ge $maximumHeight) {
                    $issues.Add('Window limits must be positive and allow resizing on both axes.')
                }
                if ($width -lt $minimumWidth -or $width -gt $maximumWidth -or $height -lt $minimumHeight -or $height -gt $maximumHeight) {
                    $issues.Add('Final window dimensions exceed the reported resize limits.')
                }
                # The content may shrink or grow independently of monitor DPI, but its
                # original 860 x 664 design must fit inside the actual window rectangle.
                if ($effectiveScale -gt [Math]::Min($width / 860.0, $height / 664.0) + 0.01) {
                    $issues.Add('Effective content scale exceeds the available window dimensions.')
                }
                $expectedWidth = $null
                $expectedHeight = $null
                switch ($size) {
                    'minimum' { $expectedWidth = $minimumWidth; $expectedHeight = $minimumHeight }
                    'maximum' { $expectedWidth = $maximumWidth; $expectedHeight = $maximumHeight }
                    'wide' { $expectedWidth = $maximumWidth; $expectedHeight = $minimumHeight }
                    'tall' { $expectedWidth = $minimumWidth; $expectedHeight = $maximumHeight }
                }
                if ($null -ne $expectedWidth -and ($width -ne $expectedWidth -or $height -ne $expectedHeight)) {
                    $issues.Add("The $size preset was not preserved after repeated resizing.")
                }
                if ($layout.networkStarted -ne $false) {
                    $issues.Add('Preview report did not confirm that networking remained stopped.')
                }
                if ($layout.settings -ne ($state -eq 'settings')) {
                    $issues.Add('Preview did not show the requested dashboard or settings view.')
                }
                $expectedPhase = if ($state -eq 'settings') { 'stopped' } else { $state }
                if ($layout.state -ne $expectedPhase) {
                    $issues.Add('Preview did not show the requested connection phase.')
                }
                $labelCount = @($layout.labels).Count
                if ($labelCount -eq 0) { $issues.Add('Layout report contained no visible text labels.') }
                if (@($layout.labels | Where-Object { -not $_.fits -and -not $_.ellipsis }).Count -gt 0) {
                    $issues.Add('Visible text is clipped without an intentional ellipsis.')
                }
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
                displayScale = $displayScale
                effectiveScale = $effectiveScale
                size = $size
                width = $width
                height = $height
                passed = $issues.Count -eq 0
                resizeChecks = $resizeChecks
                labelCount = $labelCount
                durationMs = $elapsed.ElapsedMilliseconds
                imagePath = $imagePath
                layoutPath = $layoutPath
                issues = $issues.ToArray()
            })
        }
    }
}

$failedCases = @($cases | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    passed = $failedCases.Count -eq 0
    caseCount = $cases.Count
    passedCount = $cases.Count - $failedCases.Count
    failedCount = $failedCases.Count
    expectedResizeChecksPerCase = $expectedResizeChecks
    completedResizeChecks = ($cases | Measure-Object -Property resizeChecks -Sum).Sum
    displayScales = $displayScales
    states = $states
    sizes = $sizes
    networkStarted = $false
    physicalDisplaySettingsChanged = $false
    verification = 'Same-instance resize loops, bounds/font drift, native edge hit tests and off-screen layout previews; not a live compositor or physical multi-monitor DPI test.'
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
    CompletedResizeChecks = $summary.completedResizeChecks
    ReportPath = $summaryPath
} | ConvertTo-Json
if (-not $summary.passed) {
    throw "UI resize checks failed in $($failedCases.Count) of $($cases.Count) cases. Inspect $summaryPath"
}
