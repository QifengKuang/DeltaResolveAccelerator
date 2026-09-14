# Read-only startup check. Does not read/decrypt device-key contents or start networking.
# Use app/runtime/pwsh.exe -NoProfile -NonInteractive -File this-script.ps1.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# The preflight reader decodes this redirected JSON as UTF-8.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'Mna-UI.Common.ps1')
try {
    $settings=Assert-MnaReleaseConfiguration
    [pscustomobject]@{
        valid=$true;message='首次设置和运行文件检查通过'
        gameExecutable=$settings.GameExecutable;gameExecutables=@($settings.GameExecutables);trialDeadline=$settings.TrialDeadline;routingMode='ResolveOnly'
    } | ConvertTo-Json -Depth 4
    exit 0
} catch {
    [pscustomobject]@{
        valid=$false;message=(Protect-MnaTrialMessage $_.Exception.Message)
        gameExecutable=$null;gameExecutables=@();trialDeadline='2026-11-13T00:00:00+11:00';routingMode='ResolveOnly'
    } | ConvertTo-Json -Depth 4
    exit 1
}
